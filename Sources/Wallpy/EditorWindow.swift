import AVKit
import SwiftUI

// MARK: - Window

/// Large, resizable editor window (dark, monitor + timeline + inspector).
/// Owns the temporary work folder and deletes it when the window closes.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var open: Set<EditorWindowController> = []

    private let model: EditorModel
    private let workDir: URL
    private var keyMonitor: Any?

    /// `canKeepOriginal`: the source is a temporary download that may be saved to Originals on close.
    static func open(url: URL, info: SourceInfo, name: String, workDir: URL, canKeepOriginal: Bool = false) {
        let controller = EditorWindowController(url: url, info: info, name: name, workDir: workDir,
                                                canKeepOriginal: canKeepOriginal)
        open.insert(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(url: URL, info: SourceInfo, name: String, workDir: URL, canKeepOriginal: Bool) {
        self.workDir = workDir
        model = EditorModel(url: url, info: info, name: name, workDir: workDir, canKeepOriginal: canKeepOriginal)

        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: max(1100, visible.width * 0.85), height: max(720, visible.height * 0.85))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = tr("Editor de bucle — %@", name)
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 1000, height: 680)
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.delegate = self
        let hosting = NSHostingController(rootView: EditorRootView(model: model) { [weak window] in
            window?.performClose(nil)
        })
        // Let the window, not SwiftUI's ideal size, decide how big the editor is.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(size)
        window.center()
        installKeyMonitor()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        model.teardown()
        if model.canKeepOriginal && model.keepOriginal {
            OriginalsLibrary.shared.keep(file: model.url, name: model.baseName, info: model.info)
        }
        try? FileManager.default.removeItem(at: workDir)
        Self.open.remove(self)
    }

    /// Premiere-style shortcuts. Ignored while typing in a text field.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  !(self.window?.firstResponder is NSText) else { return event }
            let shift = event.modifierFlags.contains(.shift)
            if event.modifierFlags.contains(.command) { return event }
            switch event.keyCode {
            case 49: model.togglePlay()                                  // space
            case 123: shift ? model.nudge(seconds: -1) : model.step(frames: -1)  // ←
            case 124: shift ? model.nudge(seconds: 1) : model.step(frames: 1)    // →
            case 126: model.goToIn()                                     // ↑
            case 125: model.goToOut()                                    // ↓
            default:
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "i": model.markIn()
                case "o": model.markOut()
                case "n": model.addClip()
                case "l": model.loopRange.toggle()
                case "j": model.nudge(seconds: -5)
                case "k": model.pause()
                case "+", "=": model.zoom(by: 1.5)
                case "-": model.zoom(by: 1 / 1.5)
                default: return event
                }
            }
            return nil
        }
    }
}

// MARK: - Model

/// One loop to cut from the source.
struct LoopClip: Identifiable, Equatable {
    enum Status: Equatable { case pending, queued, exporting(Double), done, failed(String) }

    let id = UUID()
    var name: String
    var inPoint: Double
    var outPoint: Double
    var status: Status = .pending

    var length: Double { max(0, outPoint - inPoint) }
}

@MainActor
final class EditorModel: ObservableObject {
    let url: URL
    let info: SourceInfo
    let player: AVPlayer
    let thumbnails: ThumbnailCache
    let canKeepOriginal: Bool
    let baseName: String
    private let workDir: URL

    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    /// In/Out of the selected clip.
    @Published var inPoint: Double { didSet { syncSelectedClip() } }
    @Published var outPoint: Double { didSet { syncSelectedClip() } }
    /// Play only between In and Out, looping (preview of the wallpaper).
    @Published var loopRange = true
    /// Visible part of the timeline, in seconds.
    @Published var viewStart: Double = 0
    @Published var viewLength: Double

    @Published var clips: [LoopClip]
    @Published private(set) var selectedClipID: UUID
    @Published var options: ExportOptions
    @Published var setAsWallpaper = true
    @Published var keepOriginal: Bool
    /// True while the export queue runs.
    @Published private(set) var isExporting = false
    private var exportTask: Task<Void, Never>?

    private var timeObserver: Any?
    private var seekTarget: Double?
    private var seeking = false

