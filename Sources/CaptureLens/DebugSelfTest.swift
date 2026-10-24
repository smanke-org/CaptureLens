#if DEBUG
import AppKit
import CaptureLensKit
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

            let window = LibraryWindow.shared
            window.show(select: store.items.last?.id)
            try? await Task.sleep(for: .seconds(2))
            render(window.window, to: out.appending(path: "library.png"))
            window.state.filter.tags = ["work"]
            window.state.selection = Set(store.items.prefix(2).map(\.id))
            try? await Task.sleep(for: .seconds(1))
            render(window.window, to: out.appending(path: "library-filtered.png"))
            window.state.filter = LibraryFilter()

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
