import AppKit

/// Where the app shows itself: a Dock icon, a menu bar icon, both, or neither.
///
/// CaptureLens is a menu bar app, so the menu bar icon is on and the Dock icon off
/// by default. Right-clicking the Dock icon offers the settings window (macOS only
/// shows an app's own Dock-menu items while it is running with a Dock icon). With
/// both off the app runs with no icon at all; opening it again from Applications
/// or Spotlight brings up its settings.
@MainActor
enum AppPresence {
    /// Posted when `showInMenuBar` changes, for the status item to follow.
    static let menuBarDidChange = Notification.Name("AppPresence.menuBarDidChange")

    private enum Key {
        static let dock = "showInDock"
        static let menuBar = "showInMenuBar"
    }

    static var showInDock: Bool {
        get { AppDefaults.store.bool(forKey: Key.dock) }
        set {
            guard newValue != showInDock || AppDefaults.store.object(forKey: Key.dock) == nil else { return }
            AppDefaults.store.set(newValue, forKey: Key.dock)
            SettingsSync.shared.localDidChange()
        }
    }

    static var showInMenuBar: Bool {
        get { AppDefaults.store.object(forKey: Key.menuBar) as? Bool ?? true }
        set {
            guard newValue != showInMenuBar || AppDefaults.store.object(forKey: Key.menuBar) == nil else { return }
            AppDefaults.store.set(newValue, forKey: Key.menuBar)
            NotificationCenter.default.post(name: menuBarDidChange, object: nil)
            SettingsSync.shared.localDidChange()
        }
    }

    /// Shown under the two checkboxes while both are off.
    static func hiddenEverywhereNote(appName: String, settingsName: String) -> String {
        "\(appName) will keep running with no icon. To get back here, open it again from Applications or Spotlight; that opens \(settingsName)."
    }

    /// Sets the activation policy to match `showInDock`. `keepInFront` is a
    /// window to keep visible when the Dock icon goes away (the settings window
    /// the change was made from), since leaving the Dock deactivates the app.
    static func applyDock(keepInFront window: NSWindow? = nil) {
        if showInDock {
            NSApp.setActivationPolicy(.regular)
        } else {
            // Going back to .accessory while the app is active doesn't take if
            // done synchronously; a runloop turn later it does.
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.accessory)
                guard let window, window.isVisible else { return }
                // macOS refuses a plain activate once the app has left the Dock.
                window.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
                window.makeKey()
            }
        }
    }

    /// The Dock icon's right-click menu: one item that opens the settings window.
    static func dockMenu(title: String, target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        menu.addItem(item)
        return menu
    }

    /// A standard app menu for while the app has a Dock icon (and so a menu
    /// bar of its own): About, settings on ⌘,, Hide and Quit.
    static func mainMenu(appName: String, settingsTitle: String, target: AnyObject, settings: Selector) -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        // Through the app delegate's showAbout, so the panel carries the beta label.
        appMenu.addItem(withTitle: "About \(appName)", action: NSSelectorFromString("showAbout"), keyEquivalent: "")
        appMenu.addItem(.separator())
        let prefs = NSMenuItem(title: settingsTitle, action: settings, keyEquivalent: ",")
        prefs.target = target
        appMenu.addItem(prefs)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        return main
    }
}