    var duration: Double { info.duration }
    var frameDuration: Double { 1 / max(info.fps, 1) }
    var rangeLength: Double { max(0, outPoint - inPoint) }
    var minViewLength: Double { min(duration, 2) }
    var selectedIndex: Int? { clips.firstIndex { $0.id == selectedClipID } }
    var pendingClips: [LoopClip] { clips.filter { $0.status != .done && $0.length >= 1 } }
    var originalSizeLabel: String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    init(url: URL, info: SourceInfo, name: String, workDir: URL, canKeepOriginal: Bool) {
        self.url = url
        self.info = info
        self.workDir = workDir
        self.canKeepOriginal = canKeepOriginal
        baseName = name
        // Long downloads are worth keeping by default to cut more loops later.
        keepOriginal = canKeepOriginal && info.duration > 120
        player = AVPlayer(url: url)
        player.isMuted = true
        thumbnails = ThumbnailCache(url: url, duration: info.duration)
        let first = LoopClip(name: name, inPoint: 0, outPoint: min(info.duration, 15))
        clips = [first]
        selectedClipID = first.id
        inPoint = first.inPoint
        outPoint = first.outPoint
        viewLength = info.duration
        options = ExportOptions(start: 0, end: first.outPoint,
                                maxShortSide: min(info.width, info.height) > 2160 ? 2160 : nil)

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        thumbnails.requestOverview()
    }

    func teardown() {
        exportTask?.cancel()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    private func tick(_ time: Double) {
        guard !seeking else { return }
        currentTime = time
        if isPlaying, loopRange, rangeLength > 0, time >= outPoint || time < inPoint - 0.5 {
            seek(to: inPoint)
        }
        // Keep the playhead on screen while playing (page-follow, like an NLE).
        if isPlaying, time > viewStart + viewLength || time < viewStart {
            setView(start: time - viewLength * 0.1)
        }
    }

    // MARK: Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        if loopRange, currentTime >= outPoint - 0.05 || currentTime < inPoint { seek(to: inPoint) }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func step(frames: Int) {
        pause()
        seek(to: currentTime + Double(frames) * frameDuration)
    }

    func nudge(seconds: Double) { seek(to: currentTime + seconds) }
    func goToIn() { seek(to: inPoint) }
    func goToOut() { seek(to: max(inPoint, outPoint - frameDuration)) }

    /// Frame-accurate seek that coalesces requests while scrubbing.
    func seek(to time: Double) {
        let clamped = min(max(0, time), duration)
        currentTime = clamped
        seekTarget = clamped
        guard !seeking else { return }
        performPendingSeek()
    }

