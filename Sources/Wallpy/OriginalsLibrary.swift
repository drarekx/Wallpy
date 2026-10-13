import AppKit
import AVFoundation

/// A full-length source video (usually a long download) kept so more loops can be cut from it later.
struct OriginalVideo: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    let fileName: String
    let addedAt: Date
    let duration: Double
    let width: Int
    let height: Int
    let bytes: Int64

    var url: URL { OriginalsLibrary.directory.appendingPathComponent(fileName) }
    var thumbnailURL: URL { OriginalsLibrary.directory.appendingPathComponent("\(id.uuidString).jpg") }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    var durationLabel: String {
        let s = Int(duration.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

@MainActor
final class OriginalsLibrary: ObservableObject {
    static let shared = OriginalsLibrary()

    nonisolated static let directory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Wallpy/Originals", isDirectory: true)
    }()

    @Published private(set) var originals: [OriginalVideo] = []
    private var indexURL: URL { Self.directory.appendingPathComponent("originals.json") }

    private init() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let list = try? JSONDecoder().decode([OriginalVideo].self, from: data) {
            originals = list.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(originals) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    var totalBytes: Int64 { originals.reduce(0) { $0 + $1.bytes } }

    /// Moves `file` (from a temporary download folder) into the originals folder.
    func keep(file: URL, name: String, info: SourceInfo) {
        let id = UUID()
        let ext = file.pathExtension.isEmpty ? "mp4" : file.pathExtension.lowercased()
        let destination = Self.directory.appendingPathComponent("\(id.uuidString).\(ext)")
        do {
            try FileManager.default.moveItem(at: file, to: destination)
        } catch {
            NSLog("Wallpy: could not keep original: \(error)")
            return
        }
        let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let original = OriginalVideo(id: id, name: name, fileName: destination.lastPathComponent, addedAt: Date(),
                                     duration: info.duration, width: info.width, height: info.height, bytes: bytes)
        originals.insert(original, at: 0)
        persist()

        Task {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: destination))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            let time = CMTime(seconds: min(10, info.duration / 3), preferredTimescale: 600)
            if let (image, _) = try? await generator.image(at: time),
               let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                try? data.write(to: original.thumbnailURL, options: .atomic)
                objectWillChange.send()
            }
        }
    }

    func rename(_ original: OriginalVideo, to name: String) {
        guard let index = originals.firstIndex(of: original) else { return }
        originals[index].name = name
        persist()
    }

    func delete(_ original: OriginalVideo) {
        try? FileManager.default.removeItem(at: original.url)
        try? FileManager.default.removeItem(at: original.thumbnailURL)
        originals.removeAll { $0.id == original.id }
        persist()
    }

    /// Opens the original in the loop editor.
    func edit(_ original: OriginalVideo) async -> Bool {
        guard let info = await SourceInfo.load(original.url) else { return false }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wallpy-\(UUID().uuidString)", isDirectory: true)
        EditorWindowController.open(url: original.url, info: info, name: original.name, workDir: work)
        return true
    }
}
