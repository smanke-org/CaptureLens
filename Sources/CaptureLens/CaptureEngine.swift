import AppKit
import CaptureLensKit

/// Every capture, from a preset's shortcut, the menu, ToolHUD or a URL: count down if asked,
/// pick what to capture, then save it to the library (and the clipboard, if wanted).
@MainActor
final class CaptureEngine {
    static let shared = CaptureEngine()

    private(set) var isCounting = false
    private var busy = false
    /// A capture is under way, from the countdown until it's saved.
    var isBusy: Bool { busy }
    /// ⌥ was down when the area or window was picked (it may be up by the time it's saved).
    var optionHeld = false

    /// The area last captured, for "Capture Same Area Again".
    private(set) var lastRegion: ScreenRegion? {
        didSet { AppDefaults.store.set(try? JSONEncoder().encode(lastRegion), forKey: "lastRegion") }
    }

    private init() {
        if let data = AppDefaults.store.data(forKey: "lastRegion") {
            lastRegion = try? JSONDecoder().decode(ScreenRegion.self, from: data)
        }
    }

    func run(_ preset: CapturePreset) {
        // Recording has its own control bar; the same shortcut stops it.
        if preset.mode == .recording { return ScreenRecorder.shared.toggle(preset) }
        guard !busy, !ScreenRecorder.shared.isActive else { return }
        guard ensureAccess() else { return }
        busy = true
        Activity.shared.touch()
        Task {
            defer { busy = false }
            if preset.delay > 0 {
                isCounting = true
                let finished = await Countdown.shared.run(seconds: preset.delay)
                isCounting = false
                guard finished else { return }
            } else {
                // Started from the menu bar menu: let it finish fading out so it isn't in the picture.
                try? await Task.sleep(for: .milliseconds(180))
            }
            await capture(preset)
        }
    }

    /// The same area as last time, from the live screen, without selecting.
    func captureAgain() {
        guard let region = lastRegion, let frame = region.globalFrame else {
            Notice.shared.show(error: "Capture an area first; then this captures the same area again.")
            return
        }
        guard !busy, ensureAccess() else { return }
        busy = true
        let cursor = Preferences.shared.captureCursor ? CursorSnapshot.current() : nil
        let windows = ScreenWindow.onScreen()
        Task {
            defer { busy = false }
            do {
                let image = try await region.capture()
                await save(image, kind: .region, frame: frame, display: region.displayID, window: nil, windows: windows,
                           cursor: cursor, preset: nil)
            } catch {
                Notice.shared.show(error: "Couldn't capture that area", near: frame)
            }
        }
    }

    private func ensureAccess() -> Bool {
        if ScreenAccess.granted { return true }
        ScreenAccess.request()
        if !ScreenAccess.granted { ScreenAccess.explainDenied(); return false }
        return true
    }

    private func capture(_ preset: CapturePreset) async {
        let prefs = Preferences.shared
        optionHeld = false
        // The pointer as it was before the overlay took over, and the windows as they were.
        let cursor = prefs.captureCursor ? CursorSnapshot.current() : nil
        let windows = ScreenWindow.onScreen()

        if preset.mode == .screen {
            let pointer = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main else { return }
            do {
                let image = try await ScreenGrabber.captureDisplay(screen.displayID)
                await save(image, kind: .screen, frame: screen.frame, display: screen.displayID, window: nil,
                           windows: windows, cursor: cursor, preset: preset)
            } catch {
                fail(error)
            }
            return
        }

        let frozen: [CGDirectDisplayID: CGImage]
        do {
            frozen = try await ScreenGrabber.captureAllScreens()
        } catch {
            return fail(error)
        }
        let size = CGSize(width: preset.width, height: preset.height)
        // Scrolling captures start like the all-in-one: click a window or drag an area.
        let pickMode: CaptureMode = preset.mode == .scrolling ? .allInOne : preset.mode
        guard let pick = await CaptureOverlay.shared.pick(mode: pickMode, fixedSize: size, images: frozen) else { return }
        if preset.mode == .scrolling { return scroll(pick, windows: windows, preset: preset) }
        switch pick {
        case .region(let region, let image, let frame):
            lastRegion = region
            await save(image, kind: .region, frame: frame, display: region.displayID, window: nil, windows: windows,
                       cursor: cursor, preset: preset)
        case .screen(let display, let image, let frame):
            await save(image, kind: .screen, frame: frame, display: display, window: nil, windows: windows,
                       cursor: cursor, preset: preset)
        case .window(let window):
            // The overlay has to be gone before the window is captured on its own.
            try? await Task.sleep(for: .milliseconds(60))
            do {
                let (image, frame) = try await ScreenGrabber.captureWindow(window.id, shadow: prefs.windowShadow)
                await save(image, kind: .window, frame: frame, display: nil, window: window, windows: windows,
                           cursor: cursor, preset: preset)
            } catch {
                fail(error)
            }
        }
    }

