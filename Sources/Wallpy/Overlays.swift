import AppKit
import SwiftUI

/// Something drawn on top of a screen's wallpaper.
enum OverlayKind: String, Codable, CaseIterable {
    case time, date

    var title: String {
        switch self {
        case .time: return tr("Hora")
        case .date: return tr("Fecha")
        }
    }

    var addTitle: String {
        switch self {
        case .time: return tr("Añadir hora")
        case .date: return tr("Añadir fecha")
        }
    }

    var symbol: String {
        switch self {
        case .time: return "clock"
        case .date: return "calendar"
        }
    }
}

/// Where on the screen an element sits. Elements sharing a position stack vertically.
enum OverlayPosition: String, Codable, CaseIterable {
    case topLeading, top, topTrailing, leading, center, trailing, bottomLeading, bottom, bottomTrailing

    var alignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .top: return .top
        case .topTrailing: return .topTrailing
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        case .bottomLeading: return .bottomLeading
        case .bottom: return .bottom
        case .bottomTrailing: return .bottomTrailing
        }
    }

    var stackAlignment: HorizontalAlignment {
        switch self {
        case .topLeading, .leading, .bottomLeading: return .leading
        case .topTrailing, .trailing, .bottomTrailing: return .trailing
        default: return .center
        }
    }
}

enum OverlayFontDesign: String, Codable, CaseIterable {
    case standard, rounded, monospaced, serif

    var design: Font.Design {
        switch self {
        case .standard: return .default
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        case .serif: return .serif
        }
    }
}

enum OverlayFontWeight: String, Codable, CaseIterable {
    case thin, regular, bold

    var weight: Font.Weight {
        switch self {
        case .thin: return .thin
        case .regular: return .regular
        case .bold: return .bold
        }
    }
}

enum ClockFormat: String, Codable, CaseIterable {
    case system, h24, h12
}

enum DateStyle: String, Codable, CaseIterable {
    /// "Monday, 26 October"
    case long
    /// "Mon 26 Oct"
    case short
    /// "26/10/2026"
    case numeric
}

/// One element (clock, date…) on one screen. Stored in `Settings.overlays`.
struct OverlayWidget: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: OverlayKind
    var position: OverlayPosition = .center
    /// Font size in points on the real screen.
    var size: Double
    var design: OverlayFontDesign = .standard
    var weight: OverlayFontWeight = .thin
    var color: UInt32 = 0xFFFFFF
    var opacity: Double = 0.9
    var shadow = true
    var clockFormat: ClockFormat = .system
    var showSeconds = false
    var dateStyle: DateStyle = .long

    init(kind: OverlayKind) {
        self.kind = kind
        switch kind {
        case .time:
            size = 140
        case .date:
            size = 32
            weight = .regular
        }
    }

    /// Text for `date` in the app's language and the system's region.
    func text(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Self.locale
        switch kind {
        case .time:
            let seconds = showSeconds ? "ss" : ""
            switch clockFormat {
            case .system: formatter.setLocalizedDateFormatFromTemplate("jmm" + seconds)
            case .h24: formatter.setLocalizedDateFormatFromTemplate("HHmm" + seconds)
            case .h12: formatter.setLocalizedDateFormatFromTemplate("hmm" + seconds)
            }
        case .date:
            switch dateStyle {
            case .long: formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
            case .short: formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
            case .numeric: formatter.dateStyle = .short
            }
        }
        let text = formatter.string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static var locale: Locale {
        let language = Localizer.shared.language.rawValue
        guard let region = Locale.current.region?.identifier else { return Locale(identifier: language) }
        return Locale(identifier: "\(language)_\(region)")
    }
}

// Decoding with defaults, so settings saved by older versions keep loading when fields are added.
extension OverlayWidget {
    private enum CodingKeys: String, CodingKey {
        case id, kind, position, size, design, weight, color, opacity, shadow, clockFormat, showSeconds, dateStyle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(OverlayKind.self, forKey: .kind))
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? id
        position = try c.decodeIfPresent(OverlayPosition.self, forKey: .position) ?? position
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? size
        design = try c.decodeIfPresent(OverlayFontDesign.self, forKey: .design) ?? design
        weight = try c.decodeIfPresent(OverlayFontWeight.self, forKey: .weight) ?? weight
        color = try c.decodeIfPresent(UInt32.self, forKey: .color) ?? color
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? shadow
        clockFormat = try c.decodeIfPresent(ClockFormat.self, forKey: .clockFormat) ?? clockFormat
        showSeconds = try c.decodeIfPresent(Bool.self, forKey: .showSeconds) ?? showSeconds
        dateStyle = try c.decodeIfPresent(DateStyle.self, forKey: .dateStyle) ?? dateStyle
    }
}

/// Draws a screen's elements. Used by the wallpaper window (scale 1) and by the preview in the library.
struct OverlayCanvas: View {
    let widgets: [OverlayWidget]
    let date: Date
    /// Preview size / real screen size.
    var scale: CGFloat = 1
    var selection: UUID?
    var onSelect: ((UUID) -> Void)?

    var body: some View {
        ZStack {
            ForEach(OverlayPosition.allCases, id: \.self) { position in
                let items = widgets.filter { $0.position == position }
                if !items.isEmpty {
                    VStack(alignment: position.stackAlignment, spacing: 4 * scale) {
                        ForEach(items) { item($0) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: position.alignment)
                }
            }
        }
        .padding(64 * scale)
    }

    private func item(_ widget: OverlayWidget) -> some View {
        Text(widget.text(at: date))
            .font(.system(size: widget.size * scale, weight: widget.weight.weight, design: widget.design.design))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Color(hex: widget.color).opacity(widget.opacity))
            .shadow(color: .black.opacity(widget.shadow ? 0.45 : 0), radius: 8 * scale, y: 2 * scale)
            .padding(.horizontal, 4 * scale)
            .overlay {
                if selection == widget.id {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onSelect?(widget.id) }
            .allowsHitTesting(onSelect != nil)
    }
}

/// What the wallpaper window of one screen draws on top of the video.
final class OverlayModel: ObservableObject {
    @Published var widgets: [OverlayWidget] = []
    @Published var now = Date()
}

struct ScreenOverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        OverlayCanvas(widgets: model.widgets, date: model.now)
    }
}