    private func performPendingSeek() {
        guard let target = seekTarget else { seeking = false; return }
        seekTarget = nil
        seeking = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.seeking = false
                if self.seekTarget != nil { self.performPendingSeek() }
            }
        }
    }

    // MARK: In / Out

    func markIn() { setIn(currentTime) }
    func markOut() { setOut(currentTime) }

    func setIn(_ time: Double) {
        inPoint = min(max(0, time), max(0, outPoint - 0.5))
    }

    func setOut(_ time: Double) {
        outPoint = max(min(duration, time), min(duration, inPoint + 0.5))
    }

    // MARK: Clips

    private func syncSelectedClip() {
        guard let index = selectedIndex else { return }
        guard clips[index].inPoint != inPoint || clips[index].outPoint != outPoint else { return }
        clips[index].inPoint = inPoint
        clips[index].outPoint = outPoint
        // Changing a finished clip means it should be exported again.
        if clips[index].status == .done { clips[index].status = .pending }
        if case .failed = clips[index].status { clips[index].status = .pending }
    }

    func selectClip(_ id: UUID) {
        guard let clip = clips.first(where: { $0.id == id }) else { return }
        selectedClipID = id
        // Assign without clamping against the previous clip's points.
        inPoint = clip.inPoint
        outPoint = clip.outPoint
        seek(to: clip.inPoint)
        if clip.inPoint < viewStart || clip.outPoint > viewStart + viewLength { zoomToRange() }
    }

    /// New clip starting at the playhead, as long as the current one.
    func addClip() {
        let length = max(1, rangeLength > 0 ? rangeLength : 15)
        var start = currentTime
        if start + length > duration { start = max(0, duration - length) }
        let clip = LoopClip(name: "\(baseName) \(clips.count + 1)", inPoint: start,
                            outPoint: min(duration, start + length))
        clips.append(clip)
        selectClip(clip.id)
    }

    func removeClip(_ id: UUID) {
        guard clips.count > 1, let index = clips.firstIndex(where: { $0.id == id }) else { return }
        clips.remove(at: index)
        if id == selectedClipID { selectClip(clips[min(index, clips.count - 1)].id) }
    }

    func renameSelected(_ name: String) {
        guard let index = selectedIndex else { return }
        clips[index].name = name
    }

    // MARK: Timeline view

    func setView(start: Double, length: Double? = nil) {
        let len = min(duration, max(minViewLength, length ?? viewLength))
        viewLength = len
        viewStart = min(max(0, start), max(0, duration - len))
        thumbnails.request(from: viewStart, to: viewStart + viewLength)
    }

    /// Zooms around the playhead.
    func zoom(by factor: Double) {
        let newLength = min(duration, max(minViewLength, viewLength / factor))
        let anchor = (currentTime >= viewStart && currentTime <= viewStart + viewLength) ? currentTime : viewStart + viewLength / 2
        let ratio = viewLength > 0 ? (anchor - viewStart) / viewLength : 0.5
        setView(start: anchor - newLength * ratio, length: newLength)
    }

    /// 0 = whole clip, 1 = maximum zoom (log scale).
    var zoomLevel: Double {
        get {
            guard duration > minViewLength else { return 0 }
            return log(viewLength / duration) / log(minViewLength / duration)
        }
        set {
            guard duration > minViewLength else { return }
            let length = duration * pow(minViewLength / duration, newValue)
            zoom(by: viewLength / length)
        }
    }

    func zoomToRange() {
        let pad = rangeLength * 0.15
        setView(start: inPoint - pad, length: rangeLength + pad * 2)
    }

    // MARK: Export

    func exportSelected() {
        guard let index = selectedIndex else { return }
        export([clips[index].id])
    }

    func exportAll() { export(pendingClips.map(\.id)) }

    /// Exports the given clips one after another; the editor stays open.
    private func export(_ ids: [UUID]) {
        guard !isExporting, !ids.isEmpty else { return }
        pause()
        isExporting = true
        for id in ids { updateStatus(id, .queued) }
        let url = self.url, info = self.info, workDir = self.workDir

        exportTask = Task {
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            for id in ids {
                // Read the clip when its turn comes, so late edits to queued clips are used.
                guard !Task.isCancelled, let clip = clips.first(where: { $0.id == id }) else { break }
                var options = self.options
                options.start = clip.inPoint
                options.end = clip.outPoint
                let output = workDir.appendingPathComponent("\(UUID().uuidString).mp4")
                updateStatus(id, .exporting(0))
                do {
                    try await LoopExporter.export(source: url, info: info, options: options, to: output) { value in
                        Task { @MainActor [weak self] in
                            if case .exporting = self?.clips.first(where: { $0.id == id })?.status {
                                self?.updateStatus(id, .exporting(value))
                            }
                        }
                    }
                    let library = VideoLibrary.shared
                    let errors = await library.importVideos([output])
                    try? FileManager.default.removeItem(at: output)
                    if let error = errors.first { throw ToolError.failed(error) }
                    if let video = library.videos.first {
                        let name = clip.name.trimmingCharacters(in: .whitespaces)
                        library.rename(video, to: name.isEmpty ? video.name : name)
                        if setAsWallpaper, let renamed = library.videos.first {
                            WallpaperManager.shared.setVideoOnAllScreens(renamed)
                        }
                    }
                    updateStatus(id, .done)
                } catch {
                    let cancelled = error is CancellationError || {
                        if let toolError = error as? ToolError, case .cancelled = toolError { return true }
                        return false
                    }()
                    updateStatus(id, cancelled ? .pending : .failed(error.localizedDescription))
                    if cancelled { break }
                }
            }
            for clip in clips where clip.status == .queued { updateStatus(clip.id, .pending) }
            isExporting = false
        }
    }

    private func updateStatus(_ id: UUID, _ status: LoopClip.Status) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[index].status = status
    }

    func cancelExport() { exportTask?.cancel() }

    // MARK: Formatting

    /// HH:MM:SS:FF, like Premiere.
    func timecode(_ seconds: Double) -> String {
        let fps = Int(info.fps.rounded())
        let totalFrames = Int((max(0, seconds) * info.fps).rounded())
        let frames = fps > 0 ? totalFrames % fps : 0
        let totalSeconds = fps > 0 ? totalFrames / fps : Int(seconds)
        return String(format: "%02d:%02d:%02d:%02d", totalSeconds / 3600, totalSeconds / 60 % 60, totalSeconds % 60, frames)
    }
}

