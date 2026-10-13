import AppKit
import AVFoundation

extension NSScreen {
    /// Stable identifier across launches and reconnections.
    var uuidString: String {
        let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let displayID = CGDirectDisplayID(number?.uint32Value ?? 0)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return "display-\(displayID)"
    }
}

enum WindowLevels {
    /// Same layer as the system wallpaper, below the Finder icons.
    static let desktop = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
    /// Just above the Finder icons, which hides them.
    static let aboveIcons = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
}

/// Borderless window glued to the desktop layer on every Space.
/// The wallpaper window is opaque so the window server never blends it with what is
/// behind it on each video frame; only the empty occlusion probe is transparent.
private func makeDesktopWindow(frame: NSRect, opaque: Bool) -> NSWindow {
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isOpaque = opaque
    window.backgroundColor = opaque ? .black : .clear
    window.hasShadow = false
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.ignoresMouseEvents = true
    return window
}

private final class PlayerView: NSView {
    let playerLayer = AVPlayerLayer()
    /// Still-image wallpapers.
    let imageLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.isOpaque = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.isOpaque = true
        playerLayer.frame = bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(playerLayer)
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.frame = bounds
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        imageLayer.isHidden = true
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// One looping player per video, shared by every screen that shows it:
/// the file is decoded once, and its sound plays once, however many screens use it.
final class PlayerPool {
    static let shared = PlayerPool()

    private final class Entry {
        let player = AVQueuePlayer()
        let looper: AVPlayerLooper
        var users = 0

        init(url: URL) {
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            player.actionAtItemEnd = .advance
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: AVURLAsset(url: url)))
        }
    }

    private var entries: [UUID: Entry] = [:]
    var volume: Float = 0 {
        didSet { entries.values.forEach { apply(volume, to: $0.player) } }
    }

    func acquire(_ video: Video) -> AVPlayer {
        let entry = entries[video.id] ?? {
            let new = Entry(url: video.url)
            apply(volume, to: new.player)
            entries[video.id] = new
            return new
        }()
        entry.users += 1
        return entry.player
    }

    func release(_ id: UUID) {
        guard let entry = entries[id] else { return }
        entry.users -= 1
        guard entry.users <= 0 else { return }
        // Last screen gone: free the decoder and its buffers.
        entry.player.pause()
        entry.looper.disableLooping()
        entry.player.removeAllItems()
        entries[id] = nil
    }

    /// Plays only the videos in `ids`; every other one is paused.
    func play(only ids: Set<UUID>) {
        for (id, entry) in entries {
            if ids.contains(id) {
                if entry.player.timeControlStatus != .playing { entry.player.play() }
            } else if entry.player.timeControlStatus != .paused {
                entry.player.pause()
            }
        }
    }

    private func apply(_ volume: Float, to player: AVPlayer) {
        player.volume = volume
        player.isMuted = volume == 0
    }
}

/// One video (or still image) wallpaper on one screen.
///
/// Occlusion uses a second, empty window that covers the screen's visible frame
/// (excluding menu bar and Dock) at the desktop layer. When app windows cover it
/// entirely — maximised windows, a full-screen app on this Space — AppKit marks
/// it occluded and the video pauses.
final class ScreenWallpaper: NSObject {
    let screenID: String
    private(set) var videoID: UUID?
    private var isImage = false
    private let window: NSWindow
    private let occlusionWindow: NSWindow
    private let playerView: PlayerView
    private(set) var isOccluded = false
    var onOcclusionChange: (() -> Void)?

    init(screen: NSScreen) {
        screenID = screen.uuidString
        window = makeDesktopWindow(frame: screen.frame, opaque: true)
        occlusionWindow = makeDesktopWindow(frame: screen.visibleFrame, opaque: false)
        playerView = PlayerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init()

        window.contentView = playerView

        occlusionWindow.contentView = NSView()
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification,
                                               object: occlusionWindow)
        applyLevel(hideIcons: Settings.shared.hideDesktopIcons)
    }

    func updateFrame(for screen: NSScreen) {
        window.setFrame(screen.frame, display: true)
        occlusionWindow.setFrame(screen.visibleFrame, display: false)
    }

    func applyLevel(hideIcons: Bool) {
        window.level = hideIcons ? WindowLevels.aboveIcons : WindowLevels.desktop
        occlusionWindow.level = window.level
        window.orderFront(nil)
        occlusionWindow.orderFront(nil)
    }

    /// The video this screen plays (nil for an image or nothing).
    var playingVideoID: UUID? { isImage ? nil : videoID }

    func setVideo(_ video: Video?) {
        guard video?.id != videoID else { return }
        if let old = videoID, !isImage { PlayerPool.shared.release(old) }
        playerView.playerLayer.player = nil
        videoID = video?.id
        isImage = video?.isImage ?? false
        playerView.imageLayer.contents = nil
        playerView.imageLayer.isHidden = !isImage
        playerView.playerLayer.isHidden = isImage
        guard let video else {
            window.orderOut(nil)
            occlusionWindow.orderOut(nil)
            return
        }
        if video.isImage {
            showImage(video)
        } else {
            playerView.playerLayer.player = PlayerPool.shared.acquire(video)
        }
        window.orderFront(nil)
        occlusionWindow.orderFront(nil)
    }

    /// Decodes the image at screen resolution (not full size: a 50 MP photo would waste memory).
    private func showImage(_ video: Video) {
        let id = video.id
        let scale = window.screen?.backingScaleFactor ?? 2
        let maxPixels = Int(max(window.frame.width, window.frame.height) * scale)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = ImageLoader.downsample(video.url, maxPixelSize: maxPixels)
            DispatchQueue.main.async {
                guard let self, self.videoID == id else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.playerView.imageLayer.contents = image
                self.playerView.imageLayer.contentsScale = scale
                CATransaction.commit()
            }
        }
    }

    @objc private func occlusionChanged() {
        let occluded = !occlusionWindow.occlusionState.contains(.visible)
        guard occluded != isOccluded else { return }
        isOccluded = occluded
        onOcclusionChange?()
    }

    func close() {
        NotificationCenter.default.removeObserver(self)
        setVideo(nil)
        window.orderOut(nil)
        occlusionWindow.orderOut(nil)
    }
}
