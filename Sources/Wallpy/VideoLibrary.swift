import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum MediaKind: String, Codable {
    case video, image
}

/// A wallpaper in the library: a looping video or a still image.
struct Video: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    let fileName: String
    let addedAt: Date
    let width: Int
    let height: Int
    let duration: Double
    var kind: MediaKind = .video

    var isImage: Bool { kind == .image }

    var url: URL { VideoLibrary.directory.appendingPathComponent(fileName) }
    var thumbnailURL: URL { VideoLibrary.directory.appendingPathComponent("\(id.uuidString).jpg") }
    var resolutionLabel: String { "\(width)×\(height)" }
    var durationLabel: String {
        if isImage { return tr("Imagen") }
        let s = Int(duration.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    init(id: UUID, name: String, fileName: String, addedAt: Date, width: Int, height: Int,
         duration: Double, kind: MediaKind = .video) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.addedAt = addedAt
        self.width = width
        self.height = height
        self.duration = duration
        self.kind = kind
    }

    // Libraries saved before images existed have no "kind".
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        fileName = try c.decode(String.self, forKey: .fileName)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        duration = try c.decode(Double.self, forKey: .duration)
        kind = try c.decodeIfPresent(MediaKind.self, forKey: .kind) ?? .video
    }
}

enum ImportError: LocalizedError {
    case notPlayable(String)
    case noVideoTrack(String)
    case unreadableImage(String)

    var errorDescription: String? {
        switch self {
        case .notPlayable(let name): return tr("«%@» no se puede reproducir con AVFoundation.", name)
        case .noVideoTrack(let name): return tr("«%@» no contiene pista de vídeo.", name)
        case .unreadableImage(let name): return tr("«%@» no es una imagen que macOS pueda abrir.", name)
        }
    }
}

/// Videos the user has imported. Files are copied into Application Support so
/// the wallpaper keeps working if the original is moved or deleted.
@MainActor
final class VideoLibrary: ObservableObject {
    static let shared = VideoLibrary()
    static let allowedTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie, .appleProtectedMPEG4Video, .movie, .image]

    @Published private(set) var videos: [Video] = []
    @Published private(set) var importing = 0

    nonisolated static let directory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Wallpy/Videos", isDirectory: true)
    }()
    private var directory: URL { Self.directory }
    private var indexURL: URL { directory.appendingPathComponent("library.json") }

    private init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([Video].self, from: data) else { return }
        videos = list.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(videos) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    func video(id: UUID?) -> Video? {
        guard let id else { return nil }
        return videos.first { $0.id == id }
    }

    /// Imports the given files; returns error messages for the ones that failed.
    func importVideos(_ urls: [URL]) async -> [String] {
        var errors: [String] = []
        for url in urls {
            importing += 1
            do {
                let video = try await importVideo(url)
                videos.insert(video, at: 0)
                persist()
            } catch {
                errors.append(error.localizedDescription)
            }
            importing -= 1
        }
        return errors
    }

    private func importVideo(_ source: URL) async throws -> Video {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let name = source.deletingPathExtension().lastPathComponent
        let type = UTType(filenameExtension: source.pathExtension)
        if type?.conforms(to: .image) == true {
            // Animated GIF / PNG become a looping video (AVFoundation can't play them).
            if (type?.conforms(to: .gif) == true || type?.conforms(to: .png) == true),
               Self.isAnimated(source), ExternalTool.ffmpeg.url != nil {
                let work = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Wallpy-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: work) }
                let movie = try await Self.convertAnimation(source, in: work)
                return try await importMovie(movie, name: name)
            }
            return try importImage(source)
        }
        return try await importMovie(source, name: name)
    }

    private func importMovie(_ source: URL, name: String) async throws -> Video {
        let asset = AVURLAsset(url: source)
        guard try await asset.load(.isPlayable) else { throw ImportError.notPlayable(source.lastPathComponent) }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ImportError.noVideoTrack(source.lastPathComponent)
        }
        let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
        let size = naturalSize.applying(transform)
        let duration = try await asset.load(.duration).seconds

        let id = UUID()
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
        let fileName = "\(id.uuidString).\(ext)"
        let destination = directory.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: source, to: destination)

        let video = Video(id: id, name: name, fileName: fileName, addedAt: Date(),
                          width: Int(abs(size.width)), height: Int(abs(size.height)),
                          duration: duration.isFinite ? duration : 0)
        await writeThumbnail(for: AVURLAsset(url: destination), duration: duration, to: video.thumbnailURL)
        return video
    }

    nonisolated static func isAnimated(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    /// GIF/APNG → H.264 MP4. Transparent pixels become black; dimensions are made even for yuv420p.
    nonisolated static func convertAnimation(_ source: URL, in work: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let output = work.appendingPathComponent("animation.mp4")
        try await ToolProcess.run(.ffmpeg, [
            "-hide_banner", "-nostats", "-y", "-i", source.path,
            "-vf", "format=rgba,premultiply=inplace=1,scale=trunc(iw/2)*2:trunc(ih/2)*2:flags=lanczos,setsar=1,format=yuv420p",
            "-an", "-c:v", "libx264", "-crf", "18", "-preset", "slow", "-tune", "animation",
            "-movflags", "+faststart", output.path,
        ])
        return output
    }

    private func importImage(_ source: URL) throws -> Video {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              var width = props[kCGImagePropertyPixelWidth] as? Int,
              var height = props[kCGImagePropertyPixelHeight] as? Int else {
            throw ImportError.unreadableImage(source.lastPathComponent)
        }
        // EXIF orientations 5–8 are rotated 90°.
        if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 {
            swap(&width, &height)
        }

        let id = UUID()
        let fileName = "\(id.uuidString).\(source.pathExtension.lowercased())"
        let destination = directory.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: source, to: destination)

        let video = Video(id: id, name: source.deletingPathExtension().lastPathComponent, fileName: fileName,
                          addedAt: Date(), width: width, height: height, duration: 0, kind: .image)
        if let thumb = ImageLoader.downsample(destination, maxPixelSize: 640),
           let data = NSBitmapImageRep(cgImage: thumb).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            try? data.write(to: video.thumbnailURL, options: .atomic)
        }
        return video
    }

    private func writeThumbnail(for asset: AVAsset, duration: Double, to url: URL) async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let time = CMTime(seconds: min(1, duration / 2), preferredTimescale: 600)
        guard let (cgImage, _) = try? await generator.image(at: time) else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func rename(_ video: Video, to name: String) {
        guard let index = videos.firstIndex(of: video) else { return }
        videos[index].name = name
        persist()
    }

    func delete(_ video: Video) {
        let settings = Settings.shared
        settings.assignments = settings.assignments.filter { $0.value != video.id }
        try? FileManager.default.removeItem(at: video.url)
        try? FileManager.default.removeItem(at: video.thumbnailURL)
        videos.removeAll { $0.id == video.id }
        persist()
    }

    func isInUse(_ video: Video) -> Bool {
        Settings.shared.assignments.values.contains(video.id)
    }
}

enum ImageLoader {
    /// Decodes an image no larger than `maxPixelSize` on its long side, with EXIF rotation applied.
    nonisolated static func downsample(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
