import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            VideosTab()
                .tabItem { Label("Biblioteca", systemImage: "film.stack") }
                .tag(0)
            OriginalsTab()
                .tabItem { Label("Originales", systemImage: "film") }
                .tag(2)
            SettingsTab()
                .tabItem { Label("Ajustes", systemImage: "gearshape") }
                .tag(1)
        }
        .padding(.top, 8)
        .frame(minWidth: 720, minHeight: 480)
    }
}

// MARK: - Library

private struct VideosTab: View {
    @ObservedObject private var library = VideoLibrary.shared
    @ObservedObject private var manager = WallpaperManager.shared
    @ObservedObject private var settings = Settings.shared
    @State private var selection: Video.ID?
    @State private var dropTargeted = false
    @State private var errors: [String] = []
    @State private var pendingDelete: Video?
    @State private var editorSource: EditorSource?

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if library.videos.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(library.videos) { video in
                            VideoCard(video: video,
                                      selected: selection == video.id,
                                      screensUsing: screensUsing(video))
                                .onTapGesture { selection = video.id }
                                .onTapGesture(count: 2) { manager.setVideoOnAllScreens(video) }
                                .contextMenu { menu(for: video) }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .sheet(item: $editorSource) { source in
            EditorSheet(source: source) { editorSource = nil }
        }
        .alert("No se pudieron añadir algunos vídeos",
               isPresented: Binding(get: { !errors.isEmpty }, set: { if !$0 { errors = [] } })) {
            Button("OK") { errors = [] }
        } message: {
            Text(errors.joined(separator: "\n"))
        }
        .confirmationDialog("Este fondo está en uso. ¿Seguro que quieres eliminarlo?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } })) {
            Button("Eliminar", role: .destructive) {
                if let video = pendingDelete { library.delete(video) }
                pendingDelete = nil
            }
        }
    }

    private var selectedVideo: Video? { library.video(id: selection) }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                openPanel()
            } label: {
                Label("Añadir vídeos…", systemImage: "plus")
            }
            Button {
                editorSource = .youtube
            } label: {
                Label("Desde YouTube…", systemImage: "arrow.down.circle")
            }
            if library.importing > 0 {
                ProgressView().controlSize(.small)
                Text("Importando…").foregroundStyle(.secondary)
            }
            Spacer()
            if let video = selectedVideo {
                Button("Poner en todas las pantallas") { manager.setVideoOnAllScreens(video) }
                if manager.screens.count > 1 {
                    Menu("Poner en…") {
                        ForEach(manager.screens) { screen in
                            Button(screen.name) { manager.setVideo(video, onScreen: screen.id) }
                        }
                    }
                    .fixedSize()
                }
                Button("Recortar…") { editorSource = .library(video) }
                    .help("Elegir el tramo del bucle y optimizar el vídeo")
                Button(role: .destructive) {
                    requestDelete(video)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Eliminar de la biblioteca")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Arrastra vídeos aquí o haz clic en «Añadir vídeos…»")
                .font(.headline)
            Text("Formatos: MP4, MOV, M4V (lo que reproduzca QuickTime). Recomendado HD o superior.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Añadir vídeos…") { openPanel() }
                Button("Desde YouTube…") { editorSource = .youtube }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func menu(for video: Video) -> some View {
        Button("Poner en todas las pantallas") { manager.setVideoOnAllScreens(video) }
        if manager.screens.count > 1 {
            ForEach(manager.screens) { screen in
                Button("Poner en \(screen.name)") { manager.setVideo(video, onScreen: screen.id) }
            }
        }
        Divider()
        Button("Recortar y optimizar…") { editorSource = .library(video) }
        Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([video.url]) }
        Button("Eliminar", role: .destructive) { requestDelete(video) }
    }

    private func screensUsing(_ video: Video) -> [String] {
        manager.screens.filter { settings.assignments[$0.id] == video.id }.map(\.name)
    }

    private func requestDelete(_ video: Video) {
        if library.isInUse(video) {
            pendingDelete = video
        } else {
            library.delete(video)
            if selection == video.id { selection = nil }
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = VideoLibrary.allowedTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Añadir"
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { importURLs(urls) }
        return true
    }

    private func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            let failures = await library.importVideos(urls)
            if !failures.isEmpty { errors = failures }
            // Nothing on screen yet: use the first import right away.
            if settings.assignments.isEmpty, let first = library.videos.first {
                manager.setVideoOnAllScreens(first)
            }
        }
    }
}

private struct VideoCard: View {
    let video: Video
    let selected: Bool
    let screensUsing: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Thumbnail(url: video.thumbnailURL)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    if !screensUsing.isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .font(.title2)
                            .padding(6)
                            .help("En uso: \(screensUsing.joined(separator: ", "))")
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
                }
            Text(video.name)
                .lineLimit(1)
                .font(.callout.weight(.medium))
            HStack {
                Text(video.resolutionLabel)
                if video.width < 1280 && video.height < 1280 {
                    Image(systemName: "exclamationmark.triangle")
                        .help("Resolución baja: se verá pixelado")
                }
                Spacer()
                Text(video.durationLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

private struct Thumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "film").foregroundStyle(.secondary)
            }
        }
        .task(id: url) { image = NSImage(contentsOf: url) }
    }
}

// MARK: - Originals

