import AppKit
import Combine

struct ScreenInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let frame: NSRect
}

/// Why wallpapers are (not) moving, shown in the sidebar.
enum PlaybackStatus: Equatable {
    case playing, pausedManually, pausedOnBattery, imageOnBattery, pausedLowBattery, pausedHot, idle
}

/// Keeps one ScreenWallpaper per connected display in sync with Settings,
/// and decides when videos play or pause.
@MainActor
final class WallpaperManager: ObservableObject {
    static let shared = WallpaperManager()

    @Published private(set) var screens: [ScreenInfo] = []
    @Published private(set) var power = PowerState.current()
    @Published private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var status: PlaybackStatus = .idle
    @Published private(set) var currentMoment = Settings.shared.moment(at: Date())
    /// Screen UUID → what it shows right now (after moments and battery rules).
    @Published private(set) var displayed: [String: UUID] = [:]
    private var momentTimer: Timer?
    private var tooHot = WallpaperManager.isTooHot

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

        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.tooHot = Self.isTooHot; self?.updatePlayback() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                self?.applyAssignments()
            }
            .store(in: &cancellables)

        // Re-evaluate the moment whenever the clock may have jumped.
        Publishers.MergeMany(
            workspace.publisher(for: NSWorkspace.didWakeNotification).map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: .NSSystemClockDidChange).map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).map { _ in () }.eraseToAnyPublisher(),
            settings.$momentStarts.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.updateMoment() }
        .store(in: &cancellables)

        Publishers.MergeMany(
            settings.$assignments.map { _ in () }.eraseToAnyPublisher(),
            settings.$momentAssignments.map { _ in () }.eraseToAnyPublisher(),
            settings.$momentsEnabled.map { _ in () }.eraseToAnyPublisher(),
            library.$videos.map { _ in () }.eraseToAnyPublisher(),
            settings.$batteryMode.map { _ in () }.eraseToAnyPublisher(),
            settings.$batteryImageID.map { _ in () }.eraseToAnyPublisher(),
            settings.$lowPowerModeAsBattery.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.applyAssignments() }
        .store(in: &cancellables)
        settings.$volume
            .sink { volume in PlayerPool.shared.volume = volume }
            .store(in: &cancellables)
        settings.$hideDesktopIcons
            .sink { [weak self] hide in self?.wallpapers.values.forEach { $0.applyLevel(hideIcons: hide) } }
            .store(in: &cancellables)
        Publishers.MergeMany(
            settings.$pausedManually.map { _ in () }.eraseToAnyPublisher(),
            settings.$pauseWhenCovered.map { _ in () }.eraseToAnyPublisher(),
            settings.$pauseOnLowBattery.map { _ in () }.eraseToAnyPublisher(),
            settings.$lowBatteryLevel.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.updatePlayback() }
        .store(in: &cancellables)

        powerMonitor = PowerMonitor { [weak self] in
            DispatchQueue.main.async {
                self?.power = PowerState.current()
                // Plugging in or out may swap videos for the battery image.
                self?.applyAssignments()
            }
        }

        syncScreens()
        scheduleMomentTimer()
    }

    // MARK: - Moments of the day

    private func updateMoment() {
        let moment = Settings.shared.moment(at: Date())
        if moment != currentMoment {
            currentMoment = moment
            applyAssignments()
        }
        scheduleMomentTimer()
    }

    /// One timer for the next boundary, so nothing runs between changes.
    private func scheduleMomentTimer() {
        momentTimer?.invalidate()
        let settings = Settings.shared
        let calendar = Calendar.current
        let now = Date()
        let starts = DayMoment.allCases.map { settings.start(of: $0) }
        let candidates = (0...1).flatMap { dayOffset in
            starts.compactMap { minutes -> Date? in
                guard let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) else { return nil }
                return calendar.date(byAdding: .minute, value: minutes, to: day)
            }
        }
        guard let next = candidates.filter({ $0 > now.addingTimeInterval(1) }).min() else { return }
        let timer = Timer(fire: next.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMoment() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        momentTimer = timer
    }

    /// Video for a screen right now: the current moment's, else the "always" one.
    private func scheduledVideo(for screenID: String) -> Video? {
        let settings = Settings.shared
        let library = VideoLibrary.shared
        if settings.momentsEnabled, let id = settings.assignment(screen: screenID, moment: currentMoment),
           let video = library.video(id: id) {
            return video
        }
        return library.video(id: settings.assignments[screenID])
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
                wallpaper.onOcclusionChange = { [weak self] in self?.updatePlayback() }
                wallpapers[id] = wallpaper
            }
        }
        applyAssignments()
    }

    private static var isTooHot: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }

    /// On battery, or in Low Power Mode when that option is on.
    var savingPower: Bool {
        power.onBattery || (Settings.shared.lowPowerModeAsBattery && lowPowerMode)
    }

    /// The still image that replaces videos while saving power, if that mode is chosen.
    private var batteryImage: Video? {
        let settings = Settings.shared
        guard savingPower, settings.batteryMode == .image,
              let image = VideoLibrary.shared.video(id: settings.batteryImageID), image.isImage else { return nil }
        return image
    }

    private func applyAssignments() {
        let replacement = batteryImage
        for (id, wallpaper) in wallpapers {
            // Screens without a wallpaper stay empty; the others show the battery image instead of a video.
            let assigned = scheduledVideo(for: id)
            wallpaper.setVideo(assigned == nil ? nil : (replacement ?? assigned))
        }
        let shown = wallpapers.compactMapValues(\.videoID)
        if shown != displayed { displayed = shown }
        updatePlayback()
    }

    private func updatePlayback() {
        let settings = Settings.shared
        let lowBattery = settings.pauseOnLowBattery && power.onBattery
            && (power.batteryLevel.map { $0 <= settings.lowBatteryLevel } ?? false)

        let newStatus: PlaybackStatus
        if settings.pausedManually {
            newStatus = .pausedManually
        } else if batteryImage != nil {
            newStatus = .imageOnBattery
        } else if savingPower && settings.batteryMode == .pause {
            newStatus = .pausedOnBattery
        } else if lowBattery {
            newStatus = .pausedLowBattery
        } else if tooHot {
            newStatus = .pausedHot
        } else if wallpapers.values.contains(where: { $0.playingVideoID != nil }) {
            newStatus = .playing
        } else {
            newStatus = .idle
        }
        if status != newStatus { status = newStatus }

        var playing = Set<UUID>()
        if newStatus == .playing && !screensAsleep && !sessionInactive {
            for wallpaper in wallpapers.values {
                guard let id = wallpaper.playingVideoID else { continue }
                if settings.pauseWhenCovered && wallpaper.isOccluded { continue }
                playing.insert(id)
            }
        }
        PlayerPool.shared.play(only: playing)
    }

    // MARK: - Actions used by the UI

    /// `moment` nil = always.
    func setVideo(_ video: Video?, onScreen id: String, moment: DayMoment? = nil) {
        Settings.shared.setAssignment(video?.id, screen: id, moment: moment)
    }

    func setVideoOnAllScreens(_ video: Video, moment: DayMoment? = nil) {
        guard let moment else {
            var assignments = Settings.shared.assignments
            for screen in screens { assignments[screen.id] = video.id }
            Settings.shared.assignments = assignments
            return
        }
        for screen in screens { Settings.shared.setAssignment(video.id, screen: screen.id, moment: moment) }
    }
}
