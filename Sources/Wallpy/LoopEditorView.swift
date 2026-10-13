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
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundStyle(Theme.warn)
                    Text(message).textSelection(.enabled).foregroundStyle(Theme.text2).frame(maxWidth: 520)
                    HStack(spacing: 8) {
                        Button(tr("Cerrar")) { close() }.buttonStyle(.wallpySecondary)
                        if case .youtube = source {
                            Button(tr("Reintentar")) { step = .link }.buttonStyle(.wallpyPrimary)
                        }
                    }
                }
                .padding(32)
            }
        }
        .background(Color(hex: 0x1C1C1F))
        .foregroundStyle(Theme.text)
        .font(.system(size: 13))
        .preferredColorScheme(.dark)
        .onAppear {
            if case .youtube = source, link.isEmpty,
               let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               text.contains("youtu") {
                link = text  // Pre-fill if a YouTube link is already on the clipboard.
            }
            if case .library(let video) = source { prepare(file: video.url, name: video.name + tr(" (bucle)")) }
        }
    }

    private var linkForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Theme.navSelected)
                    .frame(width: 36, height: 36)
                    .overlay { Image(systemName: "arrow.down.to.line").foregroundStyle(Theme.accentText) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Descargar de YouTube")).font(.system(size: 16, weight: .semibold))
                    Text(tr("Al terminar se abre el editor para elegir el bucle."))
                        .font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Enlace del vídeo")).foregroundStyle(Theme.text2)
                HStack(spacing: 8) {
                    WallpyTextField(placeholder: "https://www.youtube.com/watch?v=…", text: $link, onSubmit: startDownload)
                    Button(tr("Pegar")) {
                        if let text = NSPasteboard.general.string(forType: .string) {
                            link = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    .buttonStyle(.wallpySecondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Calidad máxima")).foregroundStyle(Theme.text2)
                SegmentedControl(options: [("1080p", 1080), ("1440p", 1440), ("4K", 2160)],
                                 selection: $maxHeight, expand: true)
            }
            if !ExternalTool.missing.isEmpty {
                Label(tr("Falta: %@. Instala con «brew install yt-dlp ffmpeg».", ExternalTool.missing.map(\.rawValue).joined(separator: ", ")),
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warn)
            }
            Text(tr("Descarga solo vídeos tuyos, con licencia libre o con permiso de su autor."))
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
            HStack(spacing: 8) {
                Spacer()
                Button(tr("Cancelar")) { close() }
                    .buttonStyle(WallpyButtonStyle(kind: .ghost, height: 34))
                    .keyboardShortcut(.cancelAction)
                Button(tr("Descargar"), action: startDownload)
                    .buttonStyle(WallpyButtonStyle(kind: .primary, height: 34))
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
        step = .working(tr("Descargando…"), 0)
        job = Task {
            do {
                let result = try await YouTubeDownloader.download(trimmed, maxHeight: maxHeight, into: workDir) { value in
                    Task { @MainActor in step = .working(tr("Descargando…"), value) }
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
        step = .working(tr("Analizando vídeo…"), nil)
        job = Task {
            guard let info = await SourceInfo.load(file) else {
                step = .failed(tr("No se pudo leer el vídeo."))
                return
            }
            if info.isPreviewable {
                openEditor(file, info, name)
                return
            }
            let converted = workDir.appendingPathComponent("preview.mp4")
            step = .working(tr("Convirtiendo a un formato compatible…"), 0)
            do {
                try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                try await LoopExporter.makePreviewable(source: file, to: converted, duration: info.duration) { value in
                    Task { @MainActor in step = .working(tr("Convirtiendo a un formato compatible…"), value) }
                }
                if let convertedInfo = await SourceInfo.load(converted) {
                    openEditor(converted, convertedInfo, name)
                } else {
                    step = .failed(tr("No se pudo convertir el vídeo."))
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
        VStack(alignment: .leading, spacing: 14) {
            Text(message).font(.system(size: 14, weight: .semibold))
            if let progress {
                ProgressView(value: progress).tint(Theme.accent)
                Text("\(Int(progress * 100)) %").monospacedText().foregroundStyle(Theme.text2)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
            HStack {
                Spacer()
                Button(tr("Cancelar"), action: onCancel).buttonStyle(WallpyButtonStyle(kind: .secondary, height: 30))
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
