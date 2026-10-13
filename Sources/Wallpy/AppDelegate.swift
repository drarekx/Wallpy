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
        Localizer.shared.$choice
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.setupMainMenu() }
            .store(in: &cancellables)
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
        appMenu.addItem(withTitle: tr("Cerrar ventana"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: tr("Salir de Wallpy"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: tr("Edición"))
        edit.addItem(withTitle: tr("Deshacer"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: tr("Rehacer"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: tr("Cortar"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("Copiar"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("Pegar"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("Seleccionar todo"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
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

        menu.addItem(withTitle: tr("Abrir biblioteca…"), action: #selector(showLibrary), keyEquivalent: "l").target = self
        menu.addItem(.separator())

        let pause = menu.addItem(withTitle: tr("Pausar fondos"), action: #selector(togglePause), keyEquivalent: "p")
        pause.target = self
        pause.state = settings.pausedManually ? .on : .off

        let mute = menu.addItem(withTitle: tr("Silenciar"), action: #selector(toggleMute), keyEquivalent: "")
        mute.target = self
        mute.state = settings.volume == 0 ? .on : .off

        let icons = menu.addItem(withTitle: tr("Ocultar iconos del escritorio"), action: #selector(toggleIcons), keyEquivalent: "")
        icons.target = self
        icons.state = settings.hideDesktopIcons ? .on : .off

        let login = menu.addItem(withTitle: tr("Abrir al iniciar sesión"), action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off

        menu.addItem(.separator())
        let updating = Updater.shared.state != .idle
        let update = menu.addItem(withTitle: updating ? tr("Actualizando…") : tr("Buscar actualizaciones…"),
                                  action: updating ? nil : #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        let coffee = menu.addItem(withTitle: tr("Invítame a un café…"), action: #selector(openBuyMeACoffee), keyEquivalent: "")
        coffee.target = self
        coffee.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: nil)
        let version = menu.addItem(withTitle: "Wallpy \(Updater.currentVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(withTitle: tr("Salir de Wallpy"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func showLibrary() {
        if libraryWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Wallpy"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 960, height: 600)
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(red: 0x12 / 255, green: 0x12 / 255, blue: 0x14 / 255, alpha: 1)
            window.titlebarAppearsTransparent = true
            let hosting = NSHostingController(rootView: LibraryView())
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 1280, height: 800))
            window.center()
            libraryWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        libraryWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openBuyMeACoffee() {
        NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/drarek")!)
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
