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
    @State private var info: RemoteVideoInfo?
    @State private var infoState: InfoState = .none
    @State private var onlySection = false
    @State private var fromText = "0:00"
    @State private var toText = ""

    private enum InfoState: Equatable { case none, loading, failed }
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
            infoCard
            if info != nil {
                sectionPicker
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
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || !ExternalTool.missing.isEmpty
                              || (onlySection && section == nil))
            }
        }
        .padding(24)
        .frame(width: 520)
        .task(id: link) { await loadInfo() }
    }

    // MARK: Video info and section

    @ViewBuilder private var infoCard: some View {
        switch infoState {
        case .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(tr("Buscando el vídeo…")).foregroundStyle(Theme.text2)
            }
        case .failed:
            Text(tr("No se encontró el vídeo. Revisa el enlace."))
                .font(.system(size: 12)).foregroundStyle(Theme.warn)
        case .none:
            if let info {
                HStack(spacing: 12) {
                    AsyncImage(url: info.thumbnail) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Theme.field
                    }
                    .frame(width: 112, height: 63)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(info.title).fontWeight(.medium).lineLimit(2)
                        if let duration = info.duration {
                            Text(Timecode.format(duration)).monospacedText().foregroundStyle(Theme.text2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var sectionPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(tr("Bajar solo un trozo"), isOn: $onlySection)
                .toggleStyle(.switch)
                .tint(Theme.accentFill)
                .onChange(of: onlySection) { _, on in
                    if on && toText.isEmpty, let duration = info?.duration {
                        toText = Timecode.format(min(duration, 60))
                    }
                }
            if onlySection {
                HStack(spacing: 10) {
                    Text(tr("Desde")).foregroundStyle(Theme.text2)
                    WallpyTextField(placeholder: "0:00", text: $fromText).frame(width: 100)
                    Text(tr("Hasta")).foregroundStyle(Theme.text2)
                    WallpyTextField(placeholder: info?.duration.map(Timecode.format) ?? "1:00", text: $toText).frame(width: 100)
                    Spacer()
                }
                Text(sectionMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(section == nil ? Theme.warn : Theme.text3)
            }
        }
    }

    /// The chosen part, or nil if the fields don't make a valid range.
    private var section: ClosedRange<Double>? {
        guard let start = Timecode.parse(fromText), let end = Timecode.parse(toText), end > start + 0.5 else { return nil }
        if let duration = info?.duration, end > duration + 0.5 { return nil }
        return start...end
    }

    private var sectionMessage: String {
        if let section {
            return tr("Se descargará un trozo de %@. Puede incluir uno o dos segundos de más en los bordes.",
                      Timecode.format(section.upperBound - section.lowerBound))
        }
        guard Timecode.parse(fromText) != nil, let end = Timecode.parse(toText) else {
            return tr("Escribe los tiempos como 1:30 o 1:02:30.")
        }
        if let duration = info?.duration, end > duration + 0.5 {
            return tr("El final pasa de la duración del vídeo (%@).", Timecode.format(duration))
        }
        return tr("El inicio tiene que ser anterior al final.")
    }

    private func loadInfo() async {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        info = nil
        guard trimmed.hasPrefix("http"), ExternalTool.ytDlp.url != nil else {
            infoState = .none
            return
        }
        // Wait until typing or pasting settles.
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        infoState = .loading
        do {
            let fetched = try await YouTubeDownloader.info(trimmed)
            guard !Task.isCancelled else { return }
            info = fetched
            infoState = .none
        } catch {
            if !Task.isCancelled { infoState = .failed }
        }
    }

    private func startDownload() {
        let trimmed = link.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let range = onlySection ? section : nil
        // yt-dlp only reports a percentage for whole videos; a part shows an activity indicator.
        step = .working(range == nil ? tr("Descargando…") : tr("Descargando el trozo…"), range == nil ? 0 : nil)
        job = Task {
            do {
                // For a part, show how much has arrived so far.
                let sizeWatcher = range == nil ? nil : Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        let bytes = Self.folderSize(workDir)
                        if bytes > 0, case .working = step {
                            step = .working(tr("Descargando el trozo… %@ descargados",
                                               ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)), nil)
                        }
                    }
                }
                defer { sizeWatcher?.cancel() }
                let result = try await YouTubeDownloader.download(trimmed, maxHeight: maxHeight, section: range,
                                                                  into: workDir) { value in
                    guard range == nil else { return }
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

    private static func folderSize(_ url: URL) -> Int64 {
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let file = files?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
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