    /// Hands the picked area to the scrolling capture, then saves what it stitches.
    private func scroll(_ pick: CaptureOverlay.Pick, windows: [ScreenWindow], preset: CapturePreset) {
        let region: ScreenRegion, frame: CGRect, window: ScreenWindow?
        switch pick {
        case .region(let r, _, let f): (region, frame, window) = (r, f, nil)
        case .screen(let display, _, let f): (region, frame, window) = (ScreenRegion(displayID: display, rect: CGRect(origin: .zero, size: f.size)), f, nil)
        case .window(let w):
            // The window's part of its screen.
            guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(w.frame) }) else { return }
            let visible = w.frame.intersection(screen.frame)
            region = ScreenRegion(displayID: screen.displayID,
                                  rect: CGRect(x: visible.minX - screen.frame.minX, y: screen.frame.maxY - visible.maxY,
                                               width: visible.width, height: visible.height))
            (frame, window) = (visible, w)
        }
        ScrollCapture.shared.start(region: region, frame: frame) { [weak self] image in
            guard let self, let image else { return }
            Task {
                // Keep the frame's width; the stitched picture is as tall as it got.
                let scale = frame.width > 0 ? Double(image.width) / frame.width : 2
                let tall = CGRect(x: frame.minX, y: frame.maxY - Double(image.height) / scale, width: frame.width,
                                  height: Double(image.height) / scale)
                await self.save(image, kind: window == nil ? .region : .window, frame: tall, display: region.displayID,
                                window: window, windows: windows, cursor: nil, preset: preset)
            }
        }
    }

    private func fail(_ error: Error) {
        NSLog("CaptureLens: capture failed: \(error.localizedDescription)")
        Sounds.failure()
        if !ScreenAccess.granted { ScreenAccess.explainDenied() } else { Notice.shared.show(error: error.localizedDescription) }
    }

    /// Saves a picture covering `frame` (global Cocoa coordinates) to the library.
    private func save(_ image: CGImage, kind: CaptureItem.Kind, frame: CGRect, display: CGDirectDisplayID?,
                      window: ScreenWindow?, windows: [ScreenWindow], cursor: CursorSnapshot?,
                      preset: CapturePreset?) async {
        let prefs = Preferences.shared
        Sounds.shutter()
        Activity.shared.touch()
        var source = SourceInfo.describe(frame: frame, windows: windows, window: window, display: display)
        if prefs.recordWebAddress, let bundleID = source.bundleID, SourceInfo.isBrowser(bundleID),
           let page = await SourceInfo.webPage(bundleID: bundleID) {
            source.url = page.url
            source.pageTitle = page.title
        }
        let scale = frame.width > 0 ? Double(image.width) / frame.width : 2
        let layer = cursor?.layer(captureTopLeft: CGPoint(x: frame.minX, y: frame.maxY), size: frame.size,
                                  visible: prefs.showCursorByDefault)
        guard let item = LibraryStore.shared.add(image: image, kind: kind, scale: scale, source: source, cursor: layer) else {
            Sounds.failure()
            Notice.shared.show(error: "Couldn't save the capture to the library")
            return
        }
        ActivityStore.shared.recordCapture(kind, scrolling: preset?.mode == .scrolling)
        let clipboard = preset?.clipboard ?? .setting
        let copy = clipboard == .always || (clipboard == .setting && prefs.copyToClipboard)
        if copy, let png = Flattener.png(item) { Clipboard.copy(png: png) }
        // Holding ⌥ while picking the area or window opens this one in the library, whatever
        // the settings. (Not ⌥ held now: the default shortcuts include it.)
        let chosen = preset?.afterCapture ?? prefs.afterCapture
        let after = optionHeld ? chosen.openingLibrary : chosen
        optionHeld = false
        if after.opensLibrary { LibraryWindow.shared.show(select: item.id) }
        // After the library, so the preview floats over it.
        if after.showsPreview { CapturePreview.shared.show(item, near: frame, copied: copy) }
        if after == .nothing && copy { Notice.shared.show("Saved and copied", symbol: "camera.viewfinder", near: frame) }
    }
}

