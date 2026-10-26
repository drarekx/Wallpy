import AppKit
import SwiftUI

/// Elements (clock, date…) drawn over each screen's wallpaper, set up screen by screen.
struct OverlaysPane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var manager = WallpaperManager.shared
    @ObservedObject private var library = VideoLibrary.shared
    @State private var screenID: String?
    @State private var selection: UUID?

    private var screen: ScreenInfo? {
        manager.screens.first { $0.id == screenID } ?? manager.screens.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Elementos")).font(.system(size: 20, weight: .semibold))
                    Text(tr("Añade la hora o la fecha encima del fondo de cada pantalla."))
                        .foregroundStyle(Theme.text2)
                }
                Spacer()
                if manager.screens.count > 1, let screen {
                    SegmentedControl(options: manager.screens.map { ($0.name, $0.id) },
                                     selection: Binding(get: { screen.id }, set: { screenID = $0; selection = nil }))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Rectangle().fill(Theme.line).frame(height: 1)

            if let screen {
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            preview(screen)
                            if manager.displayed[screen.id] == nil {
                                Label(tr("Esta pantalla no tiene fondo: los elementos se verán cuando le pongas uno."),
                                      systemImage: "info.circle")
                                    .foregroundStyle(Theme.warn)
                            }
                            HStack(spacing: 10) {
                                ForEach(OverlayKind.allCases, id: \.self) { kind in
                                    Button { add(kind, to: screen.id) } label: {
                                        Label(kind.addTitle, systemImage: kind.symbol)
                                    }
                                    .buttonStyle(.wallpySecondary)
                                }
                                Spacer()
                                if manager.screens.count > 1 {
                                    Button(tr("Copiar a las demás pantallas")) { copyToOthers(from: screen.id) }
                                        .buttonStyle(.wallpyGhost)
                                        .disabled(widgets(screen.id).isEmpty)
                                }
                            }
                        }
                        .padding(24)
                    }
                    .frame(maxWidth: .infinity)
                    Rectangle().fill(Theme.line).frame(width: 1)
                    inspector(screen.id)
                        .frame(width: 320)
                }
            } else {
                Text(tr("No hay pantallas conectadas."))
                    .foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Preview

    private func preview(_ screen: ScreenInfo) -> some View {
        let video = library.video(id: manager.displayed[screen.id])
        let showSeconds = widgets(screen.id).contains { $0.kind == .time && $0.showSeconds }
        return GeometryReader { geo in
            ZStack {
                if let video {
                    Thumbnail(url: video.thumbnailURL)
                } else {
                    Theme.field
                }
                TimelineView(.periodic(from: .now, by: showSeconds ? 1 : 10)) { context in
                    OverlayCanvas(widgets: widgets(screen.id), date: context.date,
                                  scale: geo.size.width / max(screen.frame.width, 1),
                                  selection: selection, onSelect: { selection = $0 })
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture { selection = nil }
        }
        .aspectRatio(screen.frame.width / max(screen.frame.height, 1), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.lineStrong) }
        .frame(maxWidth: 900)
    }

    // MARK: Inspector

    private func inspector(_ screenID: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(tr("En esta pantalla"))
                    if widgets(screenID).isEmpty {
                        Text(tr("Nada todavía. Añade la hora o la fecha con los botones de abajo de la vista previa."))
                            .font(.system(size: 12)).foregroundStyle(Theme.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(widgets(screenID)) { widget in
                        row(widget, screenID: screenID)
                    }
                }
                if let id = selection, let binding = binding(id, screenID: screenID) {
                    WidgetEditor(widget: binding)
                }
            }
            .padding(20)
        }
        .background(Theme.sidebar)
    }

    private func row(_ widget: OverlayWidget, screenID: String) -> some View {
        let selected = selection == widget.id
        return HStack(spacing: 10) {
            Button { selection = selected ? nil : widget.id } label: {
                HStack(spacing: 10) {
                    Image(systemName: widget.kind.symbol)
                        .foregroundStyle(selected ? Theme.accentText : Theme.text2)
                        .frame(width: 18)
                    Text(widget.kind.title).frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            IconButton(symbol: "trash", label: tr("Quitar"), size: 26) { remove(widget.id, from: screenID) }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 36)
        .background(selected ? Theme.navSelected : Theme.field, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(selected ? Theme.accentBorder : Theme.line)
        }
    }

    // MARK: Data

    private func widgets(_ screenID: String) -> [OverlayWidget] {
        settings.overlays[screenID] ?? []
    }

    private func binding(_ id: UUID, screenID: String) -> Binding<OverlayWidget>? {
        guard let current = widgets(screenID).first(where: { $0.id == id }) else { return nil }
        return Binding(get: { widgets(screenID).first { $0.id == id } ?? current },
                       set: { new in
                           var list = widgets(screenID)
                           guard let index = list.firstIndex(where: { $0.id == id }) else { return }
                           list[index] = new
                           settings.overlays[screenID] = list
                       })
    }

    private func add(_ kind: OverlayKind, to screenID: String) {
        var widget = OverlayWidget(kind: kind)
        // A date added after the time goes right below it, and the other way round.
        if let partner = widgets(screenID).last(where: { $0.kind != kind }) {
            widget.position = partner.position
            widget.design = partner.design
            widget.color = partner.color
        }
        settings.overlays[screenID, default: []].append(widget)
        selection = widget.id
    }

    private func remove(_ id: UUID, from screenID: String) {
        let list = widgets(screenID).filter { $0.id != id }
        settings.overlays[screenID] = list.isEmpty ? nil : list
        if selection == id { selection = nil }
    }

    private func copyToOthers(from screenID: String) {
        let source = widgets(screenID)
        var overlays = settings.overlays
        for screen in manager.screens where screen.id != screenID {
            overlays[screen.id] = source.map { widget in
                var copy = widget
                copy.id = UUID()
                return copy
            }
        }
        settings.overlays = overlays
    }
}

/// Controls for one element.
private struct WidgetEditor: View {
    @Binding var widget: OverlayWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            group(tr("Posición")) { PositionPicker(selection: $widget.position) }

            group(tr("Tamaño")) {
                HStack(spacing: 10) {
                    Slider(value: $widget.size, in: 12...320)
                    Text("\(Int(widget.size)) pt").monospacedText().foregroundStyle(Theme.text2)
                        .frame(width: 48, alignment: .trailing)
                }
            }

            group(tr("Letra")) {
                SegmentedControl(options: [(tr("Estándar"), OverlayFontDesign.standard), (tr("Redonda"), .rounded),
                                           (tr("Mono"), .monospaced), (tr("Serif"), .serif)],
                                 selection: $widget.design, expand: true)
                SegmentedControl(options: [(tr("Fina"), OverlayFontWeight.thin), (tr("Normal"), .regular),
                                           (tr("Gruesa"), .bold)],
                                 selection: $widget.weight, expand: true)
            }

            group(tr("Color")) {
                HStack(spacing: 10) {
                    ColorPicker(tr("Color"), selection: color, supportsOpacity: false).labelsHidden()
                    Slider(value: $widget.opacity, in: 0.1...1)
                    Text("\(Int((widget.opacity * 100).rounded())) %").monospacedText().foregroundStyle(Theme.text2)
                        .frame(width: 48, alignment: .trailing)
                }
                SwitchRow(title: tr("Sombra"), detail: tr("Se lee mejor sobre fondos claros"), isOn: $widget.shadow)
            }

            switch widget.kind {
            case .time:
                group(tr("Formato")) {
                    SegmentedControl(options: [(tr("Sistema"), ClockFormat.system), (tr("24 h"), .h24), (tr("12 h"), .h12)],
                                     selection: $widget.clockFormat, expand: true)
                    SwitchRow(title: tr("Mostrar segundos"), isOn: $widget.showSeconds)
                }
            case .date:
                group(tr("Formato")) {
                    SegmentedControl(options: [(tr("Larga"), DateStyle.long), (tr("Corta"), .short), (tr("Numérica"), .numeric)],
                                     selection: $widget.dateStyle, expand: true)
                }
            }
        }
    }

    private var color: Binding<Color> {
        Binding(get: { Color(hex: widget.color) },
                set: { new in
                    guard let rgb = NSColor(new).usingColorSpace(.sRGB) else { return }
                    let channel = { (value: CGFloat) in UInt32((min(max(value, 0), 1) * 255).rounded()) }
                    widget.color = channel(rgb.redComponent) << 16 | channel(rgb.greenComponent) << 8 | channel(rgb.blueComponent)
                })
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            content()
        }
    }
}

/// 3×3 grid of the nine positions.
private struct PositionPicker: View {
    @Binding var selection: OverlayPosition

    var body: some View {
        let positions = OverlayPosition.allCases
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(0..<3) { row in
                GridRow {
                    ForEach(0..<3) { column in
                        let position = positions[row * 3 + column]
                        let selected = position == selection
                        Button { selection = position } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(selected ? Theme.accent : Theme.lineStrong)
                                .frame(width: 18, height: 10)
                                .frame(maxWidth: .infinity, alignment: Alignment(horizontal: position.stackAlignment, vertical: .center))
                                .padding(.horizontal, 8)
                                .frame(height: 30)
                                .background(selected ? Theme.accentSoft : Theme.field, in: RoundedRectangle(cornerRadius: 6))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Theme.accentBorder : Theme.line)
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
