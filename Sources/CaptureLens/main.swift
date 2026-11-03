import AppKit
import CaptureLensKit
import SwiftUI
import UniformTypeIdentifiers

MainActor.assumeIsolated {
    // Tooltips after 0.375 s instead of the system's 1.5 s. AppKit reads this once, as it
    // starts, so it's registered first; a value set with `defaults write` still wins.
    UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 375])
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(AppPresence.showInDock ? .regular : .accessory)
    app.run()
}

/// Quits SnagAnything without asking: for quitting itself (installing an update, ending a test).
@MainActor
enum QuitConfirmation {
    private(set) static var confirmed = false

    static func quitNow() {
        confirmed = true
        NSApp.terminate(nil)
    }
}

/// Launch, the menu bar item, the Dock menu, and reopening.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem?
    private let engine = CaptureEngine.shared

    func applicationWillTerminate(_ notification: Notification) {
        // Unsealed copies made for playing don't outlive the app.
        VideoStore.shared.clearPlayback()
    }

    /// Quitting asks first, while "Ask before quitting" is on in Settings › General. Not when
    /// the Mac is logging out, restarting or shutting down (macOS gives the quit a reason
    /// then), and not when SnagAnything quits itself to install an update.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let systemQuit = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        guard Preferences.shared.confirmQuit, !QuitConfirmation.confirmed, !systemQuit else { return .terminateNow }

        // A menu bar app needs to be a regular one for the alert to come to the front; the
        // old policy goes back a runloop turn later, once the alert is gone (AppKit ignores
        // it while the modal still holds the app active).
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { DispatchQueue.main.async { NSApp.setActivationPolicy(previousPolicy) } }

        let alert = NSAlert()
        alert.messageText = "Quit \(AppInfo.name)?"
        alert.informativeText = "Capture shortcuts stop working until you open \(AppInfo.name) again."
        // NSAlert puts a Cancel button on Esc, and Quit has no key, so Return does nothing:
        // quitting takes a click on Quit, never a stray keystroke.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit").keyEquivalent = ""
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        alert.layout()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)

        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        if alert.suppressionButton?.state == .on { Preferences.shared.confirmQuit = false }
        return .terminateNow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Updated from CaptureLens: becomes SnagAnything.app and reopens from there first.
        if AppRename.renameIfNeeded() { return }
        AppAppearance.start()
        // One library window: no tab bar items in the View and Window menus.
        NSWindow.allowsAutomaticWindowTabbing = false
        let mainMenu = AppPresence.mainMenu(appName: AppInfo.name, settingsTitle: "Settings…",
                                            target: self, settings: #selector(showSettings))
        // Right below About in the app menu, where Mac apps keep it.
        #if APPSTORE
        mainMenu.items.first?.submenu?.insertItem(item("Our other apps…", #selector(showOtherApps)), at: 1)
        #else
        mainMenu.items.first?.submenu?.insertItem(item("Check for Updates…", #selector(checkForUpdates)), at: 1)
        mainMenu.items.first?.submenu?.insertItem(item("Our other apps…", #selector(showOtherApps)), at: 2)
        #endif
        // In Apple's order, ahead of the Window menu: File, Edit, View, then Capture.
        for (index, menu) in [fileMenu(), editMenu(), viewMenu(), captureMenu()].enumerated() {
            mainMenu.insertItem(menu, at: 1 + index)
        }
        // Help menu, with the standard ⌘? (macOS adds its search field).
        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        let helpOpen = NSMenuItem(title: "SnagAnything Help", action: #selector(showHelp), keyEquivalent: "?")
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
        if let out = ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_SHOTS"] {
            DebugShots.run(out: URL(fileURLWithPath: out))
            return
        }
        if let spec = ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_SCROLL"] {
            DebugScrollTest.run(spec: spec)
            return
        }
        if let out = ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_SNAGIT_EVAL"] {
            DebugSelfTest.snagitEval(out: URL(fileURLWithPath: out))
            return
        }
        if let folder = ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_TEXT_UPDATES"] {
            DebugTextAndUpdates.run(folder: folder)
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
        CaptureCollector.shared.start()
        LibraryLayout.start()
        // CloudKit tells the sync engine about other Macs' changes by push.
        NSApp.registerForRemoteNotifications()
        #if DEBUG
        SyncDebugHook.run()
        #endif

        HotKeyCenter.shared.perform = { [weak self] action in self?.perform(action) }
        HotKeyCenter.shared.apply()
        #if !APPSTORE
        // A sandboxed app can't send a distributed notification's userInfo.
        ShortcutsLensReport.start { HotKeyCenter.shared.reportedShortcuts }
        #endif

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

        CaptureBar.shared.start()
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

    /// Clicking the Dock icon (or opening the app again from Applications or Spotlight)
    /// brings up the library, even when Settings or Help is open. With no icon anywhere,
    /// it opens Settings instead, the only way back to them.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !AppPresence.showInMenuBar && !AppPresence.showInDock { showSettings() } else { showLibrary() }
        return false
    }

    /// Chosen in the app switcher (⌘-Tab) with no window open: show the library, as a Dock
    /// click does. Checked a moment later, so a window SnagAnything is opening itself
    /// (Settings, an alert, an Open panel, the capture overlay) means it's not that.
    func applicationDidBecomeActive(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard NSApp.isActive, AppPresence.showInDock, NSApp.modalWindow == nil,
                      !CaptureOverlay.shared.isSelecting, !CaptureEngine.shared.isBusy,
                      !NSApp.windows.contains(where: { $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain })
                else { return }
                self?.showLibrary()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Pictures dropped on the Dock icon or opened with SnagAnything go into the library, and
    /// `snaganything://` URLs (from ToolHUD, Shortcuts or a script) run the action they name.
    func application(_ application: NSApplication, open urls: [URL]) {
        // capturelens:// is the name before 1.1.0, still used by older ToolHUD buttons and scripts.
        for url in urls where url.scheme == "snaganything" || url.scheme == "capturelens" {
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

    /// The `snaganything://<host>` actions. Their names and titles are also listed under
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
        case "scrolling": run(mode: .scrolling)
        case "steps": toggleSteps()
        case "record": run(mode: .recording)
        case "recapture": engine.captureAgain()
        case "text": engine.captureText()
        case "library": showLibrary()
        case "capturebar": toggleCaptureBar()
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
        case .captureText: engine.captureText()
        case .library: showLibrary()
        case .captureBar: toggleCaptureBar()
        }
    }

    @objc private func stopVideo() {
        let video = ScreenRecorder.shared
        if video.phase == .recording || video.phase == .paused { video.stop() } else { video.cancel() }
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
        if menu === captureMenuList { return fillCaptureMenu(menu) }
        menu.removeAllItems()
        let prefs = Preferences.shared

        if !ScreenAccess.granted {
            let warn = item("Allow Screen Recording…", #selector(allowScreenRecording))
            warn.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        if FolderSync.shared.needsFolder && SettingsSync.shared.isReady {
            let choose = item("Choose Sync Folder…", #selector(chooseSyncFolder))
            choose.image = NSImage(systemSymbolName: "folder.badge.questionmark", accessibilityDescription: nil)
            choose.toolTip = "Your library syncs through a folder. Choose where that folder is on this Mac."
            menu.addItem(choose)
            menu.addItem(.separator())
        }

        let video = ScreenRecorder.shared
        if video.isActive {
            let stop = item(video.phase == .ready ? "Cancel Recording" : "Stop Recording", #selector(stopVideo), symbol: "stop.circle")
            menu.addItem(stop)
            menu.addItem(.separator())
        }
        for (index, item) in captureItems().enumerated() {
            // The first preset is the main capture (the library's Capture button uses it too).
            if index == 0, let symbol = prefs.presets.first?.mode.symbol { feature(item, symbol) }
            menu.addItem(item)
        }
        let again = item("Capture Same Area Again", #selector(captureAgain), hotKey: prefs.captureAgainHotKey)
        again.isEnabled = engine.lastRegion != nil
        menu.addItem(again)
        menu.addItem(feature(item("Capture Text", #selector(captureText), hotKey: prefs.captureTextHotKey), "text.viewfinder"))

        let recorder = StepRecorder.shared
        menu.addItem(item(recorder.isRecording ? "Stop Recording Steps" : "Record Steps…", #selector(toggleSteps),
                          symbol: recorder.isRecording ? "stop.circle" : "record.circle"))
        let bar = toggle("Show Capture Bar", prefs.showCaptureBar, #selector(toggleCaptureBar))
        if let shortcut = prefs.captureBarHotKey?.menuKeyEquivalent {
            bar.keyEquivalent = shortcut.key
            bar.keyEquivalentModifierMask = shortcut.mask
        }
        menu.addItem(feature(bar, "rectangle.split.3x1"))

        menu.addItem(.separator())
        menu.addItem(feature(item("Open Library…", #selector(showLibrary), hotKey: prefs.libraryHotKey), "photo.on.rectangle"))
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
        menu.addItem(item("Import from Snagit…", #selector(importFromSnagit)))
        menu.addItem(toggle("Copy Captures to Clipboard", prefs.copyToClipboard, #selector(toggleClipboard)))
        menu.addItem(toggle("Open Captures in Library", prefs.afterCapture.opensLibrary, #selector(toggleOpenInLibrary)))

        menu.addItem(.separator())
        let helpEntry = NSMenuItem(title: "SnagAnything Help", action: #selector(showHelp), keyEquivalent: "")
        helpEntry.target = self
        helpEntry.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        menu.addItem(helpEntry)
        menu.addItem(feature(item("Settings…", #selector(showSettings), key: ","), "gearshape"))
        #if !APPSTORE
        if let staged = AutoUpdater.shared.staged {
            menu.addItem(feature(item("Update to \(staged.version) Now (Otherwise Installs When Idle)", #selector(installUpdateNow)), "arrow.down.circle"))
        } else if let pending = UpdateAvailability.shared.pending {
            menu.addItem(feature(item("Update to \(pending)…", #selector(checkForUpdates)), "arrow.down.circle"))
        } else {
            menu.addItem(feature(item("Check for Updates…", #selector(checkForUpdates)), "arrow.down.circle"))
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

    private func item(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags? = nil,
                      hotKey: HotKey? = nil, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let modifiers { item.keyEquivalentModifierMask = modifiers }
        if let shortcut = hotKey?.menuKeyEquivalent {
            item.keyEquivalent = shortcut.key
            item.keyEquivalentModifierMask = shortcut.mask
        }
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    /// Marks one of the menu's most-used items with an icon. macOS 27 draws no item images in
    /// menus, so the icon goes in the title, in a slot of fixed width so the titles line up. It
    /// is a template, so it turns white with the text when the item is highlighted.
    @discardableResult
    private func feature(_ item: NSMenuItem, _ symbol: String) -> NSMenuItem {
        let font = NSFont.menuFont(ofSize: 0)
        guard let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular)) else { return item }
        let slot = NSSize(width: (font.pointSize * 1.5).rounded(), height: symbolImage.size.height)
        let icon = NSImage(size: slot, flipped: false) { rect in
            let size = symbolImage.size
            symbolImage.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            return true
        }
        icon.isTemplate = true
        let attachment = NSTextAttachment()
        attachment.image = icon
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - slot.height) / 2, width: slot.width, height: slot.height)
        let title = NSMutableAttributedString(attachment: attachment)
        title.append(NSAttributedString(string: " " + item.title))
        title.addAttribute(.font, value: font, range: NSRange(location: 0, length: title.length))
        item.attributedTitle = title
        // An image as well would show twice if menus draw images again.
        item.image = nil
        return item
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let item = item(title, action)
        item.state = on ? .on : .off
        return item
    }

    /// File: bringing pictures in, and saving or sharing the selected capture.
    private func fileMenu() -> NSMenuItem {
        let file = NSMenu(title: "File")
        file.addItem(item("Import Pictures…", #selector(importPictures), key: "I"))
        file.addItem(item("Import from Snagit…", #selector(importFromSnagit)))
        file.addItem(.separator())
        file.addItem(item("Open in Its Own Window", #selector(openInOwnWindow), key: "o", modifiers: [.command, .option]))
        file.addItem(.separator())
        file.addItem(item("Save As…", #selector(saveSelected), key: "S"))
        file.addItem(item("Share…", #selector(shareSelected)))
        file.addItem(item("Export…", #selector(exportSelected)))
        file.addItem(item("Make a Guide…", #selector(guideFromSelected)))
        let item = NSMenuItem()
        item.submenu = file
        return item
    }

    /// View: what the library window shows, and how big.
    private func viewMenu() -> NSMenuItem {
        let view = NSMenu(title: "View")
        view.addItem(item("Show Markup Tools", #selector(toggleMarkup), key: "A"))
        view.addItem(.separator())
        view.addItem(item("Picture Full Width", #selector(toggleCaptures), key: "1", modifiers: [.command, .option]))
        view.addItem(item("Hide Picture", #selector(togglePicture), key: "2", modifiers: [.command, .option]))
        view.addItem(item("Hide Details", #selector(toggleDetails), key: "i", modifiers: [.command, .control]))
        view.addItem(item("Show Sidebar as Icons", #selector(toggleSidebar), key: "s", modifiers: [.command, .control]))
        view.addItem(.separator())
        // ⌘+, ⌘− and ⌘0 zoom the picture when it's what you're working on, and size the
        // thumbnails when the grid is; the titles say which.
        view.addItem(item("Zoom In", #selector(zoomIn), key: "+"))
        view.addItem(item("Zoom Out", #selector(zoomOut), key: "-"))
        view.addItem(item("Zoom to Fit", #selector(zoomPictureToFit), key: "0"))
        view.addItem(.separator())
        view.addItem(item("Show Capture Bar", #selector(toggleCaptureBar)))
        view.addItem(item("Show Preset Buttons", #selector(togglePresetButtons)))
        let toolbar = NSMenuItem(title: "Hide Toolbar", action: #selector(NSWindow.toggleToolbarShown(_:)), keyEquivalent: "t")
        toolbar.keyEquivalentModifierMask = [.command, .option]
        view.addItem(toolbar)
        let item = NSMenuItem()
        item.submenu = view
        return item
    }

    /// Capture: every preset and the other ways to capture, with their shortcuts. Filled as
    /// it opens, so it follows Settings › Presets.
    private let captureMenuList = NSMenu(title: "Capture")

    private func captureMenu() -> NSMenuItem {
        captureMenuList.delegate = self
        let item = NSMenuItem()
        item.submenu = captureMenuList
        return item
    }

    private func fillCaptureMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let prefs = Preferences.shared
        for item in captureItems() { menu.addItem(item) }
        menu.addItem(.separator())
        menu.addItem(item("Capture Text", #selector(captureText), hotKey: prefs.captureTextHotKey))
        let again = item("Capture Same Area Again", #selector(captureAgain), hotKey: prefs.captureAgainHotKey)
        again.isEnabled = engine.lastRegion != nil
        menu.addItem(again)
        let recorder = StepRecorder.shared
        menu.addItem(item(recorder.isRecording ? "Stop Recording Steps" : "Record Steps…", #selector(toggleSteps)))
    }

    /// Ticks and names the switches, and turns off what doesn't apply now, as menus should.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let state = LibraryWindow.shared.state
        let inFront = LibraryCommands.libraryInFront
        let selected = state.selectedItems
        switch menuItem.action {
        case #selector(toggleCaptureBar):
            menuItem.state = Preferences.shared.showCaptureBar ? .on : .off
        case #selector(togglePresetButtons):
            menuItem.state = state.showPresetButtons ? .on : .off
        case #selector(toggleMarkup):
            menuItem.title = AnnotationEditor.shared.showResult ? "Show Markup Tools" : "Hide Markup Tools"
            return inFront && selected.count == 1 && selected.first?.kind != .video
        case #selector(toggleCaptures):
            // Ticked while the picture fills the window; choosing it again goes back.
            menuItem.state = state.picturesFirst ? .on : .off
            return inFront && (state.picturesFirst || state.selection.count == 1)
        case #selector(togglePicture):
            menuItem.title = state.pictureHidden ? "Show Picture" : "Hide Picture"
            return inFront
        case #selector(toggleDetails):
            menuItem.title = state.showInfo ? "Hide Details" : "Show Details"
            return inFront
        case #selector(toggleSidebar):
            menuItem.title = LibrarySidebar.isCompact ? "Show Full Sidebar" : "Show Sidebar as Icons"
            return LibraryWindow.shared.isKey
        case #selector(zoomIn), #selector(zoomOut):
            let picture = LibraryCommands.zoomsPicture
            let bigger = menuItem.action == #selector(zoomIn)
            menuItem.title = picture ? (bigger ? "Zoom In" : "Zoom Out") : (bigger ? "Bigger Thumbnails" : "Smaller Thumbnails")
            return inFront && (picture || state.gridVisible)
        case #selector(zoomPictureToFit):
            return inFront && LibraryCommands.zoomsPicture
        case #selector(findInLibrary):
            return LibraryWindow.shared.isKey
        case #selector(saveSelected), #selector(openInOwnWindow):
            return inFront && selected.count == 1
        case #selector(shareSelected):
            return inFront && !selected.isEmpty
        case #selector(exportSelected), #selector(guideFromSelected):
            return inFront && selected.count > 1
        case #selector(deleteSelected):
            // ⌘⌫ deletes to the start of the line while typing.
            return inFront && !selected.isEmpty && !(NSApp.keyWindow?.firstResponder is NSText)
        default: break
        }
        return true
    }

    /// Edit: Undo and the clipboard for text fields and the selected captures, and deleting them.
    private func editMenu() -> NSMenuItem {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        find.addItem(item("Find…", #selector(findInLibrary), key: "f"))
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = find
        edit.addItem(findItem)
        edit.addItem(.separator())
        let delete = item("Delete…", #selector(deleteSelected), key: "\u{8}")
        edit.addItem(delete)
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
    @objc func captureText() { engine.captureText() }
    @objc func toggleSteps() {
        if StepRecorder.shared.isRecording { StepRecorder.shared.stop(makeGuide: true) } else { StepRecorder.shared.start() }
    }
    @objc func showLibrary() { LibraryWindow.shared.show() }
    @objc func toggleMarkup() { AnnotationEditor.shared.showResult.toggle() }
    @objc func toggleCaptures() { LibraryWindow.shared.state.toggleFullWidth() }
    @objc func togglePicture() {
        let state = LibraryWindow.shared.state
        state.setPictureHidden(!state.pictureHidden)
    }
    @objc func toggleDetails() { LibraryWindow.shared.state.showInfo.toggle() }
    @objc func togglePresetButtons() { LibraryWindow.shared.state.showPresetButtons.toggle() }
    @objc func zoomIn() {
        if LibraryCommands.zoomsPicture { CanvasZoom.shared.step(in: true) } else { LibraryWindow.shared.state.stepThumbnails(bigger: true) }
    }
    @objc func zoomOut() {
        if LibraryCommands.zoomsPicture { CanvasZoom.shared.step(in: false) } else { LibraryWindow.shared.state.stepThumbnails(bigger: false) }
    }
    @objc func zoomPictureToFit() { CanvasZoom.shared.fitRequested += 1 }
    @objc func toggleSidebar() { LibrarySidebar.toggleCompact(in: LibraryWindow.shared.window) }
    /// Edit › Find: into the library's search field.
    @objc func findInLibrary() {
        let search = LibraryWindow.shared.window?.toolbar?.items.lazy.compactMap { $0 as? NSSearchToolbarItem }.first
        search?.beginSearchInteraction()
    }
    @objc func openInOwnWindow() { EditorWindow.shared.open() }
    @objc func saveSelected() { LibraryCommands.single.map(Exporter.save) }
    @objc func shareSelected() { ShareButton.shareAtPointer(LibraryWindow.shared.state.selectedItems) }
    @objc func exportSelected() {
        let state = LibraryWindow.shared.state
        state.export = ExportRequest(items: state.selectedItems.map(\.id))
    }
    @objc func guideFromSelected() {
        let state = LibraryWindow.shared.state
        state.makeGuide(from: state.selectedItems)
    }
    @objc func deleteSelected() {
        let state = LibraryWindow.shared.state
        state.confirmDelete = state.selection
    }
    @objc func toggleCaptureBar() { CaptureBar.shared.toggle() }
    @objc func copyRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let entry = LibraryStore.shared.entry(id),
              let png = Flattener.png(entry) else { return }
        Clipboard.copy(png: png)
        ActivityStore.shared.record(ActivityKey.copies)
        Notice.shared.show("Copied “\(entry.name)”", symbol: "doc.on.doc")
    }
    @objc func openRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        LibraryWindow.shared.show(select: id)
    }
    @objc func importFromSnagit() {
        SnagitImportWindow.shared.show()
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
        // Keeps the preview as it was: on with the preview, the preview stays too.
        switch prefs.afterCapture {
        case .preview: prefs.afterCapture = .previewAndLibrary
        case .previewAndLibrary, .openLibrary: prefs.afterCapture = .preview
        case .nothing: prefs.afterCapture = .openLibrary
        }
    }
    @objc func allowScreenRecording() {
        if !ScreenAccess.request() { ScreenAccess.openSettings() }
    }
    @objc func showSettings() { SettingsWindow.shared.show() }
    @objc func chooseSyncFolder() { SettingsWindow.shared.show(tab: "General") }
    @objc func showHelp() { HelpWindow.shared.show() }
    @objc func checkForUpdates() { UpdateController.checkForUpdates() }
    @objc func installUpdateNow() { AutoUpdater.shared.installNow() }
    @objc func quit() { NSApp.terminate(nil) }

    /// The developer's site, which lists every app.
    @objc func showOtherApps() {
        if let url = URL(string: "https://stevemanke.com/") { NSWorkspace.shared.open(url) }
    }
    @objc func showAbout() {
        AppInfo.showAbout()
    }
}
