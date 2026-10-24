#if DEBUG
import AppKit
@preconcurrency import AVFoundation
import CaptureLensKit
import SwiftUI

/// `CAPTURELENS_DEBUG_SHOTS=<folder>` (with `CAPTURELENS_DEFAULTS_SUITE` and
/// `CAPTURELENS_LIBRARY_FOLDER`): fills the test library with made-up captures, opens each
/// window on a 2× display and saves a picture of just that window (with its shadow) for the
/// website, then quits. Only CaptureLens's own windows are captured.
@MainActor
enum DebugShots {
    static func run(out: URL) {
        let env = ProcessInfo.processInfo.environment
        guard env["CAPTURELENS_DEFAULTS_SUITE"] != nil, env["CAPTURELENS_LIBRARY_FOLDER"] != nil else { exit(2) }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        AppDefaults.store.set("dark", forKey: AppAppearance.key)
        let prefs = Preferences.shared
        prefs.autoName = false
        prefs.copyToClipboard = false
        Task {
            var log: [String] = []
            func note(_ line: String) {
                log.append(line)
                try? log.joined(separator: "\n").appending("\n").write(to: out.appending(path: "shots.txt"), atomically: true, encoding: .utf8)
            }
            let screen = NSScreen.screens.first { $0.backingScaleFactor >= 2 } ?? NSScreen.main!
            note("screen \(screen.localizedName) \(screen.frame) \(screen.backingScaleFactor)x")
            let ids = await addSamples()
            note("samples \(ids.count)")
            try? await Task.sleep(for: .seconds(2))

            let library = LibraryWindow.shared
            library.show(select: ids.dashboard)
            guard let window = library.window else { return note("no library window") }
            place(window, size: CGSize(width: 1440, height: 900), on: screen)
            try? await Task.sleep(for: .seconds(3))
            await shoot(window, "library-editor", out: out, note: note)

            // The sidebar with Apps folded away.
            AppDefaults.store.set(false, forKey: "library.sidebar.appsOpen")
            try? await Task.sleep(for: .seconds(1))
            await shoot(window, "sidebar-apps-folded", out: out, note: note)
            AppDefaults.store.set(true, forKey: "library.sidebar.appsOpen")

            // Smart Move on the settings page, the pointer over its button.
            library.show(select: ids.settings)
            try? await Task.sleep(for: .seconds(1.5))
            CanvasZoom.shared.fitRequested += 1
            try? await Task.sleep(for: .seconds(0.5))
            let editor = AnnotationEditor.shared
            editor.pick(.draw(.move))
            for _ in 0..<40 where editor.analysis == nil { try? await Task.sleep(for: .milliseconds(250)) }
            if let layer = find(window.contentView), let event = NSEvent.mouseEvent(with: .mouseMoved, location: layer.convert(CGPoint(x: 120, y: 420), to: nil),
                                                                                   modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                                                   context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                layer.mouseMoved(with: event)
            }
            try? await Task.sleep(for: .seconds(1))
            await shoot(window, "smart-move", out: out, note: note)
            editor.pick(.select)

            // Simplify, shown as the finished picture.
            library.show(select: ids.simplified)
            try? await Task.sleep(for: .seconds(1.5))
            editor.simplify(.original)
            for _ in 0..<60 where editor.simplifying { try? await Task.sleep(for: .milliseconds(250)) }
            editor.showResult = true
            try? await Task.sleep(for: .seconds(1.5))
            await shoot(window, "simplify", out: out, note: note)
            editor.showResult = false

            // A recording, with its timeline.
            library.show(select: ids.video)
            try? await Task.sleep(for: .seconds(4))
            await shoot(window, "video", out: out, note: note)

            // The bar before recording.
            if let bar = ScreenRecorder.shared.debugShowBar(over: CGRect(x: screen.visibleFrame.midX - 320, y: screen.visibleFrame.midY,
                                                                       width: 640, height: 300)) {
                try? await Task.sleep(for: .seconds(1))
                await shoot(bar, "record-bar", out: out, note: note)
            }
            await ScreenRecorder.shared.debugReset()

            // Settings, as a new install has them.
            prefs.autoName = true
            let small = ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_SCREEN_HEIGHT"] != nil
            for tab in small ? ["Capture", "Presets", "Library", "Privacy", "Activity", "General"] : ["Capture", "Library", "Activity"] {
                SettingsWindow.shared.show(tab: tab)
                try? await Task.sleep(for: .seconds(1.5))
                if let settings = SettingsWindow.shared.debugWindow {
                    settings.setFrameTopLeftPoint(CGPoint(x: screen.visibleFrame.minX + 60, y: screen.visibleFrame.maxY - 20))
                    try? await Task.sleep(for: .seconds(0.5))
                    await shoot(settings, "settings-\(tab.lowercased())", out: out, note: note)
                    note("settings-\(tab.lowercased()) window \(Int(settings.frame.width))×\(Int(settings.frame.height)) pt")
                    settings.orderOut(nil)
                }
            }

            // Import from Snagit, with made-up Snagit folders.
            if let folder = await sampleSnagitFolder() {
                SnagitImporter.shared.debugUse([folder.0, folder.1], videoFolder: FileManager.default.temporaryDirectory.appending(path: "CaptureLens Shot Videos"))
                SnagitImporter.shared.nameCaptures = true
                SnagitImportWindow.shared.show()
                try? await Task.sleep(for: .seconds(1.5))
                if let importWindow = SnagitImporter.shared.debugWindow {
                    place(importWindow, size: nil, on: screen)
                    try? await Task.sleep(for: .seconds(0.5))
                    await shoot(importWindow, "snagit-import", out: out, note: note)
                    importWindow.orderOut(nil)
                }
            }

            note("done")
            NSApp.terminate(nil)
        }
    }

