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
private func makeDesktopWindow(frame: NSRect) -> NSWindow {
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
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
        playerLayer.videoGravity = .resizeAspectFill
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
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private(set) var isOccluded = false
    var onOcclusionChange: (() -> Void)?

    init(screen: NSScreen) {
        screenID = screen.uuidString
        window = makeDesktopWindow(frame: screen.frame)
        occlusionWindow = makeDesktopWindow(frame: screen.visibleFrame)
        playerView = PlayerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init()

        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .advance
        playerView.playerLayer.player = player
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

    func setVideo(_ video: Video?) {
        guard video?.id != videoID else { return }
        videoID = video?.id
        isImage = video?.isImage ?? false
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
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
            let item = AVPlayerItem(asset: AVURLAsset(url: video.url))
            looper = AVPlayerLooper(player: player, templateItem: item)
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

    func setVolume(_ volume: Float) {
        player.volume = volume
        player.isMuted = volume == 0
    }

    func setPlaying(_ playing: Bool) {
        if playing && videoID != nil && !isImage {
            if player.timeControlStatus != .playing { player.play() }
        } else {
            player.pause()
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
        player.pause()
        looper?.disableLooping()
        window.orderOut(nil)
        occlusionWindow.orderOut(nil)
    }
}
