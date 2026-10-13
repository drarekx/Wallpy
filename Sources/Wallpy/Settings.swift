import Foundation
import ServiceManagement

/// What to do when the Mac runs on battery (or in Low Power Mode, if enabled).
enum BatteryMode: String, CaseIterable {
    case keepPlaying, pause, image
}

/// Parts of the day a wallpaper can be scheduled for.
enum DayMoment: String, CaseIterable, Identifiable {
    case dawn, morning, afternoon, night
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dawn: return tr("Madrugada")
        case .morning: return tr("Mañana")
        case .afternoon: return tr("Tarde")
        case .night: return tr("Noche")
        }
    }

    var symbol: String {
        switch self {
        case .dawn: return "moon.stars"
        case .morning: return "sunrise"
        case .afternoon: return "sun.max"
        case .night: return "moon"
        }
    }

    /// Default start, in minutes after midnight.
    var defaultStart: Int {
        switch self {
        case .dawn: return 0
        case .morning: return 7 * 60
        case .afternoon: return 14 * 60
        case .night: return 21 * 60
        }
    }
}

/// User preferences, persisted in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    /// Screen UUID → video ID shown on that screen.
    @Published var assignments: [String: UUID] { didSet { save(assignments, "assignments") } }
    /// 0…1. Muted by default, like the original app.
    @Published var volume: Float { didSet { defaults.set(volume, forKey: "volume") } }
    @Published var lastVolume: Float { didSet { defaults.set(lastVolume, forKey: "lastVolume") } }
    @Published var pausedManually: Bool { didSet { defaults.set(pausedManually, forKey: "pausedManually") } }
    /// Pause when the desktop is covered by other windows.
    @Published var pauseWhenCovered: Bool { didSet { defaults.set(pauseWhenCovered, forKey: "pauseWhenCovered") } }
    @Published var batteryMode: BatteryMode { didSet { defaults.set(batteryMode.rawValue, forKey: "batteryMode") } }
    /// Still image shown on every screen when `batteryMode == .image`.
    @Published var batteryImageID: UUID? { didSet { defaults.set(batteryImageID?.uuidString, forKey: "batteryImageID") } }
    /// macOS Low Power Mode counts as being on battery.
    @Published var lowPowerModeAsBattery: Bool { didSet { defaults.set(lowPowerModeAsBattery, forKey: "lowPowerModeAsBattery") } }
    @Published var pauseOnLowBattery: Bool { didSet { defaults.set(pauseOnLowBattery, forKey: "pauseOnLowBattery") } }
    @Published var lowBatteryLevel: Int { didSet { defaults.set(lowBatteryLevel, forKey: "lowBatteryLevel") } }
    /// Change wallpapers with the time of day.
    @Published var momentsEnabled: Bool { didSet { defaults.set(momentsEnabled, forKey: "momentsEnabled") } }
    /// Moment raw value → (screen UUID → video ID). Screens missing here use `assignments`.
    @Published var momentAssignments: [String: [String: UUID]] { didSet { save(momentAssignments, "momentAssignments") } }
    /// Moment raw value → start in minutes after midnight.
    @Published var momentStarts: [String: Int] { didSet { save(momentStarts, "momentStarts") } }
    /// Put the wallpaper above the Finder desktop icons.
    @Published var hideDesktopIcons: Bool { didSet { defaults.set(hideDesktopIcons, forKey: "hideDesktopIcons") } }

    private init() {
        defaults.register(defaults: [
            "volume": Float(0),
            "lastVolume": Float(0.5),
            "pauseWhenCovered": true,
            "lowPowerModeAsBattery": true,
            "pauseOnLowBattery": true,
            "lowBatteryLevel": 20,
        ])
        if let data = defaults.data(forKey: "assignments"),
           let value = try? JSONDecoder().decode([String: UUID].self, from: data) {
            assignments = value
        } else {
            assignments = [:]
        }
        momentsEnabled = defaults.bool(forKey: "momentsEnabled")
        momentAssignments = defaults.data(forKey: "momentAssignments")
            .flatMap { try? JSONDecoder().decode([String: [String: UUID]].self, from: $0) } ?? [:]
        momentStarts = defaults.data(forKey: "momentStarts")
            .flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        volume = defaults.float(forKey: "volume")
        lastVolume = defaults.float(forKey: "lastVolume")
        pausedManually = defaults.bool(forKey: "pausedManually")
        pauseWhenCovered = defaults.bool(forKey: "pauseWhenCovered")
        if let mode = defaults.string(forKey: "batteryMode").flatMap(BatteryMode.init(rawValue:)) {
            batteryMode = mode
        } else {
            // Before 1.6 this was a single "pause on battery" switch.
            batteryMode = defaults.bool(forKey: "pauseOnBattery") ? .pause : .keepPlaying
        }
        batteryImageID = defaults.string(forKey: "batteryImageID").flatMap(UUID.init(uuidString:))
        lowPowerModeAsBattery = defaults.bool(forKey: "lowPowerModeAsBattery")
        pauseOnLowBattery = defaults.bool(forKey: "pauseOnLowBattery")
        lowBatteryLevel = defaults.integer(forKey: "lowBatteryLevel")
        hideDesktopIcons = defaults.bool(forKey: "hideDesktopIcons")
    }

    // MARK: Moments

    func start(of moment: DayMoment) -> Int { momentStarts[moment.rawValue] ?? moment.defaultStart }

    func setStart(_ minutes: Int, for moment: DayMoment) { momentStarts[moment.rawValue] = minutes }

    /// The moment `date` falls in: the one with the latest start at or before it (wrapping past midnight).
    func moment(at date: Date) -> DayMoment {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let ordered = DayMoment.allCases.sorted { start(of: $0) < start(of: $1) }
        return ordered.last { start(of: $0) <= minutes } ?? ordered.last!
    }

    /// "07:00–14:00"
    func rangeLabel(for moment: DayMoment) -> String {
        let ordered = DayMoment.allCases.sorted { start(of: $0) < start(of: $1) }
        let index = ordered.firstIndex(of: moment)!
        let next = ordered[(index + 1) % ordered.count]
        let fmt = { (m: Int) in String(format: "%02d:%02d", m / 60, m % 60) }
        return "\(fmt(start(of: moment)))–\(fmt(start(of: next)))"
    }

    /// `nil` moment = the "always" assignment.
    func assignment(screen: String, moment: DayMoment?) -> UUID? {
        guard let moment else { return assignments[screen] }
        return momentAssignments[moment.rawValue]?[screen]
    }

    func setAssignment(_ id: UUID?, screen: String, moment: DayMoment?) {
        guard let moment else {
            assignments[screen] = id
            return
        }
        var table = momentAssignments[moment.rawValue] ?? [:]
        table[screen] = id
        momentAssignments[moment.rawValue] = table.isEmpty ? nil : table
        // Scheduling something for a moment turns the feature on.
        if id != nil && !momentsEnabled { momentsEnabled = true }
    }

    /// Moments in which `id` is shown on some screen.
    func moments(using id: UUID) -> [DayMoment] {
        DayMoment.allCases.filter { momentAssignments[$0.rawValue]?.values.contains(id) == true }
    }

    func removeEverywhere(_ id: UUID) {
        assignments = assignments.filter { $0.value != id }
        momentAssignments = momentAssignments
            .mapValues { $0.filter { $0.value != id } }
            .filter { !$0.value.isEmpty }
        if batteryImageID == id { batteryImageID = nil }
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Wallpy: login item change failed: \(error)")
        }
    }
}