// MARK: - Thumbnails

/// Filmstrip frames, generated on demand for whatever part of the timeline is visible.
@MainActor
final class ThumbnailCache: ObservableObject {
    @Published private(set) var images: [Int: CGImage] = [:]
    private(set) var sortedKeys: [Int] = []
    let quantum: Double

    private let generator: AVAssetImageGenerator
    private let duration: Double
    private var pending: [Int] = []
    private var worker: Task<Void, Never>?

    init(url: URL, duration: Double) {
        self.duration = duration
        // Long clips get a coarser grid so the cache stays small.
        quantum = max(0.25, duration / 2000)
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = CMTime(seconds: quantum / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: quantum / 2, preferredTimescale: 600)
    }

    func requestOverview() { request(from: 0, to: duration, count: 60) }

    func request(from start: Double, to end: Double, count: Int = 40) {
        guard end > start else { return }
        let step = (end - start) / Double(count)
        let keys = (0..<count).map { key(for: start + step * (Double($0) + 0.5)) }
        // Visible range first, replacing whatever was queued for an older view.
        pending = Array(NSOrderedSet(array: keys.filter { images[$0] == nil })) as? [Int] ?? []
        startWorker()
    }

    func key(for time: Double) -> Int { Int((min(max(0, time), duration) / quantum).rounded()) }

    /// Closest generated frame to `time`.
    func image(near time: Double) -> CGImage? {
        let target = key(for: time)
        if let exact = images[target] { return exact }
        guard !sortedKeys.isEmpty else { return nil }
        var low = 0, high = sortedKeys.count - 1
        while low < high {
            let mid = (low + high) / 2
            if sortedKeys[mid] < target { low = mid + 1 } else { high = mid }
        }
        let candidates = [sortedKeys[low], sortedKeys[max(0, low - 1)]]
        let best = candidates.min { abs($0 - target) < abs($1 - target) }!
        return images[best]
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, !self.pending.isEmpty {
                let key = self.pending.removeFirst()
                if self.images[key] != nil { continue }
                let time = CMTime(seconds: Double(key) * self.quantum, preferredTimescale: 600)
                if let (image, _) = try? await self.generator.image(at: time) {
                    self.images[key] = image
                    let index = self.sortedKeys.firstIndex { $0 > key } ?? self.sortedKeys.count
                    self.sortedKeys.insert(key, at: index)
                }
            }
            self?.worker = nil
        }
    }
}

// MARK: - Views

private enum EditorColors {
    static let panel = Theme.sidebar
    static let background = Theme.editorBackground
    static let track = Theme.control
    static let range = Theme.accent
    static let playhead = Theme.playhead
}

struct EditorRootView: View {
    @ObservedObject var model: EditorModel
    let onClose: () -> Void
    @ObservedObject private var localizer = Localizer.shared

    var body: some View {
        VStack(spacing: 0) {
            EditorHeader(model: model)
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    MonitorView(model: model)
                    Rectangle().fill(Theme.line).frame(height: 1)
                    TransportBar(model: model)
                    Rectangle().fill(Theme.line).frame(height: 1)
                    TimelineView(model: model, thumbnails: model.thumbnails)
                }
                Rectangle().fill(Theme.line).frame(width: 1)
                InspectorView(model: model, onClose: onClose)
                    .frame(width: 330)
            }
        }
        .id(localizer.language)
        .background(EditorColors.background)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
            }
}

private struct EditorHeader: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "scissors").foregroundStyle(Theme.accentText)
            Text(tr("Editor de bucle")).fontWeight(.semibold)
            Text(model.baseName).foregroundStyle(Theme.text3).lineLimit(1)
            Spacer()
            Text("\(model.info.width)×\(model.info.height) · \(Int(model.info.fps.rounded())) fps · \(model.timecode(model.duration))")
                .monospacedText(size: 11)
                .foregroundStyle(Theme.text3)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Theme.sidebar)
    }
}

