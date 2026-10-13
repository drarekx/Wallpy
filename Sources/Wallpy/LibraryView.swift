import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum LibrarySection: Hashable {
    case library, originals, settings
}

/// Main window: sidebar + the selected section, in the editor's dark style.
struct LibraryView: View {
    @State private var section: LibrarySection = .library
    @State private var editorSource: EditorSource?
    @ObservedObject private var localizer = Localizer.shared

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: $section)
            Rectangle().fill(Theme.line).frame(width: 1)
            Group {
                switch section {
                case .library: LibraryPane(editorSource: $editorSource)
                case .originals: OriginalsPane(editorSource: $editorSource)
                case .settings: SettingsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(localizer.language)
        .background(Theme.window)
        .foregroundStyle(Theme.text)
        .font(.system(size: 13))
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .frame(minWidth: 960, minHeight: 600)
        .sheet(item: $editorSource) { source in
            EditorSheet(source: source) { editorSource = nil }
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Binding var section: LibrarySection
    @ObservedObject private var library = VideoLibrary.shared
    @ObservedObject private var originals = OriginalsLibrary.shared
    @ObservedObject private var manager = WallpaperManager.shared
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.accentFill)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: "play.rectangle").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    }
                Text("Wallpy").font(.system(size: 16, weight: .semibold))
            }
            .padding(.horizontal, 8)

            VStack(spacing: 2) {
                navItem(tr("Biblioteca"), "square.grid.2x2", .library, count: library.videos.count)
                navItem(tr("Originales"), "film", .originals, count: originals.originals.count)
                navItem(tr("Ajustes"), "slider.horizontal.3", .settings, count: nil)
            }

            if !manager.screens.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(tr("Pantallas")).padding(.horizontal, 10)
                    ForEach(manager.screens) { screen in
                        let video = library.video(id: settings.assignments[screen.id])
                        HStack(spacing: 10) {
                            Group {
                                if let video {
                                    Thumbnail(url: video.thumbnailURL)
                                } else {
                                    Theme.field
                                }
                            }
                            .frame(width: 44, height: 25)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.lineStrong) }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(screen.name).fontWeight(.medium).lineLimit(1)
                                Text(video?.name ?? tr("Sin fondo"))
                                    .font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    }
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(settings.pausedManually ? Theme.warn : Theme.ok).frame(width: 8, height: 8)
                    Text(settings.pausedManually ? tr("En pausa") : tr("Reproduciendo")).fontWeight(.medium)
                }
                Text(settings.pauseWhenCovered ? tr("Se pausa cuando las ventanas tapan el escritorio.") : tr("Se reproduce siempre."))
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    settings.pausedManually.toggle()
                } label: {
                    Label(settings.pausedManually ? tr("Reanudar fondos") : tr("Pausar fondos"),
                          systemImage: settings.pausedManually ? "play.fill" : "pause.fill")
                }
                .buttonStyle(WallpyButtonStyle(kind: .secondary, height: 30, fullWidth: true))
            }
            .padding(12)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line) }

            Text(tr("Versión %@", Updater.currentVersion))
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
                .padding(.horizontal, 10)
        }
        .padding(.horizontal, 12)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: 230)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }

    private func navItem(_ title: String, _ symbol: String, _ target: LibrarySection, count: Int?) -> some View {
        let selected = section == target
        return Button { section = target } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.accentText : Theme.text2)
                    .frame(width: 18)
                Text(title).fontWeight(selected ? .medium : .regular)
                Spacer()
                if let count {
                    Text("\(count)").font(.system(size: 11)).foregroundStyle(selected ? Color(hex: 0xA9B8DD) : Theme.text3)
                }
            }
            .foregroundStyle(selected ? .white : Color(hex: 0xC7C7CC))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(selected ? Theme.navSelected : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Library

private enum MediaFilter: Hashable { case all, videos, images }

private struct LibraryPane: View {
    @Binding var editorSource: EditorSource?
    @ObservedObject private var library = VideoLibrary.shared
    @ObservedObject private var manager = WallpaperManager.shared
    @ObservedObject private var settings = Settings.shared
    @State private var selection: Video.ID?
    @State private var filter: MediaFilter = .all
    @State private var search = ""
    @State private var dropTargeted = false
    @State private var errors: [String] = []
    @State private var pendingDelete: Video?

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 20)]

    private var visibleVideos: [Video] {
        library.videos.filter { video in
            switch filter {
            case .all: break
            case .videos: if video.isImage { return false }
            case .images: if !video.isImage { return false }
            }
            let query = search.trimmingCharacters(in: .whitespaces)
            return query.isEmpty || video.name.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Rectangle().fill(Theme.line).frame(height: 1)
                if library.videos.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(visibleVideos) { video in
                                VideoCard(video: video,
                                          selected: selection == video.id,
                                          inUse: !screensUsing(video).isEmpty)
                                    .onTapGesture(count: 2) { manager.setVideoOnAllScreens(video) }
                                    .simultaneousGesture(TapGesture().onEnded { selection = video.id })
                                    .contextMenu { menu(for: video) }
                            }
                            Button(action: openPanel) {
                                VStack(spacing: 8) {
                                    Image(systemName: "plus").font(.system(size: 20))
                                    Text(tr("Arrastra vídeos o imágenes aquí"))
                                }
                                .foregroundStyle(Theme.text2)
                                .frame(maxWidth: .infinity)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(Theme.lineStrong, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(24)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            if let video = selectedVideo {
                Rectangle().fill(Theme.line).frame(width: 1)
                Inspector(video: video, editorSource: $editorSource, onDelete: { requestDelete(video) })
                    .id(video.id)
                    .frame(width: 320)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .onAppear { if selection == nil { selection = library.videos.first?.id } }
        .alert(tr("No se pudieron añadir algunos archivos"),
               isPresented: Binding(get: { !errors.isEmpty }, set: { if !$0 { errors = [] } })) {
            Button(tr("OK")) { errors = [] }
        } message: {
            Text(errors.joined(separator: "\n"))
        }
        .confirmationDialog(tr("Este fondo está en uso. ¿Seguro que quieres eliminarlo?"),
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } })) {
            Button(tr("Eliminar"), role: .destructive) {
                if let video = pendingDelete { delete(video) }
                pendingDelete = nil
            }
        }
    }

    private var selectedVideo: Video? { library.video(id: selection) }

    private var header: some View {
        HStack(spacing: 12) {
            Text(tr("Biblioteca")).font(.system(size: 20, weight: .semibold))
            if library.importing > 0 {
                ProgressView().controlSize(.small)
                Text(tr("Importando…")).foregroundStyle(Theme.text2)
            }
            Spacer()
            SegmentedControl(options: [(tr("Todo"), MediaFilter.all), (tr("Vídeos"), .videos), (tr("Imágenes"), .images)],
                             selection: $filter)
            WallpyTextField(placeholder: tr("Buscar"), text: $search, icon: "magnifyingglass")
                .frame(width: 190)
            Button { editorSource = .youtube } label: {
                Label(tr("Desde YouTube…"), systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.wallpySecondary)
            Button(action: openPanel) { Label(tr("Añadir…"), systemImage: "plus") }
                .buttonStyle(.wallpyPrimary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 44))
                .foregroundStyle(Theme.text3)
            Text(tr("Arrastra vídeos o imágenes aquí")).font(.system(size: 16, weight: .semibold))
            Text(tr("Vídeos: MP4, MOV, M4V. Imágenes: JPG, PNG, HEIC, WebP, TIFF. Los GIF se convierten en vídeo."))
                .foregroundStyle(Theme.text2)
            HStack(spacing: 10) {
                Button(tr("Desde YouTube…")) { editorSource = .youtube }.buttonStyle(.wallpySecondary)
                Button(tr("Añadir…"), action: openPanel).buttonStyle(.wallpyPrimary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func menu(for video: Video) -> some View {
        Button(tr("Poner en todas las pantallas")) { manager.setVideoOnAllScreens(video) }
        if manager.screens.count > 1 {
            ForEach(manager.screens) { screen in
                Button(tr("Poner en %@", screen.name)) { manager.setVideo(video, onScreen: screen.id) }
            }
        }
        Divider()
        if !video.isImage {
            Button(tr("Recortar y optimizar…")) { editorSource = .library(video) }
        }
        Button(tr("Mostrar en Finder")) { NSWorkspace.shared.activateFileViewerSelecting([video.url]) }
        Button(tr("Eliminar"), role: .destructive) { requestDelete(video) }
    }

    private func screensUsing(_ video: Video) -> [String] {
        manager.screens.filter { settings.assignments[$0.id] == video.id }.map(\.name)
    }

    private func requestDelete(_ video: Video) {
        if library.isInUse(video) {
            pendingDelete = video
        } else {
            delete(video)
        }
    }

    private func delete(_ video: Video) {
        let index = library.videos.firstIndex(of: video)
        library.delete(video)
        if selection == video.id {
            selection = index.flatMap { library.videos.indices.contains($0) ? library.videos[$0].id : library.videos.last?.id }
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = VideoLibrary.allowedTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = tr("Añadir")
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
            if let first = library.videos.first { selection = first.id }
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
    let inUse: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Thumbnail(url: video.thumbnailURL)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if inUse { badge(dot: Theme.ok, tr("En uso")) }
                }
                .overlay(alignment: .topTrailing) {
                    if video.isImage {
                        Image(systemName: "photo")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 24, height: 24)
                            .background(Theme.window.opacity(0.82), in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                            .accessibilityLabel(tr("Imagen"))
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if video.width < 1280 && video.height < 1280 {
                        Label(tr("Resolución baja"), systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.warn)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.window.opacity(0.82), in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2)
                        .padding(-4)
                }
            Text(video.name).fontWeight(.medium).lineLimit(1)
            HStack {
                Text(video.resolutionLabel)
                Spacer()
                Text(video.durationLabel)
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.text3)
        }
        .contentShape(Rectangle())
    }

    private func badge(dot: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.window.opacity(0.82), in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }
}

/// Details and actions for the selected wallpaper.
private struct Inspector: View {
    let video: Video
    @Binding var editorSource: EditorSource?
    let onDelete: () -> Void
    @ObservedObject private var manager = WallpaperManager.shared
    @ObservedObject private var settings = Settings.shared
    @State private var name = ""

    private var fileSize: String {
        let bytes = (try? video.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Thumbnail(url: video.thumbnailURL)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Nombre")).font(.system(size: 11)).foregroundStyle(Theme.text3)
                    WallpyTextField(placeholder: tr("Nombre"), text: $name) { commitName() }
                        .onChange(of: name) { _, _ in commitName() }
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        meta(tr("Tipo"), video.isImage ? tr("Imagen") : tr("Vídeo"))
                        meta(tr("Resolución"), video.resolutionLabel, mono: true)
                    }
                    GridRow {
                        meta(tr("Duración"), video.isImage ? "—" : video.durationLabel, mono: true)
                        meta(tr("Tamaño"), fileSize, mono: true)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(tr("En pantalla"))
                    ForEach(manager.screens) { screen in
                        let active = settings.assignments[screen.id] == video.id
                        Button {
                            manager.setVideo(active ? nil : video, onScreen: screen.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "display")
                                    .foregroundStyle(active ? Theme.accentText : Theme.text2)
                                Text(screen.name).frame(maxWidth: .infinity, alignment: .leading)
                                if active {
                                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accentText)
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .background(active ? Theme.accentSoft : Theme.field, in: RoundedRectangle(cornerRadius: Theme.radius))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.radius)
                                    .strokeBorder(active ? Theme.accentBorder : Color(hex: 0x2F2F33))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(active ? .isSelected : [])
                    }
                }

                VStack(spacing: 8) {
                    Button(tr("Poner en todas las pantallas")) { manager.setVideoOnAllScreens(video) }
                        .buttonStyle(WallpyButtonStyle(kind: .primary, height: 38, fullWidth: true))
                    if !video.isImage {
                        Button { editorSource = .library(video) } label: {
                            Label(tr("Recortar y optimizar…"), systemImage: "scissors")
                        }
                        .buttonStyle(WallpyButtonStyle(kind: .secondary, height: 34, fullWidth: true))
                    }
                    HStack(spacing: 8) {
                        Button(tr("Mostrar en Finder")) { NSWorkspace.shared.activateFileViewerSelecting([video.url]) }
                            .buttonStyle(WallpyButtonStyle(kind: .ghost, height: 32, fullWidth: true))
                        IconButton(symbol: "trash", label: tr("Eliminar de la biblioteca"), kind: .danger, action: onDelete)
                            .frame(width: 40)
                    }
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .background(Theme.sidebar)
        .onAppear { name = video.name }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != video.name else { return }
        VideoLibrary.shared.rename(video, to: trimmed)
    }

    private func meta(_ title: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.text3)
            if mono {
                Text(value).monospacedText()
            } else {
                Text(value).font(.system(size: 12))
            }
        }
    }
}

struct Thumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Theme.field
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "film").foregroundStyle(Theme.text3)
            }
        }
        .task(id: url) { image = NSImage(contentsOf: url) }
    }
}

