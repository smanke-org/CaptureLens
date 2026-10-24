#if DEBUG
import AppKit
@preconcurrency import AVFoundation
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
            // `CAPTURELENS_DEBUG_WINDOW_WIDTH` renders the library at that width (narrow layouts).
            if let width = ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_WINDOW_WIDTH"].flatMap(Double.init),
               let win = window.window {
                win.setFrame(CGRect(x: 100, y: 100, width: width, height: 820), display: true)
            }
            try? await Task.sleep(for: .seconds(2))
            render(window.window, to: out.appending(path: "library.png"))
            window.state.filter.tags = ["work"]
            window.state.selection = Set(store.items.prefix(2).map(\.id))
            try? await Task.sleep(for: .seconds(1))
            render(window.window, to: out.appending(path: "library-filtered.png"))
            window.state.filter = LibraryFilter()

            await annotationTest(note, out: out)
            await adjustTest(note, out: out)
            await phase3Test(note, out: out)
            await phase4Test(note, out: out)
            await phase5Test(note, out: out)

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
        let zoom = CanvasZoom.shared
        let fitted = zoom.magnification
        zoom.set(2)
        let two = zoom.magnification
        zoom.step(in: true)
        let up = zoom.magnification
        zoom.step(in: false); zoom.step(in: false)
        note("zoom: fitted \(String(format: "%.2f", fitted)), set 2 → \(two), step in → \(up), two steps out → \(zoom.magnification)")
        try? await Task.sleep(for: .milliseconds(400))
        render(window.window, to: out.appending(path: "zoomed.png"))
        func findZoomer(_ view: NSView?) -> ZoomingScrollView? {
            guard let view else { return nil }
            if let hit = view as? ZoomingScrollView { return hit }
            for sub in view.subviews { if let hit = findZoomer(sub) { return hit } }
            return nil
        }
        if let zoomer = findZoomer(window.window?.contentView) {
            func wheel(_ lines: Int32, precise: Bool = false, shift: Bool = false) {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return }
                if shift { cg.flags = .maskShift }
                if let event = NSEvent(cgEvent: cg) { zoomer.scrollWheel(with: event) }
            }
            let start = zoomer.magnification
            wheel(3); let up = zoomer.magnification
            wheel(-3); wheel(-3); let down = zoomer.magnification
            wheel(5, shift: true); let shifted = zoomer.magnification
            wheel(40, precise: true); let pad = zoomer.magnification
            note(String(format: "scroll zoom: start %.2f, wheel up %.2f, wheel down twice %.2f, shift-scroll %.2f (unchanged), trackpad %.2f, slider follows %.2f",
                        start, up, down, shifted, pad, CanvasZoom.shared.magnification))
        } else {
            note("scroll zoom: no zooming scroll view found")
        }

        // Pop the picture out into its own window and back.
        func layer(in view: NSView?) -> AnnotationLayerView? {
            guard let view else { return nil }
            if let hit = view as? AnnotationLayerView { return hit }
            for sub in view.subviews { if let hit = layer(in: sub) { return hit } }
            return nil
        }
        EditorWindow.shared.open()
        try? await Task.sleep(for: .seconds(2))
        let popped = EditorWindow.shared.debugWindow
        let poppedLayer = layer(in: popped?.contentView)
        let libraryLayer = layer(in: window.window?.contentView)
        note("pop out: open \(EditorWindow.shared.isOpen), editor has canvas \(poppedLayer != nil), library has canvas \(libraryLayer != nil), title '\(popped?.title ?? "-")'")
        if let popped { render(popped, to: out.appending(path: "editor-window.png")) }
        render(window.window, to: out.appending(path: "library-popped.png"))
        let before = AnnotationEditor.shared.annotations.count
        if let poppedLayer, let win = popped {
            AnnotationEditor.shared.pick(.draw(.ellipse))
            for (type, p) in [(NSEvent.EventType.leftMouseDown, CGPoint(x: 100, y: 300)), (.leftMouseDragged, CGPoint(x: 180, y: 360)), (.leftMouseUp, CGPoint(x: 180, y: 360))] {
                let event = NSEvent.mouseEvent(with: type, location: poppedLayer.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                                               windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                switch type {
                case .leftMouseDown: poppedLayer.mouseDown(with: event)
                case .leftMouseDragged: poppedLayer.mouseDragged(with: event)
                default: poppedLayer.mouseUp(with: event)
                }
            }
            AnnotationEditor.shared.pick(.select)
        }
        note("draw in the popped-out editor: \(AnnotationEditor.shared.annotations.count == before + 1)")
        EditorWindow.shared.close()
        try? await Task.sleep(for: .seconds(1))
        note("bring back: open \(EditorWindow.shared.isOpen), library has canvas \(layer(in: window.window?.contentView) != nil)")

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

    /// Crop, cut-outs, rotation, border, edges, Smart Redact, background removal and every
    /// export format, on sample captures, plus the crop and cut tools driven by mouse.
    private static func adjustTest(_ note: (String) -> Void, out: URL) async {
        let store = LibraryStore.shared
        let editor = AnnotationEditor.shared
        let window = LibraryWindow.shared
        guard let target = store.items.last else { return }
        window.show(select: target.id)
        try? await Task.sleep(for: .seconds(1))
        editor.open(target.id)
        let size = target.pointSize
        editor.commitEdits(ImageEdits(crop: CGRect(x: 10, y: 10, width: size.width - 20, height: size.height - 20),
                                      cuts: [CutOut(axis: .horizontal, from: 200, to: 240, seam: .torn)],
                                      rotation: 0, outputScale: 1, border: Border(width: 4, color: .blue, cornerRadius: 12, shadow: true),
                                      edges: EdgeEffect(kind: .torn, sides: [.bottom])), action: "Test")
        if let item = store.entry(target.id), let image = Flattener.image(item) {
            let expected = item.edits.outputSize(for: item.pointSize)
            note("result \(image.width)×\(image.height) px for \(Int(expected.width))×\(Int(expected.height)) pt (+ shadow margin)")
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: out.appending(path: "result.png"))
            for format in Exporter.Format.allCases {
                let url = out.appending(path: "export.\(format.type.preferredFilenameExtension ?? format.rawValue)")
                let ok = Exporter.Format.available.contains(format) && Exporter.write(image, of: item, as: format, to: url)
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                note("export \(format.rawValue): \(Exporter.Format.available.contains(format) ? (ok ? "\(bytes) bytes" : "FAILED") : "not available on this Mac")")
            }
        }
        editor.showResult = true
        try? await Task.sleep(for: .seconds(1.5))
        render(window.window, to: out.appending(path: "result-view.png"))
        editor.showResult = false
        try? await Task.sleep(for: .seconds(1))
        render(window.window, to: out.appending(path: "edit-view.png"))

        // The crop and cut tools, by mouse.
        func find(_ view: NSView?) -> AnnotationLayerView? {
            guard let view else { return nil }
            if let layer = view as? AnnotationLayerView { return layer }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        guard let layer = find(window.window?.contentView), let win = window.window else { return note("adjust: no layer") }
        func send(_ type: NSEvent.EventType, _ point: CGPoint) {
            guard let event = NSEvent.mouseEvent(with: type, location: layer.convert(point, to: nil), modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            switch type {
            case .leftMouseDown: layer.mouseDown(with: event)
            case .leftMouseDragged: layer.mouseDragged(with: event)
            default: layer.mouseUp(with: event)
            }
        }
        editor.commitEdits(.none, action: "Reset")
        editor.pick(.crop)
        send(.leftMouseDown, CGPoint(x: 100, y: 50)); send(.leftMouseDragged, CGPoint(x: 300, y: 150)); send(.leftMouseUp, CGPoint(x: 300, y: 150))
        note("crop by mouse: \(editor.edits.crop.map { "\($0)" } ?? "none")")
        send(.leftMouseDown, CGPoint(x: 300, y: 150)); send(.leftMouseDragged, CGPoint(x: 400, y: 200)); send(.leftMouseUp, CGPoint(x: 400, y: 200))
        note("drag crop corner: \(editor.edits.crop.map { "\($0)" } ?? "none")")
        editor.pick(.cut(.vertical))
        send(.leftMouseDown, CGPoint(x: 150, y: 100)); send(.leftMouseDragged, CGPoint(x: 200, y: 100)); send(.leftMouseUp, CGPoint(x: 200, y: 100))
        note("cut by mouse: \(editor.edits.cuts.map { "\($0.axis.rawValue) \(Int($0.from))–\(Int($0.to)) \($0.seam.rawValue)" })")
        editor.pick(.select)
        // In the strip, away from the sample's marks.
        send(.leftMouseDown, CGPoint(x: 175, y: 200)); send(.leftMouseUp, CGPoint(x: 175, y: 200))
        let deleteKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber,
                                         context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)
        if let deleteKey { layer.keyDown(with: deleteKey) }
        note("select cut and Delete: \(editor.edits.cuts.isEmpty)")
        editor.undo()
        note("undo brings it back: \(editor.edits.cuts.count == 1)")
        editor.commitEdits(.none, action: "Reset")

        // Smart Redact on a capture full of things to hide.
        if let image = DebugImage.make(text: "Contact jane.doe@example.com\nCard 4111 1111 1111 1111\nServer 10.0.0.12", size: CGSize(width: 900, height: 300)),
           let item = store.add(image: image, kind: .region, scale: 2, source: .init(appName: "DebugHook"), cursor: nil) {
            editor.open(item.id)
            editor.smartRedact(with: .redact)
            for _ in 0..<40 where editor.redacting || store.entry(item.id)?.annotations.isEmpty == true {
                try? await Task.sleep(for: .milliseconds(250))
            }
            let marks = store.entry(item.id)?.annotations ?? []
            note("smart redact: \(marks.count) boxes \(marks.map { "\(Int($0.rect.minX)),\(Int($0.rect.minY)) \(Int($0.rect.width))×\(Int($0.rect.height))" })")
            if let final = store.entry(item.id), let flat = Flattener.image(final) {
                try? NSBitmapImageRep(cgImage: flat).representation(using: .png, properties: [:])?.write(to: out.appending(path: "redacted.png"))
            }
        }

        // Background removal on a shape on a plain background.
        let subject = NSImage(size: CGSize(width: 600, height: 400), flipped: false) { rect in
            NSColor(white: 0.93, alpha: 1).setFill(); rect.fill()
            NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: CGRect(x: 180, y: 90, width: 240, height: 220)).fill()
            NSColor.systemBlue.setFill(); NSBezierPath(rect: CGRect(x: 260, y: 160, width: 80, height: 80)).fill()
            return true
        }.cgImage(forProposedRect: nil, context: nil, hints: nil)
        if let subject, var item = store.add(image: subject, kind: .region, scale: 2, source: .init(appName: "DebugHook"), cursor: nil) {
            item.edits.removeBackground = true
            store.update(item)
            if let flat = Flattener.image(store.entry(item.id)!) {
                let corner = Self.alpha(flat, x: 5, y: 5), middle = Self.alpha(flat, x: flat.width / 2, y: flat.height / 2)
                note("remove background: corner alpha \(corner), middle alpha \(middle)")
                try? NSBitmapImageRep(cgImage: flat).representation(using: .png, properties: [:])?.write(to: out.appending(path: "no-background.png"))
            }
        }
    }

    /// A made-up recording: saving, sealing, trimming and cutting, exporting, the video view.
    private static func phase5Test(_ note: (String) -> Void, out: URL) async {
        let store = LibraryStore.shared
        let window = LibraryWindow.shared
        let folder = FileManager.default.temporaryDirectory.appending(path: "CaptureLens Self-Test \(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Two 2-second pieces, as a recording paused once would leave.
        let first = folder.appending(path: "a.mp4"), second = folder.appending(path: "b.mp4")
        guard await DebugMovie.write(to: first, seconds: 2, startFrame: 0), await DebugMovie.write(to: second, seconds: 2, startFrame: 60) else {
            return note("video: couldn't make the test movie")
        }
        guard let joined = try? await ScreenRecorder.join([first, second], into: folder.appending(path: "joined.mp4")) else {
            return note("video: couldn't join the pieces")
        }
        let asset = AVURLAsset(url: joined)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        note("video join: \(String(format: "%.2f", duration)) s from two 2 s pieces")
        guard let poster = await VideoStore.frame(of: asset, at: 0.5),
              let item = store.addVideo(movie: joined, poster: poster, scale: 2, info: VideoInfo(duration: duration),
                                        source: .init(appName: "DebugHook", windowTitle: "Demo Recording")) else {
            return note("video: couldn't save to the library")
        }
        let stored = VideoStore.shared.storedFile(item.id)
        note("video stored: \(stored != nil), sealed \(stored?.sealed == true) (library encrypted \(store.isEncrypted))")
        let playable = await VideoStore.shared.playableURL(item.id)
        let playDuration = playable.map { _ in duration } ?? 0
        note("video plays: \(playable != nil) \(String(format: "%.2f", playDuration)) s")

        // Trim half a second off the start and cut a second from the middle: 2.5 s left.
        var edited = store.entry(item.id)!
        edited.video?.edits = VideoEdits(trimStart: 0.5, cuts: [TimeCut(start: 1.5, end: 2.5)])
        store.update(edited)
        if let playable, let info = store.entry(item.id)?.video {
            let mp4 = folder.appending(path: "out.mp4"), gif = folder.appending(path: "out.gif")
            do {
                try await VideoExport.writeMP4(source: playable, info: info, to: mp4)
                let length = try await AVURLAsset(url: mp4).load(.duration).seconds
                note("video export mp4: \(String(format: "%.2f", length)) s (expected \(String(format: "%.2f", info.resultDuration)))")
            } catch { note("video export mp4 FAILED: \(error.localizedDescription)") }
            do {
                try await VideoExport.writeGIF(source: playable, info: info, to: gif, maxWidth: 320, fps: 8)
                let frames = CGImageSourceCreateWithURL(gif as CFURL, nil).map(CGImageSourceGetCount) ?? 0
                note("video export gif: \(frames) frames")
            } catch { note("video export gif FAILED: \(error.localizedDescription)") }
        }
        let batch = folder.appending(path: "batch")
        try? FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        let written = BatchExportSheet.export([item.id], format: .png, size: 1, frame: .asIs, naming: .name, to: batch)
        note("video batch export: \(written) written \((try? FileManager.default.contentsOfDirectory(atPath: batch.path)) ?? [])")

        window.show(select: item.id)
        AnnotationEditor.shared.showResult = false
        try? await Task.sleep(for: .seconds(3))
        render(window.window, to: out.appending(path: "video-view.png"))
        AnnotationEditor.shared.showResult = true
        try? await Task.sleep(for: .seconds(1.5))
        render(window.window, to: out.appending(path: "video-result.png"))
        AnnotationEditor.shared.showResult = false
        AnnotationEditor.shared.commitVideo(VideoEdits(), action: "Reset")
        AnnotationEditor.shared.undo()
        note("video undo: \(store.entry(item.id)?.video?.edits.cuts.count == 1)")

        // Keys shown while recording: shortcuts and special keys, never typing.
        func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) -> String? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
                .flatMap(RecordingOverlay.describe)
        }
        note("keys shown: ⌘⇧4 → \(key("4", 21, [.command, .shift]) ?? "nil"), a → \(key("a", 0, []) ?? "nil"), Return → \(key("\r", 36, []) ?? "nil"), ⌥← → \(key("", 123, [.option]) ?? "nil")")

        // A real recording, of nothing but this test's own window on top of everything, with no
        // sound: only when this copy already may record the screen (no prompt).
        if CGPreflightScreenCaptureAccess(), let screen = NSScreen.main {
            Preferences.shared.recordSystemAudio = false
            Preferences.shared.recordMicrophone = false
            Preferences.shared.recordCamera = false
            let frame = CGRect(x: screen.frame.midX - 240, y: screen.frame.midY - 135, width: 480, height: 270)
            let test = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            test.level = .screenSaver
            test.isOpaque = true
            test.backgroundColor = .systemTeal
            test.collectionBehavior = [.canJoinAllSpaces, .stationary]
            let label = NSTextField(labelWithString: "CaptureLens recording test")
            label.font = .systemFont(ofSize: 28, weight: .bold)
            label.frame = CGRect(x: 30, y: 110, width: 420, height: 40)
            test.contentView?.addSubview(label)
            test.orderFrontRegardless()
            var tick = 0
            let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                tick += 1
                MainActor.assumeIsolated { test.backgroundColor = tick % 2 == 0 ? .systemTeal : .systemOrange }
            }
            ScreenRecorder.shared.debugKeepWindow = test.windowNumber
            let before = Set(store.items.map(\.id))
            let started = await ScreenRecorder.shared.debugRecord(frame: frame, seconds: 2)
            timer.invalidate()
            test.orderOut(nil)
            ScreenRecorder.shared.debugKeepWindow = nil
            let made = store.items.first { !before.contains($0.id) && $0.kind == .video }
            note("live recording: started \(started), saved \(made != nil), \(String(format: "%.1f", made?.video?.duration ?? 0)) s, \(made.map { "\($0.pixelWidth)×\($0.pixelHeight)" } ?? "-")")
            if let made, let png = store.pngData(made.id) { try? png.write(to: out.appending(path: "live-recording.png")) }
        } else {
            note("live recording: skipped (this copy may not record the screen)")
        }

        if let bar = ScreenRecorder.shared.debugShowBar(over: CGRect(x: 200, y: 300, width: 640, height: 360)) {
            try? await Task.sleep(for: .seconds(1))
            render(bar, to: out.appending(path: "record-bar.png"))
        }
        await ScreenRecorder.shared.debugReset()
        note("record preset: \(Preferences.shared.presets.first { $0.mode == .recording }.map { "\($0.name) \($0.hotKey?.display ?? "-")" } ?? "missing")")
    }

    /// Edit Text, Smart Move and Simplify on a made-up settings window.
    private static func phase4Test(_ note: (String) -> Void, out: URL) async {
        let store = LibraryStore.shared
        let editor = AnnotationEditor.shared
        let window = LibraryWindow.shared
        let screen = NSImage(size: CGSize(width: 800, height: 500), flipped: true) { rect in
            NSColor(white: 0.95, alpha: 1).setFill(); rect.fill()
            NSAttributedString(string: "Account Settings", attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor.black])
                .draw(at: CGPoint(x: 40, y: 30))
            NSAttributedString(string: "Your plan renews on November 1", attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.darkGray])
                .draw(at: CGPoint(x: 40, y: 90))
            NSColor.systemRed.setFill(); NSBezierPath(ovalIn: CGRect(x: 640, y: 30, width: 48, height: 48)).fill()
            NSColor.white.setFill(); NSBezierPath(roundedRect: CGRect(x: 40, y: 160, width: 320, height: 34), xRadius: 6, yRadius: 6).fill()
            NSColor.gray.setStroke(); NSBezierPath(roundedRect: CGRect(x: 40, y: 160, width: 320, height: 34), xRadius: 6, yRadius: 6).stroke()
            NSColor.systemBlue.setFill(); NSBezierPath(roundedRect: CGRect(x: 40, y: 400, width: 160, height: 40), xRadius: 8, yRadius: 8).fill()
            NSAttributedString(string: "Save Changes", attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white])
                .draw(at: CGPoint(x: 70, y: 410))
            return true
        }
        // At 2×, as a Retina capture would be.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 1000, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = screen.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        screen.draw(in: CGRect(origin: .zero, size: screen.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = rep.cgImage, let item = store.add(image: image, kind: .region, scale: 2, source: .init(appName: "DebugHook"), cursor: nil),
              let copy = store.add(image: image, kind: .region, scale: 2, source: .init(appName: "DebugHook"), cursor: nil) else {
            return note("phase 4: couldn't add the sample")
        }
        window.show(select: item.id)
        try? await Task.sleep(for: .seconds(1))
        editor.open(item.id)
        editor.pick(.draw(.move))
        for _ in 0..<60 where editor.analysis == nil { try? await Task.sleep(for: .milliseconds(250)) }
        guard let analysis = editor.analysis else { return note("phase 4: no analysis") }
        for line in analysis.lines {
            note("smart line \"\(line.text)\" at \(Int(line.box.minX)),\(Int(line.box.minY)) \(Int(line.box.width))×\(Int(line.box.height)) → text size \(TextMatch.fontSize(forLineHeight: line.box.height))")
        }
        note("smart parts: \(analysis.objects.count) \(analysis.objects.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" })")

        func find(_ view: NSView?) -> AnnotationLayerView? {
            guard let view else { return nil }
            if let layer = view as? AnnotationLayerView { return layer }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        guard let layer = find(window.window?.contentView), let win = window.window else { return note("phase 4: no layer") }
        func send(_ type: NSEvent.EventType, _ point: CGPoint) {
            guard let event = NSEvent.mouseEvent(with: type, location: layer.convert(point, to: nil), modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            switch type {
            case .leftMouseDown: layer.mouseDown(with: event)
            case .leftMouseDragged: layer.mouseDragged(with: event)
            case .mouseMoved: layer.mouseMoved(with: event)
            default: layer.mouseUp(with: event)
            }
        }
        send(.mouseMoved, CGPoint(x: 120, y: 420))
        try? await Task.sleep(for: .seconds(0.5))
        render(win, to: out.appending(path: "smart-move-tool.png"))
        // Pick up the button and put it down to the right.
        send(.leftMouseDown, CGPoint(x: 120, y: 420)); send(.leftMouseDragged, CGPoint(x: 320, y: 400)); send(.leftMouseDragged, CGPoint(x: 520, y: 400))
        send(.leftMouseUp, CGPoint(x: 520, y: 400))
        let moved = store.entry(item.id)?.annotations.filter { $0.kind == .move } ?? []
        note("smart move: \(moved.map { "from \(Int($0.source.minX)),\(Int($0.source.minY)) to \(Int($0.rect.minX)),\(Int($0.rect.minY))" })")
        editor.undo()
        note("undo smart move: \(store.entry(item.id)?.annotations.isEmpty == true)")
        editor.redo()

        // Retype the date.
        editor.pick(.draw(.editText))
        send(.leftMouseDown, CGPoint(x: 120, y: 100)); send(.leftMouseUp, CGPoint(x: 120, y: 100))
        if let field = win.firstResponder as? NSTextView {
            field.string = "Your plan renews on December 15"
            layer.endTextEditing()
        }
        let retyped = store.entry(item.id)?.annotations.filter { $0.kind == .editText } ?? []
        note("edit text: \(retyped.map { "\"\($0.text)\" size \($0.style.fontSize) bold \($0.style.bold) color \(String(format: "%.2f", $0.style.color.r))" })")
        editor.pick(.select)
        if let final = store.entry(item.id), let flat = Flattener.image(final) {
            try? NSBitmapImageRep(cgImage: flat).representation(using: .png, properties: [:])?.write(to: out.appending(path: "smart-edited.png"))
        }

        // Simplify the untouched copy, both ways.
        window.show(select: copy.id)
        try? await Task.sleep(for: .seconds(1))
        editor.open(copy.id)
        for colors in Simplifier.Colors.allCases {
            editor.simplify(colors)
            try? await Task.sleep(for: .milliseconds(300))
            for _ in 0..<60 where editor.simplifying { try? await Task.sleep(for: .milliseconds(250)) }
            let marks = store.entry(copy.id)?.annotations ?? []
            note("simplify \(colors.rawValue): \(marks.filter { $0.shape != .textBar }.map(\.shape.rawValue)) shapes, \(marks.filter { $0.shape == .textBar }.count) bars")
            if let final = store.entry(copy.id), let flat = Flattener.image(final) {
                try? NSBitmapImageRep(cgImage: flat).representation(using: .png, properties: [:])?.write(to: out.appending(path: "simplified-\(colors.rawValue).png"))
            }
        }
        render(win, to: out.appending(path: "simplify-view.png"))
        editor.removeSimplify()
        note("remove simplify: \(store.entry(copy.id)?.annotations.isEmpty == true)")
    }

    /// Scrolling capture's stitching and saving, step labels, guides and batch export.
    private static func phase3Test(_ note: (String) -> Void, out: URL) async {
        let store = LibraryStore.shared
        // A tall page, as scrolling would see it through a 300-point-high window.
        let lines = (1...60).map { "Line \($0): the quick brown fox jumps over the lazy dog \($0 * 7)" }.joined(separator: "\n")
        if let page = DebugImage.make(text: lines, size: CGSize(width: 700, height: 2400)) {
            let worker = StitchWorker()
            let frameHeight = 600 // pixels: 300 points at 2×
            var offset = 0
            for step in [0, 180, 250, 120, 300, 260, 200, 330, 280, 310, 400, 400, 400, 400] {
                offset = min(offset + step, page.height - frameHeight)
                if let frame = page.cropping(to: CGRect(x: 0, y: offset, width: page.width, height: frameHeight)) { _ = await worker.add(frame) }
            }
            if let tall = await worker.image() {
                note("scrolling stitch: \(tall.width)×\(tall.height) px from a \(page.width)×\(page.height) page")
                try? NSBitmapImageRep(cgImage: tall).representation(using: .png, properties: [:])?.write(to: out.appending(path: "scrolled.png"))
                if let item = store.add(image: tall, kind: .region, scale: 2, source: .init(appName: "DebugHook"), cursor: nil) {
                    note("scrolling capture saved: \(Int(item.pointSize.width))×\(Int(item.pointSize.height)) pt")
                }
            }
        }
        // A click on "Save" in a strip of buttons.
        if let buttons = DebugImage.make(text: "Cancel          Save          Help", size: CGSize(width: 700, height: 160)) {
            // DebugImage draws the text 30 points in and 60 down; "Save" sits about 280 points in.
            for x in [70.0, 300.0, 520.0] {
                let label = await StepRecorder.label(near: CGPoint(x: x, y: 80), in: buttons, scale: Double(buttons.width) / 700)
                note("step label at x=\(Int(x)): \(label ?? "none")")
            }
        }
        // A guide from the three sample captures.
        let samples = store.items.filter { ["Pancake Recipe", "Build Failed Error", "Sales Dashboard Performance"].contains($0.name) || $0.source.appName == "Safari" || $0.source.appName == "Xcode" || $0.source.appName == "Notes" }
        let window = LibraryWindow.shared
        window.state.makeGuide(from: samples)
        try? await Task.sleep(for: .seconds(2))
        if let sheet = window.window?.attachedSheet {
            render(sheet, to: out.appending(path: "guide-sheet.png"))
            note("guide sheet shown for \(window.state.guide?.items.count ?? 0) captures")
        }
        let entries = samples.sorted { $0.created < $1.created }.compactMap { item -> GuideEntry? in
            Flattener.image(item).map { GuideEntry(image: $0, pointSize: item.edits.outputSize(for: item.pointSize), title: item.name, text: item.notes, date: item.created) }
        }
        for template in GuideTemplate.allCases {
            let doc = GuideRenderer.Document(template: template, title: "Sample Guide", subtitle: "Made by the self-test", entries: entries)
            if let png = GuideRenderer.image(doc).flatMap({ NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }) {
                try? png.write(to: out.appending(path: "guide-\(template.rawValue).png"))
            }
            if let pdf = GuideRenderer.pdf(doc) {
                try? pdf.write(to: out.appending(path: "guide-\(template.rawValue).pdf"))
                note("guide \(template.rawValue): \(GuideRenderer.pageCount(pdf)) PDF page(s)")
            }
        }
        window.state.guide = nil
        try? await Task.sleep(for: .milliseconds(500))
        // Batch export.
        let folder = out.appending(path: "batch")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let count = BatchExportSheet.export(samples.map(\.id), format: .jpeg, size: 0.5, frame: .shadow, naming: .numbered, to: folder)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()) ?? []
        note("batch export: \(count) written: \(files)")
        let again = BatchExportSheet.export(samples.prefix(1).map(\.id), format: .jpeg, size: 0.5, frame: .shadow, naming: .numbered, to: folder)
        note("exporting again doesn't overwrite: \(again == 1 && ((try? FileManager.default.contentsOfDirectory(atPath: folder.path).count) ?? 0) == files.count + 1)")
    }

    private static func alpha(_ image: CGImage, x: Int, y: Int) -> Int {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return Int(data[(y * image.width + x) * 4 + 3])
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
/// Short test movies: colored frames with their number written on them.
enum DebugMovie {
    static func write(to url: URL, seconds: Double, startFrame: Int, size: CGSize = CGSize(width: 640, height: 360)) async -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        let count = Int(seconds * 30)
        for i in 0..<count {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { return false }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                   bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                let n = startFrame + i
                let hue = CGFloat(n % 120) / 120
                ctx.setFillColor(NSColor(hue: hue, saturation: 0.35, brightness: 0.95, alpha: 1).cgColor)
                ctx.fill(CGRect(origin: .zero, size: size))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSAttributedString(string: "Demo Recording\nFrame \(n)", attributes: [.font: NSFont.systemFont(ofSize: 44, weight: .bold),
                                                                                       .foregroundColor: NSColor.black])
                    .draw(at: CGPoint(x: 40, y: 140))
                NSGraphicsContext.restoreGraphicsState()
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }
}
#endif