private struct MonitorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            PlayerViewRepresentable(player: model.player)
            HStack(spacing: 8) {
                if model.currentTime >= model.inPoint && model.currentTime <= model.outPoint {
                    Text(tr("DENTRO DEL BUCLE"))
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(EditorColors.range.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                }
                Text("\(model.info.width)×\(model.info.height) · \(Int(model.info.fps.rounded())) fps")
                    .font(.caption2).foregroundStyle(.white.opacity(0.7))
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.togglePlay() }
    }
}

private struct TransportBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 14) {
            Text(model.timecode(model.currentTime))
                .font(.system(size: 20, weight: .medium, design: .monospaced))
                .foregroundStyle(EditorColors.range)
                .frame(width: 150, alignment: .leading)

            Spacer()

            Group {
                iconButton("arrow.left.to.line", tr("Ir a la entrada (↑)")) { model.goToIn() }
                iconButton("backward.frame", tr("Fotograma anterior (←)")) { model.step(frames: -1) }
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.window)
                        .frame(width: 44, height: 34)
                        .background(Theme.text, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .help(tr("Reproducir / pausa (Espacio)"))
                iconButton("forward.frame", tr("Fotograma siguiente (→)")) { model.step(frames: 1) }
                iconButton("arrow.right.to.line", tr("Ir a la salida (↓)")) { model.goToOut() }
            }

            Divider().frame(height: 20)

            Button { model.markIn() } label: { Label(tr("Entrada"), systemImage: "chevron.left.to.line") }
                .help(tr("Marcar entrada (I)"))
            Button { model.markOut() } label: { Label(tr("Salida"), systemImage: "chevron.right.to.line") }
                .help(tr("Marcar salida (O)"))
            Toggle(isOn: $model.loopRange) { Label(tr("Repetir tramo"), systemImage: "repeat") }
                .toggleStyle(.button)
                .help(tr("Reproducir solo entre entrada y salida (L)"))

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(tr("Duración del bucle")).font(.caption2).foregroundStyle(.secondary)
                Text(String(format: "%.2f s", model.options.crossfade > 0 && model.rangeLength > model.options.crossfade * 2.5
                            ? model.rangeLength - model.options.crossfade : model.rangeLength))
                    .font(.system(.body, design: .monospaced))
            }
            .frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(EditorColors.panel)
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 24) }
            .buttonStyle(.borderless)
            .help(help)
    }
}

// MARK: Timeline

