import SwiftUI

/// Screens × moments grid: what each screen shows at each time of day, all in one place.
struct SchedulePane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var manager = WallpaperManager.shared
    @ObservedObject private var library = VideoLibrary.shared
    @State private var editing: ScheduleCell?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Programación")).font(.system(size: 20, weight: .semibold))
                    Text(tr("Elige qué fondo se ve en cada pantalla y en cada momento del día."))
                        .foregroundStyle(Theme.text2)
                }
                Spacer()
                Toggle(tr("Cambiar según el momento del día"), isOn: $settings.momentsEnabled)
                    .toggleStyle(.switch)
                    .tint(Theme.accentFill)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Rectangle().fill(Theme.line).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !settings.momentsEnabled {
                        Label(tr("Activa «Cambiar según el momento del día» para que se apliquen las columnas de los momentos. Mientras tanto se usa «Siempre»."),
                              systemImage: "info.circle")
                            .foregroundStyle(Theme.text2)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
                    }

                    Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 14) {
                        GridRow {
                            Text(tr("Pantalla"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.text3)
                                .frame(width: 130, alignment: .leading)
                            header(nil)
                            ForEach(DayMoment.allCases) { header($0) }
                        }
                        ForEach(manager.screens) { screen in
                            GridRow {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(screen.name).fontWeight(.medium).lineLimit(2)
                                    Text("\(Int(screen.frame.width))×\(Int(screen.frame.height))")
                                        .monospacedText(size: 11).foregroundStyle(Theme.text3)
                                }
                                .frame(width: 130, alignment: .leading)
                                .padding(.top, 8)
                                cell(screen, nil)
                                ForEach(DayMoment.allCases) { cell(screen, $0) }
                            }
                        }
                    }

                    Text(tr("Pincha una casilla para elegir el fondo. «Siempre» es el fondo base de cada pantalla: se ve en los momentos que no tengan uno propio."))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
            }
        }
    }

    private func isNow(_ moment: DayMoment?) -> Bool {
        guard let moment else { return false }
        return settings.momentsEnabled && manager.currentMoment == moment
    }

    private func header(_ moment: DayMoment?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: moment?.symbol ?? "infinity").foregroundStyle(Theme.accentText)
                Text(moment?.title ?? tr("Siempre")).fontWeight(.semibold)
                if isNow(moment) {
                    Text(tr("Ahora"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.window)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.ok, in: Capsule())
                }
            }
            if let moment {
                HStack(spacing: 4) {
                    Text(tr("desde")).foregroundStyle(Theme.text3)
                    Picker(moment.title, selection: startBinding(moment)) {
                        ForEach(Array(stride(from: 0, to: 24 * 60, by: 15)), id: \.self) { minutes in
                            Text(String(format: "%02d:%02d", minutes / 60, minutes % 60)).tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .font(.system(size: 12))
            } else {
                Text(tr("Fondo base")).font(.system(size: 12)).foregroundStyle(Theme.text3).frame(height: 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(moment != nil && !settings.momentsEnabled ? 0.5 : 1)
    }

    private func cell(_ screen: ScreenInfo, _ moment: DayMoment?) -> some View {
        let key = ScheduleCell(screen: screen.id, moment: moment)
        let own = library.video(id: settings.assignment(screen: screen.id, moment: moment))
        let fallback = moment == nil ? nil : library.video(id: settings.assignments[screen.id])
        let now = isNow(moment)
        return Button { editing = key } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    if let own {
                        Thumbnail(url: own.thumbnailURL)
                    } else if let fallback {
                        Thumbnail(url: fallback.thumbnailURL).opacity(0.28)
                        Text(tr("Usa Siempre"))
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Theme.window.opacity(0.8), in: RoundedRectangle(cornerRadius: 5))
                    } else {
                        Theme.field
                        Image(systemName: "plus").foregroundStyle(Theme.text3)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(now ? Theme.accent : (own == nil ? Theme.lineStrong : .clear),
                                      style: StrokeStyle(lineWidth: now ? 2 : 1, dash: own == nil && !now ? [5, 4] : []))
                }
                Text(own?.name ?? (fallback == nil ? tr("Sin fondo") : " "))
                    .font(.system(size: 11))
                    .foregroundStyle(own == nil ? Theme.text3 : Theme.text2)
                    .lineLimit(1)
            }
            .frame(minWidth: 120, maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(moment != nil && !settings.momentsEnabled ? 0.5 : 1)
        .accessibilityLabel("\(screen.name), \(moment?.title ?? tr("Siempre")): \(own?.name ?? tr("Sin fondo"))")
        .popover(isPresented: Binding(get: { editing == key }, set: { if !$0 { editing = nil } }),
                 arrowEdge: .bottom) {
            WallpaperChooser(cell: key, screenName: screen.name) { editing = nil }
        }
    }

    private func startBinding(_ moment: DayMoment) -> Binding<Int> {
        Binding(get: { settings.start(of: moment) / 15 * 15 },
                set: { settings.setStart($0, for: moment) })
    }
}

struct ScheduleCell: Hashable {
    let screen: String
    /// nil = always.
    let moment: DayMoment?
}

/// Popover listing the library to fill one cell (or the whole column).
private struct WallpaperChooser: View {
    let cell: ScheduleCell
    let screenName: String
    let onDone: () -> Void
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var library = VideoLibrary.shared
    @ObservedObject private var manager = WallpaperManager.shared
    @State private var allScreens = false

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 10)]

    var body: some View {
        let current = settings.assignment(screen: cell.screen, moment: cell.moment)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: cell.moment?.symbol ?? "infinity").foregroundStyle(Theme.accentText)
                Text(tr("%@ · %@", screenName, cell.moment?.title ?? tr("Siempre"))).font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            if manager.screens.count > 1 {
                Toggle(tr("Aplicar a todas las pantallas"), isOn: $allScreens)
                    .toggleStyle(.checkbox)
            }
            if library.videos.isEmpty {
                Text(tr("Añade fondos en la Biblioteca para programarlos."))
                    .foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(library.videos) { video in
                            Button { assign(video.id) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Thumbnail(url: video.thumbnailURL)
                                        .aspectRatio(16 / 9, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(current == video.id ? Theme.accent : .clear, lineWidth: 2)
                                        }
                                    Text(video.name).font(.system(size: 11)).lineLimit(1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            HStack {
                if current != nil {
                    Button(cell.moment == nil ? tr("Quitar el fondo") : tr("Usar el de Siempre")) { assign(nil) }
                        .buttonStyle(WallpyButtonStyle(kind: .ghost, height: 28))
                }
                Spacer()
                Button(tr("Cerrar"), action: onDone)
                    .buttonStyle(WallpyButtonStyle(kind: .secondary, height: 28))
            }
        }
        .padding(16)
        .frame(width: 440)
        .background(Color(hex: 0x1C1C1F))
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
    }

    private func assign(_ id: UUID?) {
        let screens = allScreens ? manager.screens.map(\.id) : [cell.screen]
        for screen in screens {
            settings.setAssignment(id, screen: screen, moment: cell.moment)
        }
        onDone()
    }
}
