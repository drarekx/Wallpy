import AppKit
import Combine

struct ScreenInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let frame: NSRect
}

/// Keeps one ScreenWallpaper per connected display in sync with Settings,
/// and decides when videos play or pause.
@MainActor
final class WallpaperManager: ObservableObject {
    static let shared = WallpaperManager()

    @Published private(set) var screens: [ScreenInfo] = []
    @Published private(set) var power = PowerState.current()

    private var wallpapers: [String: ScreenWallpaper] = [:]
    private var screensAsleep = false
    private var sessionInactive = false
    private var powerMonitor: PowerMonitor?
    private var cancellables = Set<AnyCancellable>()

    func start() {
        let settings = Settings.shared
        let library = VideoLibrary.shared

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.syncScreens() }
            .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.screensDidSleepNotification)
            .sink { [weak self] _ in self?.screensAsleep = true; self?.updatePlayback() }
            .store(in: &cancellables)
        workspace.publisher(for: NSWorkspace.screensDidWakeNotification)
            .sink { [weak self] _ in self?.screensAsleep = false; self?.updatePlayback() }
            .store(in: &cancellables)
        workspace.publisher(for: NSWorkspace.sessionDidResignActiveNotification)
            .sink { [weak self] _ in self?.sessionInactive = true; self?.updatePlayback() }
            .store(in: &cancellables)
        workspace.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification)
            .sink { [weak self] _ in self?.sessionInactive = false; self?.updatePlayback() }
            .store(in: &cancellables)

        settings.$assignments.combineLatest(library.$videos)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyAssignments() }
            .store(in: &cancellables)
        settings.$volume
            .sink { [weak self] volume in self?.wallpapers.values.forEach { $0.setVolume(volume) } }
            .store(in: &cancellables)
        settings.$hideDesktopIcons
            .sink { [weak self] hide in self?.wallpapers.values.forEach { $0.applyLevel(hideIcons: hide) } }
            .store(in: &cancellables)
        Publishers.MergeMany(
            settings.$pausedManually.map { _ in () }.eraseToAnyPublisher(),
            settings.$pauseWhenCovered.map { _ in () }.eraseToAnyPublisher(),
            settings.$pauseOnBattery.map { _ in () }.eraseToAnyPublisher(),
            settings.$pauseOnLowBattery.map { _ in () }.eraseToAnyPublisher(),
            settings.$lowBatteryLevel.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.updatePlayback() }
        .store(in: &cancellables)

        powerMonitor = PowerMonitor { [weak self] in
            DispatchQueue.main.async {
                self?.power = PowerState.current()
                self?.updatePlayback()
            }
        }

        syncScreens()
    }

    private func syncScreens() {
        let current = NSScreen.screens
        screens = current.map { ScreenInfo(id: $0.uuidString, name: $0.localizedName, frame: $0.frame) }
        let ids = Set(screens.map(\.id))

        for (id, wallpaper) in wallpapers where !ids.contains(id) {
            wallpaper.close()
            wallpapers[id] = nil
        }
        for screen in current {
            let id = screen.uuidString
            if let existing = wallpapers[id] {
                existing.updateFrame(for: screen)
            } else {
                let wallpaper = ScreenWallpaper(screen: screen)
                wallpaper.setVolume(Settings.shared.volume)
                wallpaper.onOcclusionChange = { [weak self] in self?.updatePlayback() }
                wallpapers[id] = wallpaper
            }
        }
        applyAssignments()
    }

    private func applyAssignments() {
        let library = VideoLibrary.shared
        for (id, wallpaper) in wallpapers {
            wallpaper.setVideo(library.video(id: Settings.shared.assignments[id]))
        }
        updatePlayback()
    }

    private func updatePlayback() {
        let settings = Settings.shared
        var globallyPaused = settings.pausedManually || screensAsleep || sessionInactive
        if settings.pauseOnBattery && power.onBattery { globallyPaused = true }
        if settings.pauseOnLowBattery, power.onBattery, let level = power.batteryLevel,
           level <= settings.lowBatteryLevel {
            globallyPaused = true
        }
        for wallpaper in wallpapers.values {
            let covered = settings.pauseWhenCovered && wallpaper.isOccluded
            wallpaper.setPlaying(!globallyPaused && !covered)
        }
    }

    // MARK: - Actions used by the UI

    func setVideo(_ video: Video?, onScreen id: String) {
        Settings.shared.assignments[id] = video?.id
    }

    func setVideoOnAllScreens(_ video: Video) {
        var assignments = Settings.shared.assignments
        for screen in screens { assignments[screen.id] = video.id }
        Settings.shared.assignments = assignments
    }
}
