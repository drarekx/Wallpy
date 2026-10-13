import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var libraryWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Migration.fromMyWallpaper()
        setupMainMenu()
        removeLeftoverDownloads()
        VideoLibrary.shared.load()
        WallpaperManager.shared.start()
        setupStatusItem()
        Updater.shared.start()

        // Development: `Wallpy --edit <file>` opens the loop editor directly.
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--edit"), index + 1 < args.count {
            let url = URL(fileURLWithPath: args[index + 1])
            Task { @MainActor in
                if let info = await SourceInfo.load(url) {
                    let work = FileManager.default.temporaryDirectory
                        .appendingPathComponent("Wallpy-\(UUID().uuidString)", isDirectory: true)
                    EditorWindowController.open(url: url, info: info, name: url.deletingPathExtension().lastPathComponent, workDir: work)
                }
            }
            return
        }

        // First launch (or empty library): show the library so the user can add videos.
        if VideoLibrary.shared.videos.isEmpty {
            showLibrary()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLibrary()
        return true
    }

    /// Downloads live in a temp folder that the editor deletes on close;
    /// clean up any left behind by a crash or force quit.
    private func removeLeftoverDownloads() {
        let temp = FileManager.default.temporaryDirectory
        let items = (try? FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix("Wallpy-") {
            try? FileManager.default.removeItem(at: item)
        }
    }

    // MARK: - Main menu

    /// Accessory apps show no menu bar, but text fields still need an Edit menu
    /// for ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z to reach them.
    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Cerrar ventana", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Salir de Wallpy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edición")
        edit.addItem(withTitle: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Rehacer", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    // MARK: - Status bar menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "play.rectangle.on.rectangle",
                                           accessibilityDescription: "Wallpy")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = Settings.shared

        menu.addItem(withTitle: "Abrir biblioteca…", action: #selector(showLibrary), keyEquivalent: "l").target = self
        menu.addItem(.separator())

        let pause = menu.addItem(withTitle: "Pausar fondos", action: #selector(togglePause), keyEquivalent: "p")
        pause.target = self
        pause.state = settings.pausedManually ? .on : .off

        let mute = menu.addItem(withTitle: "Silenciar", action: #selector(toggleMute), keyEquivalent: "")
        mute.target = self
        mute.state = settings.volume == 0 ? .on : .off

        let icons = menu.addItem(withTitle: "Ocultar iconos del escritorio", action: #selector(toggleIcons), keyEquivalent: "")
        icons.target = self
        icons.state = settings.hideDesktopIcons ? .on : .off

        let login = menu.addItem(withTitle: "Abrir al iniciar sesión", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off

        menu.addItem(.separator())
        let updating = Updater.shared.state != .idle
        let update = menu.addItem(withTitle: updating ? "Actualizando…" : "Buscar actualizaciones…",
                                  action: updating ? nil : #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        let version = menu.addItem(withTitle: "Wallpy \(Updater.currentVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(withTitle: "Salir de Wallpy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func showLibrary() {
        if libraryWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Wallpy"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 720, height: 480)
            window.contentViewController = NSHostingController(rootView: LibraryView())
            window.center()
            libraryWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        libraryWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func checkForUpdates() {
        Task { await Updater.shared.check(userInitiated: true) }
    }

    @objc private func togglePause() { Settings.shared.pausedManually.toggle() }

    @objc private func toggleMute() {
        let settings = Settings.shared
        if settings.volume == 0 {
            settings.volume = settings.lastVolume > 0 ? settings.lastVolume : 0.5
        } else {
            settings.lastVolume = settings.volume
            settings.volume = 0
        }
    }

    @objc private func toggleIcons() { Settings.shared.hideDesktopIcons.toggle() }

    @objc private func toggleLogin() { LoginItem.setEnabled(!LoginItem.isEnabled) }
}
