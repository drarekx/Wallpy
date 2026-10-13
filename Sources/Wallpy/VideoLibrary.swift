import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct Video: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    let fileName: String
    let addedAt: Date
    let width: Int
    let height: Int
    let duration: Double

    var url: URL { VideoLibrary.directory.appendingPathComponent(fileName) }
    var thumbnailURL: URL { VideoLibrary.directory.appendingPathComponent("\(id.uuidString).jpg") }
    var resolutionLabel: String { "\(width)×\(height)" }
    var durationLabel: String {
        let s = Int(duration.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

enum ImportError: LocalizedError {
    case notPlayable(String)
    case noVideoTrack(String)

    var errorDescription: String? {
        switch self {
        case .notPlayable(let name): return "«\(name)» no se puede reproducir con AVFoundation."
        case .noVideoTrack(let name): return "«\(name)» no contiene pista de vídeo."
        }
    }
}

/// Videos the user has imported. Files are copied into Application Support so
/// the wallpaper keeps working if the original is moved or deleted.
@MainActor
final class VideoLibrary: ObservableObject {
    static let shared = VideoLibrary()
    static let allowedTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie, .appleProtectedMPEG4Video, .movie]

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
        let name = source.deletingPathExtension().lastPathComponent
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
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: source, to: destination)

        let video = Video(id: id, name: name, fileName: fileName, addedAt: Date(),
                          width: Int(abs(size.width)), height: Int(abs(size.height)),
                          duration: duration.isFinite ? duration : 0)
        await writeThumbnail(for: AVURLAsset(url: destination), duration: duration, to: video.thumbnailURL)
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