    // MARK: Windows

    static func place(_ window: NSWindow, size: CGSize?, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = size.map { CGSize(width: min($0.width, visible.width - 80), height: min($0.height, visible.height - 60)) } ?? window.frame.size
        window.setFrame(CGRect(x: visible.minX + 40, y: visible.maxY - size.height - 20, width: size.width, height: size.height), display: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func shoot(_ window: NSWindow, _ name: String, out: URL, note: (String) -> Void) async {
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(400))
        do {
            let (image, _) = try await ScreenGrabber.captureWindow(CGWindowID(window.windowNumber), shadow: true)
            try image.pngData?.write(to: out.appending(path: "\(name).png"))
            note("\(name): \(image.width)×\(image.height)")
        } catch {
            note("\(name): FAILED \(error.localizedDescription)")
        }
    }

    static func find(_ view: NSView?) -> AnnotationLayerView? {
        guard let view else { return nil }
        if let layer = view as? AnnotationLayerView { return layer }
        for sub in view.subviews { if let hit = find(sub) { return hit } }
        return nil
    }

    // MARK: Made-up captures

    struct Samples { var dashboard: UUID; var settings: UUID; var simplified: UUID; var video: UUID; var count: Int }

    static func addSamples() async -> Samples {
        let store = LibraryStore.shared
        func add(_ image: CGImage?, name: String, app: String, bundle: String, title: String, url: String? = nil, tags: [String],
                 favorite: Bool = false, notes: String = "", daysAgo: Double, marks: [Annotation] = []) -> UUID? {
            guard let image, var item = store.add(image: image, kind: url == nil ? .window : .region, scale: 2,
                                                  source: .init(appName: app, bundleID: bundle, windowTitle: title, url: url,
                                                                pageTitle: url == nil ? nil : title),
                                                  cursor: nil, created: Date().addingTimeInterval(-daysAgo * 86_400), analyze: false) else { return nil }
            item.name = name
            item.nameIsAutomatic = false
            item.tags = tags
            item.favorite = favorite
            item.notes = notes
            item.annotations = marks
            store.update(item)
            store.analyze(item.id, rename: false)
            return item.id
        }
        let palette = add(Mock.palette(), name: "Brand Color Palette", app: "Preview", bundle: "com.apple.Preview", title: "Palette.png",
                          tags: ["design"], daysAgo: 9)
        let flight = add(Mock.flight(), name: "Flight to Lisbon Itinerary", app: "Mail", bundle: "com.apple.mail", title: "Your trip to Lisbon",
                         tags: ["travel"], notes: "Seat 14A. Check in opens 24 hours before.", daysAgo: 6)
        let calendar = add(Mock.calendar(), name: "Team Calendar Week 44", app: "Calendar", bundle: "com.apple.iCal", title: "Calendar",
                           tags: ["work"], daysAgo: 4)
        let recipe = add(Mock.recipe(), name: "Lemon Ricotta Pancakes Recipe", app: "Notes", bundle: "com.apple.Notes", title: "Recipes",
                         tags: ["recipes"], favorite: true, daysAgo: 3)
        let code = add(Mock.codeError(), name: "Order Total Build Error", app: "Xcode", bundle: "com.apple.dt.Xcode", title: "Shop — OrderView.swift",
                       tags: ["bugs", "work"], notes: "Happens after the cart refactor.", daysAgo: 2,
                       marks: [Annotation(kind: .rectangle, rect: CGRect(x: 54, y: 254, width: 640, height: 34), style: AnnotationStyle(color: .yellow, lineWidth: 3))])
        let settings = add(Mock.settings(), name: "Account Settings Page", app: "Safari", bundle: "com.apple.Safari", title: "Account Settings",
                           url: "https://app.example.com/settings/account", tags: ["work", "design"], daysAgo: 1)
        let simplified = add(Mock.settings(), name: "Account Settings Layout", app: "Safari", bundle: "com.apple.Safari", title: "Account Settings",
                             url: "https://app.example.com/settings/account", tags: ["design"], daysAgo: 1.5)
        let red = AnnotationStyle(color: .red, lineWidth: 4)
        let dashboard = add(Mock.dashboard(), name: "Quarterly Sales Dashboard", app: "Safari", bundle: "com.apple.Safari", title: "Sales Dashboard",
                            url: "https://analytics.example.com/q3", tags: ["work", "reports"], favorite: true,
                            notes: "For the Monday review: call out the North region and the September jump.", daysAgo: 0.1,
                            marks: [
                                Annotation(kind: .rectangle, rect: CGRect(x: 36, y: 96, width: 196, height: 104), style: red),
                                Annotation(kind: .step, rect: CGRect(x: 18, y: 80, width: 32, height: 32), style: AnnotationStyle(color: .blue, lineWidth: 4, fontSize: 20)),
                                Annotation(kind: .callout, rect: CGRect(x: 520, y: 236, width: 200, height: 64), tail: CGPoint(x: 600, y: 330),
                                           text: "Up 12% after the September launch", style: AnnotationStyle(color: .purple, lineWidth: 3, fontSize: 16)),
                                Annotation(kind: .arrow, from: CGPoint(x: 330, y: 440), to: CGPoint(x: 268, y: 372), style: AnnotationStyle(color: .orange, lineWidth: 5)),
                                Annotation(kind: .text, rect: CGRect(x: 336, y: 430, width: 220, height: 30), text: "Best region", style: AnnotationStyle(color: .orange, lineWidth: 3, fontSize: 18)),
                            ])
        // A short recording.
        let movie = FileManager.default.temporaryDirectory.appending(path: "CaptureLens Shot \(UUID().uuidString).mp4")
        var video: UUID?
        if await DebugMovie.write(to: movie, seconds: 6, startFrame: 0, size: CGSize(width: 1520, height: 960), background: Mock.dashboard()) {
            let asset = AVURLAsset(url: movie)
            let duration = (try? await asset.load(.duration).seconds) ?? 6
            if let poster = await VideoStore.frame(of: asset, at: 0.5),
               var item = store.addVideo(movie: movie, poster: poster, scale: 2, info: VideoInfo(duration: duration, edits: VideoEdits(trimStart: 0.6, cuts: [TimeCut(start: 2.4, end: 3.3)])),
                                         source: .init(appName: "Keynote", bundleID: "com.apple.iWork.Keynote", windowTitle: "Product Tour")) {
                item.name = "Product Tour Walkthrough"
                item.nameIsAutomatic = false
                item.tags = ["demo", "work"]
                store.update(item)
                video = item.id
            }
        }
        _ = (palette, flight, calendar, recipe, code)
        return Samples(dashboard: dashboard!, settings: settings!, simplified: simplified!, video: video ?? dashboard!, count: store.items.count)
    }

    /// Two made-up Snagit folders, so the import window has something to show.
    static func sampleSnagitFolder() async -> (URL, URL)? {
        let base = FileManager.default.temporaryDirectory.appending(path: "CaptureLens Shot Snagit")
        let autosave = base.appending(path: "Pictures/Snagit/Autosaved Captures"), cloud = base.appending(path: "OneDrive/Snagit")
        for folder in [autosave, cloud] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for i in 0..<3 { try? Data("x".utf8).write(to: autosave.appending(path: "2025-0\(i + 1)-01_10-00-00.snagx")) }
        for i in 0..<5 { try? Data("x".utf8).write(to: cloud.appending(path: "2024-1\(i % 3)-0\(i + 1)_09-30-00.snagx")) }
        _ = await DebugMovie.write(to: cloud.appending(path: "Onboarding demo.mp4"), seconds: 1, startFrame: 0)
        return (autosave, cloud)
    }
}

/// Made-up screens for the screenshots: placeholder names, sites and numbers.
@MainActor
enum Mock {
    static func draw(_ size: CGSize, _ body: (CGRect) -> Void) -> CGImage? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
        ctx.cgContext.translateBy(x: 0, y: size.height)
        ctx.cgContext.scaleBy(x: 1, y: -1)
        body(CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    static func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor = .black, at p: CGPoint) {
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]).draw(at: p)
    }

    static func box(_ r: CGRect, _ color: NSColor, radius: CGFloat = 10) {
        color.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }

    static func dashboard() -> CGImage? {
        draw(CGSize(width: 760, height: 480)) { r in
            NSColor(white: 0.97, alpha: 1).setFill(); r.fill()
            text("Quarterly Sales", 26, .bold, at: CGPoint(x: 36, y: 30))
            text("Q3 2026 · All regions", 13, .regular, .gray, at: CGPoint(x: 38, y: 64))
            let kpis = [("Revenue", "$1.28M", NSColor.systemBlue), ("Orders", "8,412", .systemGreen), ("New customers", "1,906", .systemOrange)]
            for (i, kpi) in kpis.enumerated() {
                let card = CGRect(x: 40 + CGFloat(i) * 236, y: 100, width: 220, height: 96)
                box(card, .white, radius: 12)
                text(kpi.0, 13, .medium, .gray, at: CGPoint(x: card.minX + 16, y: card.minY + 16))
                text(kpi.1, 28, .bold, kpi.2, at: CGPoint(x: card.minX + 16, y: card.minY + 40))
            }
            let chart = CGRect(x: 40, y: 220, width: 680, height: 230)
            box(chart, .white, radius: 12)
            text("Revenue by month", 14, .semibold, at: CGPoint(x: chart.minX + 16, y: chart.minY + 14))
            let values: [CGFloat] = [0.42, 0.5, 0.47, 0.58, 0.55, 0.63, 0.61, 0.66, 0.92]
            for (i, v) in values.enumerated() {
                let h = v * 150
                box(CGRect(x: chart.minX + 30 + CGFloat(i) * 70, y: chart.maxY - 24 - h, width: 40, height: h),
                    i == 8 ? .systemPurple : NSColor.systemBlue.withAlphaComponent(0.75), radius: 6)
            }
        }
    }

    static func settings() -> CGImage? {
        draw(CGSize(width: 800, height: 500)) { r in
            NSColor(white: 0.95, alpha: 1).setFill(); r.fill()
            text("Account Settings", 24, .bold, at: CGPoint(x: 40, y: 30))
            text("Your plan renews on November 1", 15, .regular, .darkGray, at: CGPoint(x: 40, y: 90))
            NSColor.systemRed.setFill(); NSBezierPath(ovalIn: CGRect(x: 690, y: 30, width: 48, height: 48)).fill()
            text("Display name", 13, .medium, .gray, at: CGPoint(x: 40, y: 140))
            box(CGRect(x: 40, y: 162, width: 320, height: 34), .white, radius: 6)
            NSColor.gray.setStroke(); NSBezierPath(roundedRect: CGRect(x: 40, y: 162, width: 320, height: 34), xRadius: 6, yRadius: 6).stroke()
            text("Alex Morgan", 15, .regular, at: CGPoint(x: 52, y: 170))
            text("Email", 13, .medium, .gray, at: CGPoint(x: 40, y: 216))
            box(CGRect(x: 40, y: 238, width: 320, height: 34), .white, radius: 6)
            NSBezierPath(roundedRect: CGRect(x: 40, y: 238, width: 320, height: 34), xRadius: 6, yRadius: 6).stroke()
            text("alex@example.com", 15, .regular, at: CGPoint(x: 52, y: 246))
            box(CGRect(x: 440, y: 140, width: 300, height: 132), .white, radius: 12)
            text("Pro plan", 18, .bold, at: CGPoint(x: 460, y: 156))
            text("5 seats · billed yearly", 13, .regular, .gray, at: CGPoint(x: 460, y: 186))
            box(CGRect(x: 460, y: 222, width: 120, height: 30), .systemGreen, radius: 15)
            text("Active", 14, .semibold, .white, at: CGPoint(x: 496, y: 228))
            box(CGRect(x: 40, y: 400, width: 160, height: 40), .systemBlue, radius: 8)
            text("Save Changes", 15, .semibold, .white, at: CGPoint(x: 70, y: 410))
            text("Cancel", 15, .regular, .systemBlue, at: CGPoint(x: 226, y: 410))
        }
    }

    static func codeError() -> CGImage? {
        draw(CGSize(width: 740, height: 420)) { r in
            NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1).setFill(); r.fill()
            let lines: [(String, NSColor)] = [
                ("struct OrderView: View {", .systemPink), ("    let order: Order", .white), ("", .white),
                ("    var body: some View {", .systemPink), ("        VStack(alignment: .leading) {", .white),
                ("            Text(order.title)", .white), ("            Text(order.total.formatted())", .white),
                ("        }", .white), ("    }", .white), ("}", .white),
            ]
            for (i, line) in lines.enumerated() {
                text("\(i + 12)", 13, .regular, .gray, at: CGPoint(x: 16, y: 30 + CGFloat(i) * 26))
                NSAttributedString(string: line.0, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: line.1])
                    .draw(at: CGPoint(x: 60, y: 28 + CGFloat(i) * 26))
            }
            box(CGRect(x: 56, y: 256, width: 636, height: 30), NSColor.systemRed.withAlphaComponent(0.35), radius: 4)
            text("Value of type 'Order' has no member 'total'", 13, .semibold, .white, at: CGPoint(x: 70, y: 262))
        }
    }

    static func recipe() -> CGImage? {
        draw(CGSize(width: 560, height: 460)) { r in
            NSColor(calibratedRed: 1, green: 0.98, blue: 0.9, alpha: 1).setFill(); r.fill()
            text("Lemon Ricotta Pancakes", 24, .bold, at: CGPoint(x: 34, y: 30))
            let items = ["1 cup ricotta", "2 eggs, separated", "1 cup flour", "1 lemon, zested", "2 tbsp sugar", "Pinch of salt"]
            for (i, item) in items.enumerated() { text("•  \(item)", 16, .regular, at: CGPoint(x: 40, y: 84 + CGFloat(i) * 30)) }
            text("Whisk the yolks into the ricotta, fold in the whites,", 14, .regular, .darkGray, at: CGPoint(x: 34, y: 290))
            text("cook on a buttered pan until golden.", 14, .regular, .darkGray, at: CGPoint(x: 34, y: 312))
        }
    }

    static func calendar() -> CGImage? {
        draw(CGSize(width: 760, height: 460)) { r in
            NSColor.white.setFill(); r.fill()
            text("Week 44", 22, .bold, at: CGPoint(x: 30, y: 22))
            let days = ["Mon", "Tue", "Wed", "Thu", "Fri"]
            for (i, day) in days.enumerated() {
                text(day, 13, .semibold, .gray, at: CGPoint(x: 90 + CGFloat(i) * 134, y: 64))
                NSColor(white: 0.9, alpha: 1).setFill(); CGRect(x: 80 + CGFloat(i) * 134, y: 90, width: 1, height: 350).fill()
            }
            let events: [(Int, CGFloat, CGFloat, String, NSColor)] = [(0, 110, 60, "Standup", .systemBlue), (1, 180, 90, "Design review", .systemPurple),
                                                                     (2, 120, 50, "1:1", .systemGreen), (3, 240, 110, "Launch prep", .systemOrange),
                                                                     (4, 140, 70, "Demo day", .systemPink)]
            for e in events {
                box(CGRect(x: 86 + CGFloat(e.0) * 134, y: e.1, width: 122, height: e.2), e.4.withAlphaComponent(0.85), radius: 8)
                text(e.3, 13, .semibold, .white, at: CGPoint(x: 94 + CGFloat(e.0) * 134, y: e.1 + 8))
            }
        }
    }

    static func flight() -> CGImage? {
        draw(CGSize(width: 640, height: 400)) { r in
            NSColor(white: 0.96, alpha: 1).setFill(); r.fill()
            box(CGRect(x: 30, y: 30, width: 580, height: 330), .white, radius: 16)
            text("Your trip to Lisbon", 22, .bold, at: CGPoint(x: 56, y: 54))
            text("BOS", 40, .heavy, .systemIndigo, at: CGPoint(x: 56, y: 110))
            text("LIS", 40, .heavy, .systemIndigo, at: CGPoint(x: 470, y: 110))
            NSColor.systemIndigo.setStroke(); let p = NSBezierPath(); p.move(to: CGPoint(x: 160, y: 136)); p.line(to: CGPoint(x: 450, y: 136)); p.lineWidth = 2; p.stroke()
            text("Departs Fri 7:40 PM · Arrives Sat 7:55 AM", 15, .medium, .darkGray, at: CGPoint(x: 56, y: 190))
            text("Seat 14A · Confirmation Q7X2LM", 15, .regular, .gray, at: CGPoint(x: 56, y: 220))
        }
    }

    static func palette() -> CGImage? {
        draw(CGSize(width: 680, height: 320)) { r in
            NSColor(white: 0.98, alpha: 1).setFill(); r.fill()
            text("Brand palette", 22, .bold, at: CGPoint(x: 30, y: 24))
            let colors: [(NSColor, String)] = [(.systemIndigo, "#5856D6"), (.systemTeal, "#30B0C7"), (.systemOrange, "#FF9500"), (.systemPink, "#FF2D55"), (NSColor(white: 0.15, alpha: 1), "#262626")]
            for (i, c) in colors.enumerated() {
                box(CGRect(x: 30 + CGFloat(i) * 126, y: 80, width: 110, height: 150), c.0, radius: 14)
                text(c.1, 13, .medium, .darkGray, at: CGPoint(x: 40 + CGFloat(i) * 126, y: 244))
            }
        }
    }
}
#endif
