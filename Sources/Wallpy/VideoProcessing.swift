import AVFoundation
import Foundation

// MARK: - YouTube download

struct DownloadResult {
    let file: URL
    let title: String
}

/// Title, length and thumbnail of a video, fetched without downloading it.
struct RemoteVideoInfo {
    let title: String
    let duration: Double?
    let thumbnail: URL?
}

enum YouTubeDownloader {
    static func info(_ link: String) async throws -> RemoteVideoInfo {
        let collector = OutputCollector()
        try await ToolProcess.run(.ytDlp, [
            link, "--no-playlist", "--skip-download", "--no-warnings",
            "--print", "TITLE %(title)s",
            "--print", "DURATION %(duration)s",
            "--print", "THUMB %(thumbnail)s",
        ]) { line in
            if line.hasPrefix("TITLE ") { collector.set(title: String(line.dropFirst(6))) }
            if line.hasPrefix("DURATION ") { collector.set(duration: Double(line.dropFirst(9))) }
            if line.hasPrefix("THUMB ") { collector.set(file: String(line.dropFirst(6))) }
        }
        return RemoteVideoInfo(title: collector.title ?? tr("Vídeo de YouTube"),
                               duration: collector.duration,
                               thumbnail: collector.file.flatMap(URL.init(string:)))
    }

