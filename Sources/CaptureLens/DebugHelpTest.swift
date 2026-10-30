#if DEBUG
import AppKit

/// `CAPTURELENS_DEBUG_HELP_TEST=<png path>` (trace to `CAPTURELENS_DEBUG_TRACE`): presses Help on
/// every Settings tab, notes the topic it opened, checks the menus and shortcut tokens,
/// renders Help and Settings to PNGs, then quits.
@MainActor
enum DebugHelpTest {
    static func run(snapshot: String, delegate: NSMenuDelegate) {
        let tracePath = ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_TRACE"]
        var lines: [String] = []
        func trace(_ s: String) {
            lines.append(s)
            if let tracePath { try? lines.joined(separator: "\n").appending("\n").write(toFile: tracePath, atomically: true, encoding: .utf8) }
        }
        trace("started")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                if ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_HELP_SKIP_SETTINGS"] != nil {
                    // Opening Settings needs sync running, which a test run never starts, so
                    // press each tab's button code directly instead of finding it on screen.
                    for tab in Help.testTabs {
                        HelpButton(topic: Help.topic(forSettingsTab: tab)).makeCoordinator().open()
                        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                        trace("tab \(tab): opened=\(HelpWindow.shared.state.selection ?? "-") visible=\(HelpWindow.shared.window?.isVisible == true)")
                    }
                } else {
                trace("opening Settings")
                func helpButton(_ view: NSView) -> NSButton? {
                    if let b = view as? NSButton, b.bezelStyle == .helpButton, !b.isHiddenOrHasHiddenAncestor { return b }
                    for sub in view.subviews { if let hit = helpButton(sub) { return hit } }
                    return nil
                }
                SettingsWindow.shared.show()
                let tabs = SettingsWindow.shared.debugWindow?.contentViewController as? NSTabViewController
                for (index, item) in (tabs?.tabViewItems ?? []).enumerated() {
                    tabs?.selectedTabViewItemIndex = index
                    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                    // Only inside this tab's own view: other tabs' views can linger in the window.
                    let button = item.viewController?.view.superview == nil ? nil : item.viewController.flatMap { helpButton($0.view) }
                    button?.performClick(nil)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                    trace("tab \(item.label): button=\(button != nil) opened=\(HelpWindow.shared.state.selection ?? "-") visible=\(HelpWindow.shared.window?.isVisible == true)")
                }
                }
                let unresolved = Help.topics.filter { $0.blocks.contains { $0.searchText.contains("{") } }.map(\.id)
                trace("topics=\(Help.topics.count) unresolved=\(unresolved) tokens=\(Help.debugTokens)")
                let menu = NSMenu()
                delegate.menuNeedsUpdate?(menu)
                trace("menu: \(menu.items.map(\.title).filter { !$0.isEmpty })")
                trace("help menu: \(NSApp.helpMenu?.items.map { $0.title + " " + $0.keyEquivalent } ?? [])")
                HelpWindow.shared.show(topic: ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_HELP_TOPIC"] ?? "getting-started")
                RunLoop.main.run(until: Date().addingTimeInterval(1))
                for (window, path) in [(HelpWindow.shared.window, snapshot), (SettingsWindow.shared.debugWindow, snapshot + ".settings.png")] {
                    if let view = window?.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                }
                trace("done")
                QuitConfirmation.quitNow()
            }
        }
    }
}
#endif
