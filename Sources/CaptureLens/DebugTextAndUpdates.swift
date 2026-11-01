#if DEBUG
import AppKit

/// Debug builds only. `CAPTURELENS_DEBUG_TEXT_UPDATES=<folder>` (with `CAPTURELENS_DEFAULTS_SUITE`
/// and `CAPTURELENS_LIBRARY_FOLDER`, so nothing real is touched): runs Capture Text on a
/// rendered picture, checks the clipboard and the library (putting the clipboard back after),
/// then draws the library, the update prompt and the What's New sheet to PNGs, writes
/// report.txt, and quits.
@MainActor
enum DebugTextAndUpdates {
    static func run(folder: String) {
        let env = ProcessInfo.processInfo.environment
        guard env["CAPTURELENS_DEFAULTS_SUITE"] != nil, env["CAPTURELENS_LIBRARY_FOLDER"] != nil else {
            NSLog("SnagAnything: this test needs CAPTURELENS_DEFAULTS_SUITE and CAPTURELENS_LIBRARY_FOLDER")
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
            // Capture Text, without the overlay: the picked picture goes straight in.
            let saved = NSPasteboard.general.string(forType: .string)
            guard let image = DebugImage.make(text: "Quarterly totals rose 12% over the last year\nNorth region leads sales",
                                              size: CGSize(width: 900, height: 300)) else { return note("no image") }
            await CaptureEngine.shared.deliverText(from: image, frame: CGRect(x: 100, y: 100, width: 450, height: 150),
                                                   display: nil, windows: [])
            let copied = NSPasteboard.general.string(forType: .string) ?? ""
            note("clipboard: \(copied.replacingOccurrences(of: "\n", with: " / "))")
            if let saved { Clipboard.copy(text: saved) } else { NSPasteboard.general.clearContents() }
            note("clipboard restored: \(NSPasteboard.general.string(forType: .string) == saved)")
            let item = LibraryStore.shared.items.first
            note("library kind: \(item?.kind.rawValue ?? "none") text matches: \(item?.recognizedText == copied)")
            // A blank picture finds nothing and saves nothing.
            let before = LibraryStore.shared.items.count
            if let blank = DebugImage.make(text: " ") {
                await CaptureEngine.shared.deliverText(from: blank, frame: .zero, display: nil, windows: [])
            }
            note("blank adds nothing: \(LibraryStore.shared.items.count == before)")
            // A couple of ordinary captures beside it, for the picture.
            for text in ["Build failed: linker error", "Pancake recipe"] {
                if let picture = DebugImage.make(text: text) {
                    LibraryStore.shared.add(image: picture, kind: .region, scale: 2, source: .init(), cursor: nil)
                }
            }
            try? await Task.sleep(for: .seconds(3))

            LibraryWindow.shared.show()
            try? await Task.sleep(for: .seconds(2))
            render(NSApp.windows.first { $0.title == AppInfo.name && $0.isVisible }, to: out.appending(path: "library.png"))

            // The update prompt, as it would look offering the latest CaptureLens release.
            let notes = await ReleaseNotes.fetch(newAfter: "1.0.26", through: "1.0.29")
            note("notes fetched: \(notes.map { $0.version + ($0.isNew ? " new" : "") })")
            let alert = UpdateController.makeConfirmAlert(newVersion: "1.0.29", current: "1.0.26", notes: notes)
            alert.layout()
            alert.window.orderFront(nil)
            try? await Task.sleep(for: .seconds(1))
            render(alert.window, to: out.appending(path: "update-prompt.png"))
            note("reminder box on by default: \(alert.suppressionButton?.state == .on)")
            alert.window.orderOut(nil)

            // What's New in Settings after an automatic update from 1.0.28.
            WhatsNew.shared.noteLaunch(newInstall: false, autoInstalledFrom: "1.0.28")
            note("what's new pending: \(String(describing: WhatsNew.shared.pending))")
            SettingsWindow.shared.show()
            try? await Task.sleep(for: .seconds(4))
            render(SettingsWindow.shared.debugWindow?.attachedSheet, to: out.appending(path: "whats-new.png"))
            note("sheet shown: \(SettingsWindow.shared.debugWindow?.attachedSheet != nil)")
            note("done")
            exit(0)
        }
    }

    private static func render(_ window: NSWindow?, to url: URL) {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
