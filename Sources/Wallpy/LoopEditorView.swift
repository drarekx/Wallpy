import AVKit
import SwiftUI

/// What the sheet starts from: a YouTube link to download, or a video already in the library.
enum EditorSource: Identifiable {
    case youtube
    case library(Video)

    var id: String {
        switch self {
        case .youtube: return "youtube"
        case .library(let video): return video.id.uuidString
        }
    }
}

/// Download (optional) → preview → pick loop range → export into the library.
struct EditorSheet: View {
    let source: EditorSource
    let onClose: () -> Void

    private enum Step {
        case link
        case working(String, Double?)
        case editing(URL, SourceInfo, String)
        case failed(String)
    }

    @State private var step: Step = .link
    @State private var link = ""
    @State private var maxHeight = 2160
    @State private var job: Task<Void, Never>?
    @State private var workDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("Wallpy-\(UUID().uuidString)", isDirectory: true)

    var body: some View {
        Group {
            switch step {
            case .link:
                linkForm
            case .working(let message, let progress):
                WorkingView(message: message, progress: progress) { cancel() }
            case .editing:
                ProgressView()
            case .failed(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text(message).textSelection(.enabled).frame(maxWidth: 520)
                    HStack {
                        Button("Cerrar") { close() }
                        if case .youtube = source { Button("Reintentar") { step = .link } }
                    }
                }
                .padding(32)
            }
        }
        .onAppear {
            if case .youtube = source, link.isEmpty,
               let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               text.contains("youtu") {
                link = text  // Pre-fill if a YouTube link is already on the clipboard.
            }
            if case .library(let video) = source { prepare(file: video.url, name: video.name + " (bucle)") }
        }
    }

    private var linkForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Descargar de YouTube").font(.title2.weight(.semibold))
            HStack {
                TextField("https://www.youtube.com/watch?v=…", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(startDownload)
                Button("Pegar") {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        link = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
            Picker("Calidad máxima", selection: $maxHeight) {
                Text("1080p").tag(1080)
                Text("1440p").tag(1440)
                Text("4K").tag(2160)
            }
            .pickerStyle(.segmented)
            if !ExternalTool.missing.isEmpty {
                Label("Falta: \(ExternalTool.missing.map(\.rawValue).joined(separator: ", ")). Instala con «brew install yt-dlp ffmpeg».",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Text("Descarga solo vídeos tuyos, con licencia libre o con permiso del autor.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancelar") { close() }.keyboardShortcut(.cancelAction)
                Button("Descargar", action: startDownload)
                    .keyboardShortcut(.defaultAction)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || !ExternalTool.missing.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func startDownload() {
        let trimmed = link.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        step = .working("Descargando…", 0)
        job = Task {
            do {
                let result = try await YouTubeDownloader.download(trimmed, maxHeight: maxHeight, into: workDir) { value in
                    Task { @MainActor in step = .working("Descargando…", value) }
                }
                prepare(file: result.file, name: result.title)
            } catch is CancellationError {
            } catch ToolError.cancelled {
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }

    /// Loads the file; transcodes it first if AVFoundation can't preview it.
    private func prepare(file: URL, name: String) {
        step = .working("Analizando vídeo…", nil)
        job = Task {
            guard let info = await SourceInfo.load(file) else {
                step = .failed("No se pudo leer el vídeo.")
                return
            }
            if info.isPreviewable {
                openEditor(file, info, name)
                return
            }
            let converted = workDir.appendingPathComponent("preview.mp4")
            step = .working("Convirtiendo a un formato compatible…", 0)
            do {
                try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                try await LoopExporter.makePreviewable(source: file, to: converted, duration: info.duration) { value in
                    Task { @MainActor in step = .working("Convirtiendo a un formato compatible…", value) }
                }
                if let convertedInfo = await SourceInfo.load(converted) {
                    openEditor(converted, convertedInfo, name)
                } else {
                    step = .failed("No se pudo convertir el vídeo.")
                }
            } catch is CancellationError {
            } catch ToolError.cancelled {
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }

    /// Hands the file (and the temporary folder) to the full editor window and closes the sheet.
    private func openEditor(_ file: URL, _ info: SourceInfo, _ name: String) {
        step = .editing(file, info, name)
        var downloaded = false
        if case .youtube = source { downloaded = true }
        EditorWindowController.open(url: file, info: info, name: name, workDir: workDir,
                                    canKeepOriginal: downloaded)
        onClose()
    }

    private func cancel() {
        job?.cancel()
        close()
    }

    private func close() {
        job?.cancel()
        try? FileManager.default.removeItem(at: workDir)
        onClose()
    }
}

private struct WorkingView: View {
    let message: String
    let progress: Double?
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(message).font(.headline)
            if let progress {
                ProgressView(value: progress).frame(width: 360)
                Text("\(Int(progress * 100)) %").monospacedDigit().foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            Button("Cancelar", action: onCancel)
        }
        .padding(32)
        .frame(minWidth: 460)
    }
}