    /// Downloads the best stream up to `maxHeight` into `directory`.
    /// `section` (seconds) downloads only that part; the cut lands on the nearest keyframes.
    static func download(_ link: String, maxHeight: Int, section: ClosedRange<Double>? = nil, into directory: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> DownloadResult {
        guard let ffmpeg = ExternalTool.ffmpeg.url else { throw ToolError.notInstalled(.ffmpeg) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var sectionArgs: [String] = []
        if let section {
            sectionArgs = ["--download-sections", String(format: "*%.2f-%.2f", section.lowerBound, section.upperBound)]
        }

        let collector = OutputCollector()
        try await ToolProcess.run(.ytDlp, sectionArgs + [
            link,
            "--no-playlist",
            "-f", "bv*[height<=\(maxHeight)]+ba/b[height<=\(maxHeight)]/bv*+ba/b",
            "-S", "res:\(maxHeight)",
            "--merge-output-format", "mp4",
            "--ffmpeg-location", ffmpeg.path,
            "-o", directory.appendingPathComponent("%(id)s.%(ext)s").path,
            "--print", "before_dl:TITLE %(title)s",
            "--print", "after_move:FILE %(filepath)s",
            "--progress", "--newline",
            "--progress-template", "download:PROGRESS %(progress._percent_str)s",
        ]) { line in
            if line.hasPrefix("PROGRESS ") {
                let number = line.dropFirst(9).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
                if let value = Double(number) { progress(value / 100) }
            } else if line.hasPrefix("TITLE ") {
                collector.set(title: String(line.dropFirst(6)))
            } else if line.hasPrefix("FILE ") {
                collector.set(file: String(line.dropFirst(5)))
            }
        }
        guard let path = collector.file else { throw ToolError.failed(tr("yt-dlp no devolvió ningún archivo.")) }
        return DownloadResult(file: URL(fileURLWithPath: path), title: collector.title ?? tr("Vídeo de YouTube"))
    }
}

/// "90", "1:30", "1:02:30", "1:30.5" ↔ seconds.
enum Timecode {
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for (index, part) in parts.enumerated() {
            guard let value = Double(part), value >= 0 else { return nil }
            // Minutes and seconds after the first field must be below 60.
            if index > 0 && value >= 60 { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var title: String?
    private(set) var file: String?
    private(set) var duration: Double?
    func set(duration: Double?) { lock.lock(); self.duration = duration; lock.unlock() }
    func set(title: String) { lock.lock(); self.title = title; lock.unlock() }
    func set(file: String) { lock.lock(); self.file = file; lock.unlock() }
}

// MARK: - Source inspection

struct SourceInfo {
    let duration: Double
    let fps: Double
    let width: Int
    let height: Int
    let hasAudio: Bool
    /// AVFoundation can decode it, so it can be previewed in the editor.
    let isPreviewable: Bool

    static func load(_ url: URL) async -> SourceInfo? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let fps = (try? await track.load(.nominalFrameRate)) ?? 30
        let (size, transform) = (try? await track.load(.naturalSize, .preferredTransform)) ?? (.zero, .identity)
        let oriented = size.applying(transform)
        let audio = (try? await asset.loadTracks(withMediaType: .audio).isEmpty == false) ?? false
        let playable = (try? await asset.load(.isPlayable)) ?? false
        let decodable = (try? await track.load(.isDecodable)) ?? false
        return SourceInfo(duration: duration, fps: Double(fps > 0 ? fps : 30),
                          width: Int(abs(oriented.width)), height: Int(abs(oriented.height)),
                          hasAudio: audio, isPreviewable: playable && decodable)
    }
}

// MARK: - Trim + optimise

enum ExportQuality: String, CaseIterable, Identifiable {
    case high = "Alta", medium = "Media", low = "Ligera"
    var id: String { rawValue }
    var label: String { tr(rawValue) }
    /// Encoder arguments. Constant-quality (-q:v) needs Apple Silicon; Intel Macs get a target bitrate.
    func encoderArguments(shortSide: Int) -> [String] {
        #if arch(arm64)
        return ["-q:v", "\(videoToolboxQuality)"]
        #else
        let mbps: Double
        switch shortSide {
        case 2000...: mbps = [ExportQuality.high: 30, .medium: 20, .low: 12][self]!
        case 1300...: mbps = [ExportQuality.high: 16, .medium: 11, .low: 7][self]!
        default: mbps = [ExportQuality.high: 10, .medium: 7, .low: 4.5][self]!
        }
        return ["-b:v", "\(Int(mbps * 1000))k", "-maxrate", "\(Int(mbps * 1500))k", "-bufsize", "\(Int(mbps * 2000))k"]
        #endif
    }

    /// VideoToolbox constant-quality value (1–100).
    var videoToolboxQuality: Int {
        switch self {
        case .high: return 68
        case .medium: return 58
        case .low: return 48
        }
    }
}

struct ExportOptions {
    var start: Double
    var end: Double
    /// Longest side limit for the short edge (1080 = 1080p, 2160 = 4K); nil keeps the original.
    var maxShortSide: Int? = 2160
    var quality: ExportQuality = .high
    var keepAudio = false
    /// Seconds blended from the end of the clip into its start so the loop has no visible jump.
    var crossfade: Double = 0.5
    /// Output frame rate; nil keeps the source rate.
    var fps: Int? = nil

    var length: Double { max(0, end - start) }
    var outputDuration: Double { crossfade > 0 ? length - crossfade : length }
}

enum LoopExporter {
    /// Re-encodes only the selected segment as HEVC (hardware) into `output`.
    ///
    /// With a crossfade of `d` seconds, the segment [start, end] is rendered as
    /// A = [start+d, end] fading into B = [start, start+d]. The last frame of the
    /// result is the frame at start+d, which is exactly where A begins, so the
    /// loop restarts without a jump.
    static func export(source: URL, info: SourceInfo, options: ExportOptions, to output: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let fade = options.crossfade > 0 && options.length > options.crossfade * 2.5 ? options.crossfade : 0
        let fps = Double(options.fps ?? Int(info.fps.rounded()))
        let keepAudio = options.keepAudio && info.hasAudio

        var chain = "setpts=PTS-STARTPTS,fps=\(fmt(fps))"
        if let limit = options.maxShortSide {
            // Cap the short side (height for landscape, width for portrait); never upscale.
            chain += ",scale='if(gte(iw,ih),-2,min(iw,\(limit)))':'if(gte(iw,ih),min(ih,\(limit)),-2)':flags=lanczos"
        }
        chain += ",format=yuv420p,settb=AVTB"

        var args = ["-hide_banner", "-nostats", "-y"]
        let filter: String
        if fade > 0 {
            args += ["-ss", fmt(options.start + fade), "-t", fmt(options.length - fade), "-i", source.path]
            args += ["-ss", fmt(options.start), "-t", fmt(fade), "-i", source.path]
            var graph = "[0:v]\(chain)[a];[1:v]\(chain)[b];"
            graph += "[a][b]xfade=transition=fade:duration=\(fmt(fade)):offset=\(fmt(options.length - 2 * fade))[v]"
            if keepAudio { graph += ";[0:a][1:a]acrossfade=d=\(fmt(fade))[au]" }
            filter = graph
        } else {
            args += ["-ss", fmt(options.start), "-t", fmt(options.length), "-i", source.path]
            filter = "[0:v]\(chain)[v]" + (keepAudio ? ";[0:a]asetpts=PTS-STARTPTS[au]" : "")
        }
        args += ["-filter_complex", filter, "-map", "[v]"]
        args += keepAudio ? ["-map", "[au]", "-c:a", "aac", "-b:a", "160k"] : ["-an"]
        let sourceShortSide = min(info.width, info.height)
        let shortSide = options.maxShortSide.map { min($0, sourceShortSide) } ?? sourceShortSide
        args += ["-c:v", "hevc_videotoolbox"] + options.quality.encoderArguments(shortSide: shortSide)
        args += ["-tag:v", "hvc1", "-movflags", "+faststart", "-progress", "pipe:1", output.path]

        let total = max(options.outputDuration, 0.1)
        try await ToolProcess.run(.ffmpeg, args) { line in
            if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) {
                progress(min(1, us / 1_000_000 / total))
            }
        }
    }

    /// Converts a file AVFoundation cannot decode (VP9, some AV1…) into HEVC so it can be previewed.
    static func makePreviewable(source: URL, to output: URL,
                                duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await ToolProcess.run(.ffmpeg, [
            "-hide_banner", "-nostats", "-y", "-i", source.path,
            "-c:v", "hevc_videotoolbox"] + ExportQuality.high.encoderArguments(shortSide: 2160) + [
            "-tag:v", "hvc1",
            "-c:a", "aac", "-b:a", "192k", "-progress", "pipe:1", output.path,
        ]) { line in
            if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)), duration > 0 {
                progress(min(1, us / 1_000_000 / duration))
            }
        }
    }

    private static func fmt(_ value: Double) -> String { String(format: "%.3f", value) }
}