// MARK: - Originals

/// Full-length downloads kept to cut more loops from later.
private struct OriginalsPane: View {
    @Binding var editorSource: EditorSource?
    @ObservedObject private var originals = OriginalsLibrary.shared
    @State private var pendingDelete: OriginalVideo?
    @State private var opening: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Originales")).font(.system(size: 20, weight: .semibold))
                    Text(tr("Vídeos completos guardados para sacar más fondos sin volver a descargarlos."))
                        .foregroundStyle(Theme.text2)
                }
                Spacer()
                if !originals.originals.isEmpty {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(tr("Espacio usado")).font(.system(size: 11)).foregroundStyle(Theme.text3)
                        Text(ByteCountFormatter.string(fromByteCount: originals.totalBytes, countStyle: .file))
                            .monospacedText(size: 13)
                    }
                }
                Button { editorSource = .youtube } label: {
                    Label(tr("Desde YouTube…"), systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.wallpySecondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Rectangle().fill(Theme.line).frame(height: 1)

            if originals.originals.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "film").font(.system(size: 44)).foregroundStyle(Theme.text3)
                    Text(tr("Aún no hay originales")).font(.system(size: 16, weight: .semibold))
                    Text(tr("Al descargar de YouTube, activa «Guardar en Originales» en el editor para conservar el vídeo completo."))
                        .foregroundStyle(Theme.text2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(originals.originals) { original in
                            row(original)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .confirmationDialog(tr("¿Eliminar «%@»? Los fondos ya creados a partir de él no se borran.", pendingDelete?.name ?? ""),
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button(tr("Eliminar"), role: .destructive) {
                if let original = pendingDelete { originals.delete(original) }
                pendingDelete = nil
            }
        }
    }

    private func row(_ original: OriginalVideo) -> some View {
        HStack(spacing: 18) {
            Thumbnail(url: original.thumbnailURL)
                .frame(width: 200, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { if opening == original.id { ProgressView() } }
            VStack(alignment: .leading, spacing: 8) {
                Text(original.name).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                HStack(spacing: 16) {
                    Text("\(original.width)×\(original.height)").monospacedText()
                    Text(original.durationLabel).monospacedText()
                    Text(original.sizeLabel).monospacedText()
                    Text(tr("Guardado el %@", original.addedAt.formatted(.dateTime.day().month(.abbreviated).locale(Localizer.shared.locale))))
                }
                .foregroundStyle(Theme.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { open(original) } label: { Label(tr("Crear fondos"), systemImage: "scissors") }
                .buttonStyle(WallpyButtonStyle(kind: .primary, height: 34))
            IconButton(symbol: "folder", label: tr("Mostrar en Finder"), size: 34) {
                NSWorkspace.shared.activateFileViewerSelecting([original.url])
            }
            IconButton(symbol: "trash", label: tr("Eliminar original"), kind: .danger, size: 34) {
                pendingDelete = original
            }
        }
        .wallpyCard(padding: 14)
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

private struct SettingsPane: View {
    @ObservedObject private var localizer = Localizer.shared
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var manager = WallpaperManager.shared
    @ObservedObject private var library = VideoLibrary.shared
    @ObservedObject private var updater = Updater.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var autoUpdate = Updater.shared.autoCheck

    private let columns = [GridItem(.adaptive(minimum: 420), spacing: 20, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tr("Ajustes")).font(.system(size: 20, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Rectangle().fill(Theme.line).frame(height: 1)

            ScrollView {
                VStack(spacing: 20) {
                    screensCard
                    LazyVGrid(columns: columns, spacing: 20) {
                        languageCard
                        energyCard
                        soundCard
                        updatesCard
                        toolsCard
                    }
                }
                .padding(24)
                .frame(maxWidth: 1180)
            }
        }
    }

    private var screensCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Pantallas")).font(.system(size: 14, weight: .semibold))
            DisplayArrangement(screens: manager.screens)
                .frame(height: 180)
                .background(Theme.window, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: 0x26262A)) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                ForEach(manager.screens) { screen in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(screen.name).foregroundStyle(Theme.text2)
                        Picker(screen.name, selection: assignment(for: screen.id)) {
                            Text(tr("Ninguno")).tag(UUID?.none)
                            ForEach(library.videos) { video in
                                Text(video.name).tag(UUID?.some(video.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wallpyCard()
    }

    private var languageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Idioma")).font(.system(size: 14, weight: .semibold))
            SegmentedControl(options: AppLanguage.allCases.map { ($0.nativeName, $0) },
                             selection: $localizer.choice, expand: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wallpyCard()
    }

    private var energyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("Ahorro de energía")).font(.system(size: 14, weight: .semibold)).padding(.bottom, 8)
            SwitchRow(title: tr("Pausar cuando las ventanas tapan el escritorio"),
                      detail: tr("Recomendado: no gasta nada si no lo ves"), isOn: $settings.pauseWhenCovered)
            divider
            SwitchRow(title: tr("Pausar con batería"), isOn: $settings.pauseOnBattery)
            divider
            SwitchRow(title: tr("Pausar con batería baja"), isOn: $settings.pauseOnLowBattery)
            if settings.pauseOnLowBattery {
                Stepper(value: $settings.lowBatteryLevel, in: 5...90, step: 5) {
                    Text(tr("Por debajo de %d %%", settings.lowBatteryLevel)).foregroundStyle(Theme.text2)
                }
                .padding(.bottom, 6)
            }
            if let level = manager.power.batteryLevel {
                Text(tr("Batería: %d %% · %@", level, manager.power.onBattery ? tr("con batería") : tr("conectado")))
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wallpyCard()
    }

    private var soundCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("Sonido y escritorio")).font(.system(size: 14, weight: .semibold)).padding(.bottom, 12)
            HStack(spacing: 12) {
                Text(tr("Volumen")).foregroundStyle(Theme.text2).frame(width: 64, alignment: .leading)
                Slider(value: $settings.volume, in: 0...1)
                Text("\(Int((settings.volume * 100).rounded())) %")
                    .monospacedText().foregroundStyle(Theme.text2).frame(width: 44, alignment: .trailing)
            }
            .padding(.bottom, 8)
            divider
            SwitchRow(title: tr("Ocultar iconos del escritorio"), isOn: $settings.hideDesktopIcons)
            divider
            SwitchRow(title: tr("Abrir al iniciar sesión"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    LoginItem.setEnabled(enabled)
                    launchAtLogin = LoginItem.isEnabled
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wallpyCard()
    }

    private var updatesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("Actualizaciones")).font(.system(size: 14, weight: .semibold)).padding(.bottom, 8)
            SwitchRow(title: tr("Buscar actualizaciones automáticamente"), isOn: $autoUpdate)
                .onChange(of: autoUpdate) { _, value in updater.autoCheck = value }
            divider
            HStack {
                Text(tr("Versión ")).foregroundStyle(Theme.text2) + Text(Updater.currentVersion).font(.system(size: 13, design: .monospaced))
                Spacer()
                if updater.state != .idle { ProgressView().controlSize(.small) }
                Button(tr("Buscar ahora")) { Task { await updater.check(userInitiated: true) } }
                    .buttonStyle(WallpyButtonStyle(kind: .secondary, height: 30))
                    .disabled(updater.state != .idle)
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wallpyCard()
    }

    private var toolsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Herramientas")).font(.system(size: 14, weight: .semibold))
            ForEach([ExternalTool.ytDlp, .ffmpeg], id: \.rawValue) { tool in
                let installed = tool.url != nil
                HStack(spacing: 10) {
                    Circle().fill(installed ? Theme.ok : Theme.warn).frame(width: 8, height: 8)
                    Text(tool.rawValue)
                    Spacer()
                    Text(installed ? tr("Instalado") : tr("No instalado")).foregroundStyle(Theme.text3)
                }
            }
            Text(ExternalTool.missing.isEmpty
                 ? tr("Necesarios para descargar de YouTube, el editor de bucles y convertir GIF.")
                 : tr("Instálalos con: brew install yt-dlp ffmpeg"))
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wallpyCard()
    }

    private var divider: some View {
        Rectangle().fill(Color(hex: 0x26262A)).frame(height: 1)
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
            let scale = bounds.isEmpty ? 1 : min(geo.size.width / bounds.width, geo.size.height / bounds.height) * 0.85
            let offsetX = (geo.size.width - bounds.width * scale) / 2
            let offsetY = (geo.size.height - bounds.height * scale) / 2
            ZStack(alignment: .topLeading) {
                ForEach(screens) { screen in
                    let w = screen.frame.width * scale
                    let h = screen.frame.height * scale
                    let x = (screen.frame.minX - bounds.minX) * scale + offsetX
                    // AppKit's y axis grows upward; SwiftUI's grows downward.
                    let y = (bounds.maxY - screen.frame.maxY) * scale + offsetY
                    ZStack(alignment: .bottomLeading) {
                        if let video = library.video(id: settings.assignments[screen.id]) {
                            Thumbnail(url: video.thumbnailURL)
                        } else {
                            Theme.field
                        }
                        Text(screen.name)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Theme.window.opacity(0.82), in: RoundedRectangle(cornerRadius: 5))
                            .padding(8)
                    }
                    .frame(width: w - 6, height: h - 6)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.lineStrong) }
                    .position(x: x + w / 2, y: y + h / 2)
                }
            }
        }
    }
}