/// Full-length downloads kept to cut more loops from later.
private struct OriginalsTab: View {
    @ObservedObject private var originals = OriginalsLibrary.shared
    @State private var pendingDelete: OriginalVideo?
    @State private var opening: UUID?

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Vídeos completos guardados para sacar más fondos")
                    .foregroundStyle(.secondary)
                Spacer()
                if !originals.originals.isEmpty {
                    Text("Ocupan \(ByteCountFormatter.string(fromByteCount: originals.totalBytes, countStyle: .file))")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if originals.originals.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("Aún no hay originales").font(.headline)
                    Text("Al descargar de YouTube, activa «Guardar en Originales» en el editor para conservar el vídeo completo.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(originals.originals) { original in
                            card(original)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .confirmationDialog("¿Eliminar «\(pendingDelete?.name ?? "")»? Los fondos ya creados a partir de él no se borran.",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Eliminar", role: .destructive) {
                if let original = pendingDelete { originals.delete(original) }
                pendingDelete = nil
            }
        }
    }

    private func card(_ original: OriginalVideo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Thumbnail(url: original.thumbnailURL)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if opening == original.id { ProgressView() }
                }
            Text(original.name).lineLimit(1).font(.callout.weight(.medium))
            HStack {
                Text("\(original.width)×\(original.height) · \(original.durationLabel)")
                Spacer()
                Text(original.sizeLabel)
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button {
                    open(original)
                } label: {
                    Label("Crear fondos", systemImage: "scissors")
                }
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([original.url]) } label: {
                    Image(systemName: "folder")
                }
                .help("Mostrar en Finder")
                Button(role: .destructive) { pendingDelete = original } label: { Image(systemName: "trash") }
                    .help("Eliminar original")
            }
            .controlSize(.small)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(original) }
    }

    private func open(_ original: OriginalVideo) {
        opening = original.id
        Task { @MainActor in
            _ = await originals.edit(original)
            opening = nil
        }
    }
}

// MARK: - Settings

private struct SettingsTab: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var manager = WallpaperManager.shared
    @ObservedObject private var library = VideoLibrary.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var autoUpdate = Updater.shared.autoCheck
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Form {
            Section("Pantallas") {
                DisplayArrangement(screens: manager.screens)
                    .frame(height: 140)
                ForEach(manager.screens) { screen in
                    Picker(screen.name, selection: assignment(for: screen.id)) {
                        Text("Ninguno").tag(UUID?.none)
                        ForEach(library.videos) { video in
                            Text(video.name).tag(UUID?.some(video.id))
                        }
                    }
                }
            }

            Section("Sonido") {
                HStack {
                    Image(systemName: "speaker.slash")
                    Slider(value: $settings.volume, in: 0...1)
                    Image(systemName: "speaker.wave.3")
                }
                Text("Silenciado por defecto. Si hay varias pantallas, el sonido suena en todas.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Ahorro de energía") {
                Toggle("Pausar cuando el escritorio está tapado por ventanas", isOn: $settings.pauseWhenCovered)
                Toggle("Pausar con batería", isOn: $settings.pauseOnBattery)
                Toggle("Pausar con batería baja", isOn: $settings.pauseOnLowBattery)
                if settings.pauseOnLowBattery {
                    Stepper("Por debajo de \(settings.lowBatteryLevel) %",
                            value: $settings.lowBatteryLevel, in: 5...90, step: 5)
                }
                if let level = manager.power.batteryLevel {
                    Text("Batería: \(level) % · \(manager.power.onBattery ? "con batería" : "conectado")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Escritorio") {
                Toggle("Ocultar iconos del escritorio", isOn: $settings.hideDesktopIcons)
                Toggle("Abrir al iniciar sesión", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        LoginItem.setEnabled(enabled)
                        launchAtLogin = LoginItem.isEnabled
                    }
            }

            Section("Actualizaciones") {
                Toggle("Buscar actualizaciones automáticamente", isOn: $autoUpdate)
                    .onChange(of: autoUpdate) { _, value in updater.autoCheck = value }
                HStack {
                    Text("Versión \(Updater.currentVersion)").foregroundStyle(.secondary)
                    Spacer()
                    if updater.state != .idle { ProgressView().controlSize(.small) }
                    Button("Buscar ahora") { Task { await updater.check(userInitiated: true) } }
                        .disabled(updater.state != .idle)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func assignment(for screenID: String) -> Binding<UUID?> {
        Binding(get: { settings.assignments[screenID] },
                set: { settings.assignments[screenID] = $0 })
    }
}

/// Miniature of the display layout with each screen's current wallpaper.
private struct DisplayArrangement: View {
    let screens: [ScreenInfo]
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var library = VideoLibrary.shared

    var body: some View {
        GeometryReader { geo in
            let bounds = screens.reduce(NSRect.null) { $0.union($1.frame) }
            let scale = bounds.isEmpty ? 1 : min(geo.size.width / bounds.width, geo.size.height / bounds.height) * 0.9
            let offsetX = (geo.size.width - bounds.width * scale) / 2
            let offsetY = (geo.size.height - bounds.height * scale) / 2
            ZStack(alignment: .topLeading) {
                ForEach(screens) { screen in
                    let w = screen.frame.width * scale
                    let h = screen.frame.height * scale
                    let x = (screen.frame.minX - bounds.minX) * scale + offsetX
                    // AppKit's y axis grows upward; SwiftUI's grows downward.
                    let y = (bounds.maxY - screen.frame.maxY) * scale + offsetY
                    ZStack {
                        if let video = library.video(id: settings.assignments[screen.id]) {
                            Thumbnail(url: video.thumbnailURL)
                        } else {
                            Color.gray.opacity(0.3)
                        }
                        Text(screen.name)
                            .font(.caption2.weight(.semibold))
                            .padding(4)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .frame(width: w - 4, height: h - 4)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .position(x: x + w / 2, y: y + h / 2)
                }
            }
        }
    }
}