private struct TimelineView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var thumbnails: ThumbnailCache

    private enum DragTarget { case scrub, select, inHandle, outHandle, range(Double, Double, Double) }
    @State private var drag: DragTarget?
    @State private var wasPlaying = false

    private let rulerHeight: CGFloat = 24
    private let laneHeight: CGFloat = 20
    private let stripHeight: CGFloat = 76
    private var stripTop: CGFloat { rulerHeight + laneHeight }
    private var totalHeight: CGFloat { rulerHeight + laneHeight + stripHeight }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .topLeading) {
                    ruler(width: width)
                    clipLane(width: width)
                        .offset(y: rulerHeight)
                    filmstrip(width: width)
                        .offset(y: stripTop)
                    rangeOverlay(width: width)
                        .offset(y: stripTop)
                    playhead(width: width)
                }
                .frame(width: width, height: totalHeight, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .gesture(timelineDrag(width: width))
                .onAppear { model.setView(start: model.viewStart) }
            }
            .frame(height: totalHeight)

            HStack(spacing: 10) {
                OverviewBar(model: model)
                    .frame(height: 14)
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.zoomLevel }, set: { model.zoomLevel = $0 }), in: 0...1)
                    .frame(width: 140)
                    .controlSize(.small)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                Button(tr("Ajustar al tramo")) { model.zoomToRange() }
                    .controlSize(.small)
                Button(tr("Ver todo")) { model.setView(start: 0, length: model.duration) }
                    .controlSize(.small)
            }
            Text(tr("Arrastra para buscar · bordes azules: entrada/salida · ⌥ arrastrar: mover tramo · clic en la franja de tramos: seleccionar · N nuevo tramo · I / O marcan · Espacio reproduce · ← → fotograma · ⇧← ⇧→ 1 s · + / − zoom"))
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(EditorColors.panel)
    }

    private func x(_ time: Double, _ width: CGFloat) -> CGFloat {
        guard model.viewLength > 0 else { return 0 }
        return CGFloat((time - model.viewStart) / model.viewLength) * width
    }

    private func time(at x: CGFloat, _ width: CGFloat) -> Double {
        model.viewStart + Double(x / max(width, 1)) * model.viewLength
    }

    private func ruler(width: CGFloat) -> some View {
        let step = Self.tickStep(viewLength: model.viewLength, width: width)
        let first = (model.viewStart / step).rounded(.up) * step
        let ticks = stride(from: first, through: model.viewStart + model.viewLength, by: step).map { $0 }
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(EditorColors.track.opacity(0.6))
            ForEach(ticks, id: \.self) { tick in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.label(tick, step: step))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Rectangle().fill(Color.secondary.opacity(0.6)).frame(width: 1, height: 6)
                }
                .offset(x: x(tick, width))
            }
        }
        .frame(width: width, height: rulerHeight)
    }

    /// One bar per clip; the selected one is highlighted.
    private func clipLane(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(EditorColors.background)
            ForEach(Array(model.clips.enumerated()), id: \.element.id) { index, clip in
                let selected = clip.id == model.selectedClipID
                let startX = x(clip.inPoint, width)
                let barWidth = max(4, x(clip.outPoint, width) - startX)
                HStack(spacing: 4) {
                    Image(systemName: clip.status == .done ? "checkmark.circle.fill" : "\(index + 1).circle.fill")
                        .font(.system(size: 11))
                    Text(clip.name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(width: barWidth, height: laneHeight - 4, alignment: .leading)
                .background((selected ? EditorColors.range : Color(white: 0.35)).opacity(clip.status == .done ? 0.6 : 1),
                            in: RoundedRectangle(cornerRadius: 3))
                .clipped()
                .offset(x: startX, y: 2)
            }
        }
        .frame(width: width, height: laneHeight)
        .allowsHitTesting(false)
    }

    private func filmstrip(width: CGFloat) -> some View {
        let aspect = CGFloat(max(model.info.width, 1)) / CGFloat(max(model.info.height, 1))
        let slotWidth = max(40, stripHeight * aspect)
        let count = max(1, Int((width / slotWidth).rounded(.up)))
        return HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                let center = time(at: (CGFloat(index) + 0.5) * slotWidth, width)
                ZStack {
                    EditorColors.track
                    if let image = thumbnails.image(near: center) {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                    }
                }
                .frame(width: slotWidth, height: stripHeight)
                .clipped()
                .overlay(alignment: .trailing) { Rectangle().fill(Color.black.opacity(0.5)).frame(width: 1) }
            }
        }
        .frame(width: width, height: stripHeight, alignment: .leading)
        .clipped()
    }

    private func rangeOverlay(width: CGFloat) -> some View {
        let inX = x(model.inPoint, width)
        let outX = x(model.outPoint, width)
        return ZStack(alignment: .topLeading) {
            // Dim everything outside the loop.
            Rectangle().fill(Color.black.opacity(0.6))
                .frame(width: max(0, min(width, inX)), height: stripHeight)
            Rectangle().fill(Color.black.opacity(0.6))
                .frame(width: max(0, width - max(0, outX)), height: stripHeight)
                .offset(x: max(0, outX))
            // Other clips: faint outlines.
            ForEach(model.clips.filter { $0.id != model.selectedClipID }) { clip in
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: max(2, x(clip.outPoint, width) - x(clip.inPoint, width)), height: stripHeight)
                    .offset(x: x(clip.inPoint, width))
            }
            // Selected loop box with handles.
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(EditorColors.range, lineWidth: 2)
                .frame(width: max(2, outX - inX), height: stripHeight)
                .offset(x: inX)
            handle(edge: .leading).offset(x: inX - 6)
            handle(edge: .trailing).offset(x: outX - 6)
        }
        .frame(width: width, height: stripHeight, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func handle(edge: HorizontalEdge) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(EditorColors.range)
            .frame(width: 12, height: stripHeight)
            .overlay {
                Image(systemName: edge == .leading ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
    }

    private func playhead(width: CGFloat) -> some View {
        let px = x(model.currentTime, width)
        return VStack(spacing: 0) {
            Triangle().fill(EditorColors.playhead).frame(width: 12, height: 8)
            Rectangle().fill(EditorColors.playhead).frame(width: 2, height: totalHeight - 8)
        }
        .offset(x: px - 6)
        .allowsHitTesting(false)
        .opacity(px >= -6 && px <= width + 6 ? 1 : 0)
    }

    private func timelineDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == nil {
                    let startX = value.startLocation.x
                    let inX = x(model.inPoint, width), outX = x(model.outPoint, width)
                    wasPlaying = model.isPlaying
                    let y = value.startLocation.y
                    if y > rulerHeight && y < stripTop {
                        // Clip lane: select the clip under the pointer.
                        let t = time(at: startX, width)
                        if let clip = model.clips.first(where: { t >= $0.inPoint && t <= $0.outPoint }) {
                            model.selectClip(clip.id)
                        }
                        drag = .select
                        return
                    }
                    if y > stripTop && abs(startX - inX) < 10 {
                        drag = .inHandle
                    } else if y > stripTop && abs(startX - outX) < 10 {
                        drag = .outHandle
                    } else if y > stripTop, NSEvent.modifierFlags.contains(.option),
                              startX > inX, startX < outX {
                        // ⌥-drag inside the box slides the whole loop.
                        drag = .range(time(at: startX, width), model.inPoint, model.outPoint)
                    } else {
                        drag = .scrub
                    }
                    model.pause()
                }
                let t = time(at: value.location.x, width)
                switch drag {
                case .inHandle:
                    model.setIn(t); model.seek(to: model.inPoint)
                case .outHandle:
                    model.setOut(t); model.seek(to: model.outPoint)
                case .select:
                    break
                case .range(let anchor, let originalIn, let originalOut):
                    let length = originalOut - originalIn
                    let newIn = min(max(0, originalIn + t - anchor), model.duration - length)
                    model.setOut(newIn + length); model.setIn(newIn); model.setOut(newIn + length)
                    model.seek(to: model.inPoint)
                default:
                    model.seek(to: t)
                }
            }
            .onEnded { _ in
                if case .scrub = drag, wasPlaying { model.play() }
                drag = nil
            }
    }

    static func tickStep(viewLength: Double, width: CGFloat) -> Double {
        let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let minSpacing: Double = 80
        for step in steps where step / viewLength * Double(width) >= minSpacing { return step }
        return steps.last!
    }

    static func label(_ time: Double, step: Double) -> String {
        let total = Int(time)
        let base = total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
        if step < 1 { return base + String(format: ".%d", Int((time * 10).rounded()) % 10) }
        return base
    }
}

