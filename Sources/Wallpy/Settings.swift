import Foundation
import ServiceManagement

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
    @Published var pauseOnBattery: Bool { didSet { defaults.set(pauseOnBattery, forKey: "pauseOnBattery") } }
    @Published var pauseOnLowBattery: Bool { didSet { defaults.set(pauseOnLowBattery, forKey: "pauseOnLowBattery") } }
    @Published var lowBatteryLevel: Int { didSet { defaults.set(lowBatteryLevel, forKey: "lowBatteryLevel") } }
    /// Put the wallpaper above the Finder desktop icons.
    @Published var hideDesktopIcons: Bool { didSet { defaults.set(hideDesktopIcons, forKey: "hideDesktopIcons") } }

    private init() {
        defaults.register(defaults: [
            "volume": Float(0),
            "lastVolume": Float(0.5),
            "pauseWhenCovered": true,
            "pauseOnBattery": false,
            "pauseOnLowBattery": true,
            "lowBatteryLevel": 20,
        ])
        if let data = defaults.data(forKey: "assignments"),
           let value = try? JSONDecoder().decode([String: UUID].self, from: data) {
            assignments = value
        } else {
            assignments = [:]
        }
        volume = defaults.float(forKey: "volume")
        lastVolume = defaults.float(forKey: "lastVolume")
        pausedManually = defaults.bool(forKey: "pausedManually")
        pauseWhenCovered = defaults.bool(forKey: "pauseWhenCovered")
        pauseOnBattery = defaults.bool(forKey: "pauseOnBattery")
        pauseOnLowBattery = defaults.bool(forKey: "pauseOnLowBattery")
        lowBatteryLevel = defaults.integer(forKey: "lowBatteryLevel")
        hideDesktopIcons = defaults.bool(forKey: "hideDesktopIcons")
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