/// The big countdown before a delayed capture. Clicking it cancels.
@MainActor
final class Countdown {
    static let shared = Countdown()
    private var panel: NSPanel?
    private var label = NSTextField(labelWithString: "")
    private var cancelled = false

    /// Counts down; false if it was cancelled.
    func run(seconds: Int) async -> Bool {
        cancelled = false
        let panel = makePanel()
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        panel.setFrameOrigin(CGPoint(x: screen.frame.midX - 70, y: screen.frame.midY - 70))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        for remaining in stride(from: seconds, through: 1, by: -1) {
            label.stringValue = "\(remaining)"
            if remaining <= 3 { Sounds.tick() }
            try? await Task.sleep(for: .seconds(1))
            if cancelled { break }
        }
        panel.orderOut(nil)
        // Let the panel leave the screen before the picture is taken.
        try? await Task.sleep(for: .milliseconds(120))
        return !cancelled
    }

    private func makePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 140, height: 140), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let button = ClickView(frame: CGRect(x: 0, y: 0, width: 140, height: 140)) { [weak self] in self?.cancelled = true }
        button.wantsLayer = true
        button.layer?.cornerRadius = 32
        button.layer?.cornerCurve = .continuous
        button.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.82).cgColor
        label.font = .monospacedDigitSystemFont(ofSize: 72, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = CGRect(x: 0, y: 30, width: 140, height: 86)
        button.addSubview(label)
        let hint = NSTextField(labelWithString: "Click to cancel")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .init(white: 1, alpha: 0.7)
        hint.alignment = .center
        hint.frame = CGRect(x: 0, y: 12, width: 140, height: 16)
        button.addSubview(hint)
        panel.contentView = button
        self.panel = panel
        return panel
    }

    private final class ClickView: NSView {
        let action: () -> Void
        init(frame: CGRect, action: @escaping () -> Void) {
            self.action = action
            super.init(frame: frame)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { action() }
    }
}

/// A capture with its visible layers drawn in, for copying, dragging and saving.
@MainActor
enum Flattener {
    /// PNG of the capture as it looks in the library: the picture with its annotations and,
    /// if shown, the pointer.
    static func png(_ item: CaptureItem) -> Data? {
        guard let data = LibraryStore.shared.pngData(item.id) else { return nil }
        guard needsDrawing(item) else { return data }
        return image(item, data: data)?.pngData ?? data
    }

    /// The finished picture: annotations and pointer drawn in, then cropped, cut, turned,
    /// resized, edged and framed as the capture's adjustments say.
    static func image(_ item: CaptureItem, data: Data? = nil) -> CGImage? {
        guard let data = data ?? LibraryStore.shared.pngData(item.id), let source = AnnotationRenderer.image(from: data) else { return nil }
        let mask = item.edits.removeBackground ? LibraryStore.shared.subjectMask(item.id, image: source) : nil
        return EditRenderer.render(base: source, scale: item.scale, edits: item.edits, annotations: item.annotations,
                                   cursor: item.cursor, mask: mask)
    }

    /// Whether the finished picture differs from the original.
    static func needsDrawing(_ item: CaptureItem) -> Bool {
        !item.annotations.isEmpty || item.cursor?.visible == true || !item.edits.isEmpty
    }

    /// Writes the flattened capture to a temporary file named after it, for dragging out.
    static func temporaryFile(_ item: CaptureItem) -> URL? {
        if item.kind == .video, VideoStore.shared.has(item.id) { return VideoExport.temporaryFile(item) }
        guard let png = png(item) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appending(path: "CaptureLens Drag/\(item.id.uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(item.name).png")
        do { try png.write(to: url) } catch { return nil }
        return url
    }
}
