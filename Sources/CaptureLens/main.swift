import AppKit
import CaptureLensKit
import SwiftUI
import UniformTypeIdentifiers

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(AppPresence.showInDock ? .regular : .accessory)
    app.run()
}

/// Launch, the menu bar item, the Dock menu, and reopening.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let engine = CaptureEngine.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearance.start()
        let mainMenu = AppPresence.mainMenu(appName: AppInfo.name, settingsTitle: "Settings…",
                                            target: self, settings: #selector(showSettings))
        // Right below About in the app menu.
        mainMenu.items.first?.submenu?.insertItem(item("Our other apps…", #selector(showOtherApps)), at: 1)
        mainMenu.addItem(editMenu())
        // Help menu, with the standard ⌘? (macOS adds its search field).
        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        let helpOpen = NSMenuItem(title: "CaptureLens Help", action: #selector(showHelp), keyEquivalent: "?")
        helpOpen.target = self
        help.addItem(helpOpen)
        helpItem.submenu = help
        mainMenu.addItem(helpItem)
        NSApp.helpMenu = help
        NSApp.mainMenu = mainMenu
        #if DEBUG
        // A test run shares the installed app's settings, so it checks Help and stops
        // before sync or anything else starts.
        if let snapshot = ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_HELP_TEST"] {
            DebugHelpTest.run(snapshot: snapshot, delegate: self)
            return
        }
        if let folder = ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_SNAPSHOT"] {
            setUpStatusItem()
            DebugSelfTest.run(folder: folder)
            return
        }
        #endif
        // Set at the end of the first launch, so its absence means a brand-new install.
        let newInstall = !AppDefaults.store.bool(forKey: "welcomed")
        _ = LibraryStore.shared
        _ = LibraryLock.shared
        if newInstall { SettingsSync.shared.adoptOnNewInstall() }
        SettingsSync.shared.start()
        // CloudKit tells the sync engine about other Macs' changes by push.
        NSApp.registerForRemoteNotifications()
        #if DEBUG
        SyncDebugHook.run()
        #endif

        HotKeyCenter.shared.perform = { [weak self] action in self?.perform(action) }
        HotKeyCenter.shared.apply()

        setUpStatusItem()
        // ToolHUD can take the menu into its own while it runs.
        NotificationCenter.default.addObserver(forName: AppPresence.menuBarDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in self?.statusItem?.isVisible = MenuHub.shared.showsOwnIcon }
        }
        #if !APPSTORE
        // A sandboxed build can't name the message port, so the App Store version stays out.
        MenuHub.shared.onChange = { SettingsSync.shared.localDidChange() }
        MenuHub.shared.start(menu: { [weak self] in
            let menu = NSMenu()
            self?.menuNeedsUpdate(menu)
            return menu
        }, icon: { [weak self] in self?.statusItem?.button?.image })
        #endif

        AutoUpdater.shared.start()
        // Sync is on but waiting for a passphrase (joining another Mac): say so where it
        // can be entered, once per version.
        let sync = SettingsSync.shared
        let syncNeedsPassphrase = sync.isEnabled && [.needsPassphrase, .needsNewPassphrase].contains(sync.keyState)
            && AppDefaults.store.string(forKey: "sync.passphrasePromptVersion") != AppInfo.version
        if syncNeedsPassphrase { AppDefaults.store.set(AppInfo.version, forKey: "sync.passphrasePromptVersion") }
        if newInstall {
            AppDefaults.store.set(true, forKey: "welcomed")
            // Ask for Screen Recording up front, so the first capture just works.
            if !ScreenAccess.granted { ScreenAccess.request() }
            LibraryWindow.shared.show()
            HelpWindow.shared.show(topic: "getting-started")
        } else if syncNeedsPassphrase {
            SettingsWindow.shared.show(tab: "General")
        } else if !AppPresence.showInMenuBar && !AppPresence.showInDock {
            showSettings()
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = AppPresence.dockMenu(title: "Settings…", target: self, action: #selector(showSettings))
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(item("Open Library", #selector(showLibrary)), at: 0)
        for item in captureItems().reversed() { menu.insertItem(item, at: 0) }
        return menu
    }

    /// Opening the app again (from Applications, Spotlight, or the Dock tile) shows the
    /// library, or Settings when CaptureLens has no icon anywhere to reach them from.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !AppPresence.showInMenuBar && !AppPresence.showInDock { showSettings() } else if !flag { showLibrary() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Pictures dropped on the Dock icon or opened with CaptureLens go into the library, and
    /// `capturelens://` URLs (from ToolHUD, Shortcuts or a script) run the action they name.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "capturelens" {
            handle(url)
        }
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty {
            let count = LibraryStore.shared.importFiles(files)
            Notice.shared.show(count == 0 ? "Those files aren't pictures" : "Added \(count) picture\(count == 1 ? "" : "s") to the library",
                               symbol: count == 0 ? "exclamationmark.triangle.fill" : "photo.on.rectangle",
                               tint: count == 0 ? .systemOrange : .systemGreen)
        }
    }

    /// The `capturelens://<host>` actions. Their names and titles are also listed under
    /// ToolHUDActions in Info.plist, which is how ToolHUD finds them.
    private func handle(_ url: URL) {
        let presets = Preferences.shared.presets
        func run(mode: CaptureMode) {
            let preset = presets.first { $0.mode == mode && $0.delay == 0 } ?? CapturePreset(name: mode.title, mode: mode)
            engine.run(preset)
        }
        switch url.host ?? "" {
        case "capture": run(mode: .allInOne)
        case "screen": run(mode: .screen)
        case "window": run(mode: .window)
        case "area": run(mode: .region)
        case "recapture": engine.captureAgain()
        case "library": showLibrary()
        case "preset":
            let name = url.pathComponents.dropFirst().joined(separator: "/")
            if let preset = presets.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                engine.run(preset)
            } else {
                Notice.shared.show(error: "No preset called “\(name)”")
            }
        default: break
        }
    }

    private func perform(_ action: HotKeyCenter.Action) {
        switch action {
        case .preset(let id): if let preset = Preferences.shared.preset(id) { engine.run(preset) }
        case .captureAgain: engine.captureAgain()
        case .library: showLibrary()
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.isVisible = MenuHub.shared.showsOwnIcon
        let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: AppInfo.name)
        image?.isTemplate = true
        item.button?.image = image
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let prefs = Preferences.shared

        if !ScreenAccess.granted {
            let warn = item("Allow Screen Recording…", #selector(allowScreenRecording))
            warn.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        for item in captureItems() { menu.addItem(item) }
        let again = item("Capture Same Area Again", #selector(captureAgain), hotKey: prefs.captureAgainHotKey)
        again.isEnabled = engine.lastRegion != nil
        menu.addItem(again)

        menu.addItem(.separator())
        menu.addItem(item("Open Library…", #selector(showLibrary), hotKey: prefs.libraryHotKey, symbol: "photo.on.rectangle"))
        let recent = LibraryStore.shared.items.prefix(5)
        if !recent.isEmpty && !LibraryLock.shared.isLocked {
            let recentItem = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for entry in recent {
                let row = item(entry.name, #selector(copyRecent(_:)))
                row.representedObject = entry.id
                row.toolTip = "Copy \(entry.name). ⌥ opens it in the library."
                let open = item(entry.name, #selector(openRecent(_:)))
                open.representedObject = entry.id
                open.isAlternate = true
                open.keyEquivalentModifierMask = .option
                sub.addItem(row)
                sub.addItem(open)
            }
            recentItem.submenu = sub
            menu.addItem(recentItem)
        }
        menu.addItem(item("Import Pictures…", #selector(importPictures)))
        menu.addItem(toggle("Copy Captures to Clipboard", prefs.copyToClipboard, #selector(toggleClipboard)))
        menu.addItem(toggle("Open Captures in Library", prefs.afterCapture == .openLibrary, #selector(toggleOpenInLibrary)))

        menu.addItem(.separator())
        let helpEntry = NSMenuItem(title: "CaptureLens Help", action: #selector(showHelp), keyEquivalent: "")
        helpEntry.target = self
        helpEntry.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        menu.addItem(helpEntry)
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        #if !APPSTORE
        if let staged = AutoUpdater.shared.staged {
            menu.addItem(item("Update to \(staged.version) Now (Otherwise Installs When Idle)", #selector(installUpdateNow)))
        } else if let pending = UpdateAvailability.shared.pending {
            menu.addItem(item("Update to \(pending)…", #selector(checkForUpdates)))
        } else {
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        }
        #endif
        menu.addItem(item("About \(AppInfo.name)", #selector(showAbout)))
        menu.addItem(item("Our other apps…", #selector(showOtherApps)))
        menu.addItem(.separator())
        let version = NSMenuItem(title: "\(AppInfo.name) \(AppInfo.displayVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(item("Quit \(AppInfo.name)", #selector(quit), key: "q"))
    }

    /// One item per preset.
    private func captureItems() -> [NSMenuItem] {
        Preferences.shared.presets.map { preset in
            let entry = item(preset.name, #selector(runPreset(_:)), hotKey: preset.hotKey, symbol: preset.mode.symbol)
            entry.representedObject = preset.id
            entry.toolTip = preset.summary
            return entry
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "", hotKey: HotKey? = nil,
                      symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let shortcut = hotKey?.menuKeyEquivalent {
            item.keyEquivalent = shortcut.key
            item.keyEquivalentModifierMask = shortcut.mask
        }
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let item = item(title, action)
        item.state = on ? .on : .off
        return item
    }

    /// Cut, Copy, Paste and Select All, so text fields in the library and Settings take them.
    private func editMenu() -> NSMenuItem {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem()
        item.submenu = edit
        return item
    }

    // MARK: - Actions

    @objc func runPreset(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let preset = Preferences.shared.preset(id) else { return }
        engine.run(preset)
    }
    @objc func captureAgain() { engine.captureAgain() }
    @objc func showLibrary() { LibraryWindow.shared.show() }
    @objc func copyRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let entry = LibraryStore.shared.entry(id),
              let png = Flattener.png(entry) else { return }
        Clipboard.copy(png: png)
        Notice.shared.show("Copied “\(entry.name)”", symbol: "doc.on.doc")
    }
    @objc func openRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        LibraryWindow.shared.show(select: id)
    }
    @objc func importPictures() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose pictures to add to the library"
        guard panel.runModal() == .OK else { return }
        let count = LibraryStore.shared.importFiles(panel.urls)
        Notice.shared.show("Added \(count) picture\(count == 1 ? "" : "s") to the library", symbol: "photo.on.rectangle")
    }
    @objc func toggleClipboard() { Preferences.shared.copyToClipboard.toggle() }
    @objc func toggleOpenInLibrary() {
        let prefs = Preferences.shared
        prefs.afterCapture = prefs.afterCapture == .openLibrary ? .preview : .openLibrary
    }
    @objc func allowScreenRecording() {
        if !ScreenAccess.request() { ScreenAccess.openSettings() }
    }
    @objc func showSettings() { SettingsWindow.shared.show() }
    @objc func showHelp() { HelpWindow.shared.show() }
    @objc func checkForUpdates() { UpdateController.checkForUpdates() }
    @objc func installUpdateNow() { AutoUpdater.shared.installNow() }
    @objc func quit() { NSApp.terminate(nil) }

    /// The developer's site, which lists every app.
    @objc func showOtherApps() {
        if let url = URL(string: "https://stevemanke.com/") { NSWorkspace.shared.open(url) }
    }
    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
