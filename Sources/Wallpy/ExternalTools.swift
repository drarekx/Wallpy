import Foundation

/// Command-line tools the app drives: yt-dlp for downloads, ffmpeg for trimming
/// and re-encoding. They are not bundled; install with `brew install yt-dlp ffmpeg`.
enum ExternalTool: String {
    case ytDlp = "yt-dlp"
    case ffmpeg
    case ffprobe

    private static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                                      NSHomeDirectory() + "/.local/bin"]

    var url: URL? {
        // Apps launched from Finder get a minimal PATH, so look in the usual places first.
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in Self.searchPaths + envPaths {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(rawValue)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static var missing: [ExternalTool] { [.ytDlp, .ffmpeg, .ffprobe].filter { $0.url == nil } }
}

enum ToolError: LocalizedError {
    case notInstalled(ExternalTool)
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notInstalled(let tool): return tr("No se encuentra %@. Instálalo con: brew install %@", tool.rawValue, tool.rawValue)
        case .failed(let message): return message
        case .cancelled: return tr("Cancelado.")
        }
    }
}

/// Runs a tool, streaming its output line by line. Cancelling the Swift task
/// terminates the process.
final class ToolProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var tail: [String] = []
    /// Only touched from the pipe's readability handler, which runs serially.
    private var buffer = Data()

    /// Runs `tool` and calls `onLine` (on a background queue) for each stdout/stderr line.
    static func run(_ tool: ExternalTool, _ arguments: [String],
                    onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        guard let executable = tool.url else { throw ToolError.notInstalled(tool) }
        let runner = ToolProcess()
        try await withTaskCancellationHandler {
            try await runner.start(executable: executable, arguments: arguments, onLine: onLine)
        } onCancel: {
            runner.process.terminate()
        }
    }

    private func start(executable: URL, arguments: [String],
                       onLine: @escaping @Sendable (String) -> Void) async throws {
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            self.buffer.append(chunk)
            // ffmpeg and yt-dlp use both \n and \r to separate progress updates.
            while let index = self.buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let lineData = self.buffer[self.buffer.startIndex..<index]
                self.buffer.removeSubrange(self.buffer.startIndex...index)
                guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
                self.remember(line)
                onLine(line)
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { [weak self] process in
                pipe.fileHandleForReading.readabilityHandler = nil
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: ToolError.cancelled)
                } else if process.terminationStatus != 0 {
                    let detail = self?.lastLines() ?? ""
                    continuation.resume(throwing: ToolError.failed(
                        tr("%@ terminó con error %d.\n%@", executable.lastPathComponent, Int(process.terminationStatus), detail)))
                } else {
                    continuation.resume()
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func remember(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        tail.append(line)
        if tail.count > 6 { tail.removeFirst() }
    }

    private func lastLines() -> String {
        lock.lock(); defer { lock.unlock() }
        return tail.joined(separator: "\n")
    }
}