/// Whole-clip mini map: loop range, playhead and the visible window (drag to pan).
private struct OverviewBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let scale = model.duration > 0 ? w / CGFloat(model.duration) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(EditorColors.track)
                Rectangle().fill(EditorColors.range.opacity(0.55))
                    .frame(width: max(2, CGFloat(model.rangeLength) * scale))
                    .offset(x: CGFloat(model.inPoint) * scale)
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.white.opacity(0.8), lineWidth: 1.5)
                    .frame(width: max(8, CGFloat(model.viewLength) * scale))
                    .offset(x: CGFloat(model.viewStart) * scale)
                Rectangle().fill(EditorColors.playhead)
                    .frame(width: 2)
                    .offset(x: CGFloat(model.currentTime) * scale)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let center = Double(value.location.x / max(w, 1)) * model.duration
                model.setView(start: center - model.viewLength / 2)
            })
        }
        .help(tr("Mapa del vídeo completo: arrastra para moverte por la línea de tiempo"))
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

// MARK: Inspector

private struct InspectorView: View {
    @ObservedObject var model: EditorModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(Array(model.clips.enumerated()), id: \.element.id) { index, clip in
                        ClipRow(model: model, clip: clip, number: index + 1)
                    }
                    Button {
                        model.addClip()
                    } label: {
                        Label(tr("Nuevo tramo en el cabezal (N)"), systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text(tr("Tramos (%d)", model.clips.count))
                } footer: {
                    Text(tr("Haz tantos fondos como quieras del mismo vídeo. Cada tramo se exporta como un fondo independiente."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let index = model.selectedIndex {
                    Section(tr("Tramo seleccionado")) {
                        TextField(tr("Nombre"), text: Binding(
                            get: { model.clips[safe: index]?.name ?? "" },
                            set: { model.renameSelected($0) }))
                        LabeledContent(tr("Entrada")) {
                            Text(model.timecode(model.inPoint)).font(.system(.body, design: .monospaced))
                        }
                        LabeledContent(tr("Salida")) {
                            Text(model.timecode(model.outPoint)).font(.system(.body, design: .monospaced))
                        }
                        LabeledContent(tr("Duración")) {
                            Text(String(format: "%.2f s", model.rangeLength)).font(.system(.body, design: .monospaced))
                        }
                    }
                }

                Section(tr("Bucle y optimización (todos los tramos)")) {
                    Picker(tr("Fundido"), selection: $model.options.crossfade) {
                        Text(tr("Sin fundido")).tag(0.0)
                        Text(tr("0,5 s")).tag(0.5)
                        Text("1 s").tag(1.0)
                        Text("2 s").tag(2.0)
                    }
                    Picker(tr("Resolución"), selection: $model.options.maxShortSide) {
                        Text(tr("Original")).tag(Int?.none)
                        Text("4K").tag(Int?.some(2160))
                        Text("1440p").tag(Int?.some(1440))
                        Text("1080p").tag(Int?.some(1080))
                    }
                    Picker(tr("Calidad"), selection: $model.options.quality) {
                        ForEach(ExportQuality.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle(tr("Limitar a 30 fps"), isOn: Binding(
                        get: { model.options.fps == 30 }, set: { model.options.fps = $0 ? 30 : nil }))
                        .disabled(model.info.fps <= 30.5)
                    Toggle(tr("Mantener sonido"), isOn: $model.options.keepAudio)
                        .disabled(!model.info.hasAudio)
                    Toggle(tr("Poner como fondo al terminar"), isOn: $model.setAsWallpaper)
                }

                if model.canKeepOriginal {
                    Section(tr("Vídeo original")) {
                        Toggle(tr("Guardar en «Originales» al cerrar"), isOn: $model.keepOriginal)
                        Text(model.keepOriginal
                             ? tr("Podrás volver a abrirlo para sacar más fondos sin descargarlo otra vez (%@).", model.originalSizeLabel)
                             : tr("Se borrará al cerrar el editor (%@).", model.originalSizeLabel))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            VStack(spacing: 10) {
                if model.isExporting {
                    let done = model.clips.filter { $0.status == .done }.count
                    Text(tr("Creando fondos… (%d hechos)", done)).font(.caption)
                    Button(tr("Cancelar exportación")) { model.cancelExport() }
                        .frame(maxWidth: .infinity)
                } else {
                    Button {
                        model.exportAll()
                    } label: {
                        Label(model.pendingClips.count > 1 ? tr("Crear %d fondos", model.pendingClips.count) : tr("Crear fondo"),
                              systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.pendingClips.isEmpty)
                    if model.pendingClips.count > 1 {
                        Button(tr("Crear solo el seleccionado")) { model.exportSelected() }
                            .disabled((model.selectedIndex.map { model.clips[$0].length } ?? 0) < 1)
                    }
                    Button(model.clips.contains { $0.status == .done } ? tr("Cerrar") : tr("Cerrar sin guardar"), action: onClose)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(EditorColors.panel)
    }
}

private struct ClipRow: View {
    @ObservedObject var model: EditorModel
    let clip: LoopClip
    let number: Int

    var body: some View {
        let selected = clip.id == model.selectedClipID
        HStack(spacing: 8) {
            statusIcon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.name).lineLimit(1).font(.callout.weight(selected ? .semibold : .regular))
                Text("\(model.timecode(clip.inPoint)) → \(String(format: "%.1f s", clip.length))")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                if case .exporting(let progress) = clip.status {
                    ProgressView(value: progress).controlSize(.small)
                }
                if case .failed(let message) = clip.status {
                    Text(message).font(.caption2).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                }
            }
            Spacer()
            if model.clips.count > 1 && !model.isExporting {
                Button { model.removeClip(clip.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(tr("Quitar tramo"))
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(selected ? EditorColors.range.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { model.selectClip(clip.id) }
    }

    @ViewBuilder private var statusIcon: some View {
        switch clip.status {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .exporting: ProgressView().controlSize(.mini)
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .pending: Image(systemName: "\(number).circle").foregroundStyle(.secondary)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: Player

private struct PlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
