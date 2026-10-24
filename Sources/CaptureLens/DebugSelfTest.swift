#if DEBUG
import AppKit
import CaptureLensKit
import CryptoKit
import SwiftUI

/// `CAPTURELENS_DEBUG_SNAPSHOT=<folder>` (with `CAPTURELENS_DEFAULTS_SUITE` and
/// `CAPTURELENS_LIBRARY_FOLDER`, so nothing real is touched): adds sample captures, waits
/// for their text and names, checks search and encryption at rest, renders the library and
/// every Settings pane to PNGs in the folder, writes report.txt there, then quits.
@MainActor
enum DebugSelfTest {
    static func run(folder: String) {
        let env = ProcessInfo.processInfo.environment
        guard env["CAPTURELENS_DEFAULTS_SUITE"] != nil, env["CAPTURELENS_LIBRARY_FOLDER"] != nil else {
            NSLog("CaptureLens: the self-test needs CAPTURELENS_DEFAULTS_SUITE and CAPTURELENS_LIBRARY_FOLDER")
            exit(2)
        }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report: [String] = []
        func note(_ line: String) {
            report.append(line)
            try? report.joined(separator: "\n").appending("\n").write(to: out.appending(path: "report.txt"), atomically: true, encoding: .utf8)
        }

        Task {
            let store = LibraryStore.shared
            note("autoName available: \(AutoNamer.unavailableReason ?? "yes")")
            note("encrypted: \(store.isEncrypted)")
            let samples: [(String, CaptureItem.Source, [String], String)] = [
                ("Quarterly revenue grew 12%\nNorth region leads sales", .init(appName: "Safari", bundleID: "com.apple.Safari",
                    windowTitle: "Sales Dashboard", url: "https://www.example.com/dashboard", pageTitle: "Sales Dashboard"), ["work"], "For the board deck"),
                ("error: linker command failed\nUndefined symbol: _main", .init(appName: "Xcode", bundleID: "com.apple.dt.Xcode",
                    windowTitle: "SampleApp — Build Failed"), ["bugs", "work"], ""),
                ("Pancake Recipe\n2 cups flour, 1 egg, milk", .init(appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Recipes"), [], ""),
            ]
            for (text, source, tags, notes) in samples {
                guard let image = DebugImage.make(text: text, size: CGSize(width: 900, height: 420)),
                      var item = store.add(image: image, kind: .region, scale: 2, source: source,
                                           cursor: CursorLayer(png: debugCursorPNG(), width: 17, height: 24, x: 120, y: 60, visible: true))
                else { note("add failed"); continue }
                item.tags = tags
                item.notes = notes
                store.update(item)
            }
            note("added \(store.items.count)")
            let start = Date()
            while !store.analyzing.isEmpty && Date().timeIntervalSince(start) < 90 { try? await Task.sleep(for: .milliseconds(300)) }
            note("analysis took \(Int(Date().timeIntervalSince(start))) s")
            for item in store.items {
                note("- \(item.name) | auto=\(item.nameIsAutomatic) | tags=\(item.tags) | text=\(item.recognizedText.replacingOccurrences(of: "\n", with: " / ").prefix(70))")
            }
            for query in ["revenue", "linker", "tag:work", "app:xcode", "site:example", "today", "pancake flour", "nothing-here"] {
                var filter = LibraryFilter()
                filter.text = query
                note("search \(query): \(LibraryQuery.filter(store.items, with: filter).map(\.name))")
            }
            // Nothing readable may be in the file while encrypted.
            if let db = store.db {
                try? db.set(nil as Data?, forKey: "selftest")
                let files = ["Library.sqlite", "Library.sqlite-wal"].compactMap { try? Data(contentsOf: store.folder.appending(path: $0)) }
                let leaks = ["revenue", "linker", "Pancake", "board deck"].filter { word in files.contains { $0.range(of: Data(word.utf8)) != nil } }
                note("plaintext in database files: \(leaks.isEmpty ? "none" : leaks.joined(separator: ", "))")
            }

            settingsSyncRoundTrip(note)
            await updateCheck(note)

            let window = LibraryWindow.shared
            window.show(select: store.items.last?.id)
            try? await Task.sleep(for: .seconds(2))
            render(window.window, to: out.appending(path: "library.png"))
            window.state.filter.tags = ["work"]
            window.state.selection = Set(store.items.prefix(2).map(\.id))
            try? await Task.sleep(for: .seconds(1))
            render(window.window, to: out.appending(path: "library-filtered.png"))
            window.state.filter = LibraryFilter()

            await annotationTest(note, out: out)

            CapturePreview.shared.show(store.items[0], near: NSScreen.main?.frame ?? .zero, copied: true)
            try? await Task.sleep(for: .seconds(1))
            render(NSApp.windows.first { $0 is NSPanel && $0.isVisible && $0.contentView is NSHostingViewProtocol }, to: out.appending(path: "preview.png"))

            SettingsWindow.shared.show()
            if let tabs = SettingsWindow.shared.debugWindow?.contentViewController as? NSTabViewController {
                for (index, item) in tabs.tabViewItems.enumerated() {
                    tabs.selectedTabViewItemIndex = index
                    try? await Task.sleep(for: .milliseconds(700))
                    render(SettingsWindow.shared.debugWindow, to: out.appending(path: "settings-\(item.label).png"))
                }
            }
            HelpWindow.shared.show(topic: "library")
            try? await Task.sleep(for: .seconds(1))
            render(HelpWindow.shared.window, to: out.appending(path: "help.png"))
            note("unresolved help tokens: \(Help.topics.filter { $0.blocks.contains { $0.searchText.contains("{") } }.map(\.id))")
            let menu = NSMenu()
            (NSApp.delegate as? NSMenuDelegate)?.menuNeedsUpdate?(menu)
            note("menu: \(menu.items.map(\.title).filter { !$0.isEmpty })")
            note("done")
            NSApp.terminate(nil)
        }
    }

    /// Every kind of annotation on a sample, then drawing, moving, undoing and typing with
    /// simulated mouse and keys, as a person would in the library.
    private static func annotationTest(_ note: (String) -> Void, out: URL) async {
        let store = LibraryStore.shared
        let window = LibraryWindow.shared
        guard let target = store.items.last else { return note("annotations: no capture") }
        let thumbBefore = store.db?.thumbnail(target.id)
        var item = target
        let red = AnnotationStyle(color: .red, lineWidth: 4)
        item.annotations = [
            Annotation(kind: .spotlight, rect: CGRect(x: 20, y: 20, width: 330, height: 130), style: red),
            Annotation(kind: .rectangle, rect: CGRect(x: 25, y: 30, width: 300, height: 60), style: red),
            Annotation(kind: .arrow, from: CGPoint(x: 420, y: 170), to: CGPoint(x: 330, y: 70), style: AnnotationStyle(color: .blue, lineWidth: 5)),
            Annotation(kind: .callout, rect: CGRect(x: 470, y: 120, width: 240, height: 70), tail: CGPoint(x: 340, y: 60),
                       text: "Revenue is up", style: AnnotationStyle(color: .purple, fontSize: 20)),
            Annotation(kind: .step, rect: CGRect(x: 10, y: 120, width: 34, height: 34), style: AnnotationStyle(color: .orange)),
            Annotation(kind: .step, rect: CGRect(x: 60, y: 120, width: 34, height: 34), style: AnnotationStyle(color: .orange)),
            Annotation(kind: .highlighter, points: [CGPoint(x: 30, y: 70), CGPoint(x: 260, y: 70)], style: AnnotationStyle(color: .yellow, lineWidth: 6, shadow: false)),
            Annotation(kind: .text, rect: CGRect(x: 520, y: 20, width: 300, height: 40), text: "Check the totals", style: AnnotationStyle(color: .green, fontSize: 24)),
            Annotation(kind: .magnify, rect: CGRect(x: 740, y: 230, width: 130, height: 130), zoom: 2.5, style: AnnotationStyle(color: .black, lineWidth: 3)),
            Annotation(kind: .stamp, rect: CGRect(x: 600, y: 330, width: 150, height: 54), stamp: "Approved", style: AnnotationStyle(color: .green)),
            Annotation(kind: .stamp, rect: CGRect(x: 520, y: 330, width: 56, height: 56), stamp: "✅", style: red),
            Annotation(kind: .ellipse, rect: CGRect(x: 300, y: 250, width: 160, height: 90), style: AnnotationStyle(color: .red, lineWidth: 3, filled: true)),
            Annotation(kind: .pen, points: (0..<20).map { CGPoint(x: 100 + Double($0) * 8, y: 300 + sin(Double($0) / 2) * 20) }, style: AnnotationStyle(color: .blue, lineWidth: 3)),
            Annotation(kind: .line, from: CGPoint(x: 100, y: 380), to: CGPoint(x: 300, y: 380), style: AnnotationStyle(color: .black, lineWidth: 2)),
        ]
        store.update(item)
        let thumbAfter = store.db?.thumbnail(target.id)
        note("annotations saved: \(store.entry(target.id)?.annotations.count ?? 0); thumbnail redrawn: \(thumbBefore != thumbAfter)")
        if let png = Flattener.png(store.entry(target.id)!) {
            try? png.write(to: out.appending(path: "flattened.png"))
            note("flattened \(png.count) bytes; original unchanged: \(store.pngData(target.id) != png)")
        }

        window.show(select: target.id)
        window.state.showInspector = true
        try? await Task.sleep(for: .seconds(2))
        AnnotationEditor.shared.select(item.annotations[3].id)
        try? await Task.sleep(for: .seconds(1))
        render(window.window, to: out.appending(path: "annotated.png"))

        // Drive the layer as a person would.
        func find(_ view: NSView?) -> AnnotationLayerView? {
            guard let view else { return nil }
            if let layer = view as? AnnotationLayerView { return layer }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        guard let layer = find(window.window?.contentView), let win = window.window else { return note("annotations: no layer") }
        func send(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) {
            let inWindow = layer.convert(point, to: nil)
            guard let event = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1) else { return }
            switch type {
            case .leftMouseDown: layer.mouseDown(with: event)
            case .leftMouseDragged: layer.mouseDragged(with: event)
            default: layer.mouseUp(with: event)
            }
        }
        let editor = AnnotationEditor.shared
        let undo: UndoManager? = AnnotationEditor.shared.undoManager
        editor.pick(.draw(.rectangle))
        let countBefore = editor.annotations.count
        send(.leftMouseDown, CGPoint(x: 600, y: 230)); send(.leftMouseDragged, CGPoint(x: 650, y: 260)); send(.leftMouseDragged, CGPoint(x: 700, y: 290)); send(.leftMouseUp, CGPoint(x: 700, y: 290))
        let drawn = editor.annotations.last
        note("draw box: \(editor.annotations.count == countBefore + 1 && drawn?.kind == .rectangle) rect=\(drawn.map { "\($0.rect)" } ?? "-")")
        // Each real click is its own event, and its own undo step.
        try? await Task.sleep(for: .milliseconds(300))
        editor.pick(.select)
        note("undo after drawing: level \(undo?.groupingLevel ?? -1), can undo \(undo?.canUndo ?? false) '\(undo?.undoActionName ?? "")'")
        send(.leftMouseDown, CGPoint(x: 600, y: 260)); send(.leftMouseDragged, CGPoint(x: 620, y: 270)); send(.leftMouseUp, CGPoint(x: 620, y: 270))
        let moved = editor.annotations.last
        note("move box by (20, 10): \(moved.map { "\($0.rect.origin)" } ?? "-") selected=\(editor.selection == moved?.id)")
        try? await Task.sleep(for: .milliseconds(300))
        note("before undo: level \(undo?.groupingLevel ?? -1) '\(undo?.undoActionName ?? "")'")
        editor.undo()
        note("undo move: \(editor.annotations.last.map { "\($0.rect.origin)" } ?? "-") (\(undo?.undoActionName ?? ""))")
        try? await Task.sleep(for: .milliseconds(300))
        editor.undo()
        note("undo add: count back to \(editor.annotations.count) (was \(countBefore))")
        editor.redo()
        note("redo add: \(editor.annotations.count == countBefore + 1)")
        editor.undo()
        editor.pick(.draw(.text))
        send(.leftMouseDown, CGPoint(x: 120, y: 200)); send(.leftMouseUp, CGPoint(x: 120, y: 200))
        if let textView = win.firstResponder as? NSTextView {
            textView.insertText("Typed in the library", replacementRange: NSRange(location: NSNotFound, length: 0))
            layer.endTextEditing()
        }
        let typed = editor.annotations.last
        note("type text: \(typed?.kind == .text && typed?.text == "Typed in the library") size=\(typed.map { "\($0.rect.size)" } ?? "-")")
        editor.pick(.select)
        editor.select(typed?.id)
        let keyDelete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber,
                                         context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)
        if let keyDelete { layer.keyDown(with: keyDelete) }
        note("delete key removes it: \(!editor.annotations.contains { $0.id == typed?.id })")
        try? await Task.sleep(for: .milliseconds(500))
    }

    /// Settings that sync survive the trip through a sealed record; per-Mac ones stay out.
    private static func settingsSyncRoundTrip(_ note: (String) -> Void) {
        let prefs = Preferences.shared
        let originalAfter = prefs.afterCapture
        defer { prefs.afterCapture = originalAfter }
        prefs.copyToClipboard = false
        prefs.afterCapture = .openLibrary
        var first = prefs.presets[0]
        first.name = "Synced Preset"
        first.delay = 3
        first.afterCapture = .openLibrary
        prefs.update(first)
        prefs.libraryHotKey = nil
        AppDefaults.store.set(AppAppearance.dark.rawValue, forKey: AppAppearance.key)
        // Set straight in the store, and "off": turning checks on would ask GitHub.
        AppDefaults.store.set(UpdatePolicy.off.rawValue, forKey: UpdatePolicy.key)
        UpdateInterval.current = UpdateInterval(value: 3, unit: .days)
        AppDefaults.store.set(true, forKey: "lock.enabled")
        let key = SymmetricKey(size: .bits256)
        let sent = SettingsSync.shared.debugRoundTrip(using: key) {
            // What another Mac would have before adopting: everything back to the defaults.
            prefs.resetToDefaults()
            AppDefaults.store.set(AppAppearance.system.rawValue, forKey: AppAppearance.key)
            AppDefaults.store.set(UpdatePolicy.ask.rawValue, forKey: UpdatePolicy.key)
            UpdateInterval.current = UpdateInterval(value: 1, unit: .days)
        }
        let checks: [(String, Bool)] = [
            ("clipboard", prefs.copyToClipboard == false), ("after", prefs.afterCapture == .openLibrary),
            ("preset name", prefs.presets[0].name == "Synced Preset"), ("preset delay", prefs.presets[0].delay == 3),
            ("preset after", prefs.presets[0].afterCapture == .openLibrary && prefs.presets[1].afterCapture == nil),
            ("library key", prefs.libraryHotKey == nil), ("appearance", AppAppearance.current == .dark),
            ("policy", AutoUpdater.shared.policy == .off),
            ("interval", AutoUpdater.shared.interval == UpdateInterval(value: 3, unit: .days)),
        ]
        let ok = checks.allSatisfy(\.1)
        if !ok { note("settings that didn't come back: \(checks.filter { !$0.1 }.map(\.0))") }
        let keys = Set(sent?.keys.map { $0 } ?? [])
        note("settings sync round trip: \(ok ? "ok" : "FAILED") (\(keys.count) keys)")
        note("synced keys missing: \(Set(SettingsSync.syncedKeys).subtracting(keys).sorted())")
        note("per-Mac keys leaked: \(["lock.enabled", "library.encrypt", "lock.afterMinutes", "lastRegion", "welcomed"].filter(keys.contains))")
        // Set only to prove it doesn't sync; left on, the library window would open locked.
        AppDefaults.store.removeObject(forKey: "lock.enabled")
    }

    /// Asks GitHub for the latest release (of `CAPTURELENS_UPDATE_REPOSITORY`, if set) and,
    /// if it's newer, downloads and verifies it without installing.
    private static func updateCheck(_ note: (String) -> Void) async {
        // `CAPTURELENS_DEBUG_UPDATE_DMG=<path> <version>`: verify a disk image already on disk
        // instead of asking GitHub, so a network filter's prompt can't get in the way.
        if let spec = ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_UPDATE_DMG"] {
            let parts = spec.split(separator: " ").map(String.init)
            let copy = FileManager.default.temporaryDirectory.appending(path: "selftest-\(UUID().uuidString).dmg")
            do {
                try FileManager.default.copyItem(at: URL(fileURLWithPath: parts[0]), to: copy)
                let app = try UpdateController.stage(copy)
                note("update staged: \(app.lastPathComponent)")
                try UpdateController.verifyCandidate(app, version: parts.count > 1 ? parts[1] : "9.9.9")
                note("update verified")
            } catch {
                note("update refused: \(error.localizedDescription)")
            }
            return
        }
        guard ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_UPDATE_NETWORK"] != nil else {
            note("update check: skipped (set CAPTURELENS_DEBUG_UPDATE_NETWORK to ask GitHub)")
            return
        }
        do {
            guard let release = try await UpdateController.fetchLatestRelease() else {
                note("update check: no releases yet (up to date)")
                return
            }
            let newer = UpdateController.isNewer(release.version, than: AppInfo.version)
            note("update check: latest \(release.version), newer: \(newer)")
            guard newer else { return }
            let app = try await UpdateController.downloadAndStage(release)
            note("update staged: \(app.lastPathComponent)")
            do {
                try UpdateController.verifyCandidate(app, version: release.version)
                note("update verified")
            } catch {
                note("update refused: \(error.localizedDescription)")
            }
        } catch {
            note("update check error: \(error.localizedDescription)")
        }
    }

    private static func render(_ window: NSWindow?, to url: URL) {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func debugCursorPNG() -> Data {
        let image = NSCursor.arrow.image
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return Data() }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}

private protocol NSHostingViewProtocol {}
extension NSHostingView: NSHostingViewProtocol {}
#endif
