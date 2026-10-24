import AppKit

/// The full-screen overlay for picking what to capture.
///
/// The screens are photographed first and the overlay is drawn over those still pictures,
/// so a menu, tooltip or video frame stays put while you pick. Depending on the mode you
/// point at a window and click it, drag out an area, or place a frame of an exact size.
@MainActor
final class CaptureOverlay {
    enum Pick {
        /// An area of one display, with its pixels from the still picture.
        case region(ScreenRegion, image: CGImage, globalFrame: CGRect)
        /// A window; it's captured on its own afterwards, so covered parts show too.
        case window(ScreenWindow)
        /// A whole display, from the still picture.
        case screen(CGDirectDisplayID, image: CGImage, globalFrame: CGRect)
    }

    static let shared = CaptureOverlay()
    private(set) var isSelecting = false

    private var views: [OverlayView] = []
    private var windows: [NSWindow] = []
    private var continuation: CheckedContinuation<Pick?, Never>?
    private var previousApp: NSRunningApplication?

    fileprivate var mode: CaptureMode = .allInOne
    fileprivate var fixedSize = CGSize(width: 1280, height: 720)
    fileprivate var screenWindows: [ScreenWindow] = []
    /// The window under the pointer, while windows can be picked.
    fileprivate var hovered: ScreenWindow?
    /// Global Cocoa coordinates.
    fileprivate var pointer = CGPoint.zero

    /// Shows the overlay and waits for a pick; nil if cancelled with Esc.
    func pick(mode: CaptureMode, fixedSize: CGSize, images: [CGDirectDisplayID: CGImage]) async -> Pick? {
        guard !isSelecting else { return nil }
        isSelecting = true
        defer { isSelecting = false }
        self.mode = mode
        self.fixedSize = fixedSize
        screenWindows = mode == .allInOne || mode == .window ? ScreenWindow.onScreen() : []
        pointer = NSEvent.mouseLocation
        hovered = window(at: pointer)
        previousApp = NSWorkspace.shared.frontmostApplication
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            for screen in NSScreen.screens {
                guard let image = images[screen.displayID] else { continue }
                let window = OverlayWindow(screen: screen)
                let view = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size), screen: screen, image: image, owner: self)
                window.contentView = view
                views.append(view)
                windows.append(window)
                window.orderFrontRegardless()
            }
            NSApp.activate(ignoringOtherApps: true)
            // Keyboard focus to the window under the pointer, so Esc works at once.
            (windows.first { NSMouseInRect(pointer, $0.frame, false) } ?? windows.first)?.makeKey()
            NSCursor.crosshair.set()
        }
    }

    fileprivate func window(at point: CGPoint) -> ScreenWindow? {
        screenWindows.first { $0.frame.contains(point) }
    }

    fileprivate func pointerMoved(to point: CGPoint) {
        pointer = point
        let now = window(at: point)
        if now?.id != hovered?.id { hovered = now }
        for view in views { view.needsDisplay = true }
    }

    fileprivate func finish(_ pick: Pick?) {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        screenWindows.removeAll()
        hovered = nil
        // Give the keyboard back to the app that had it.
        if let previousApp, previousApp != NSRunningApplication.current { previousApp.activate() }
        continuation?.resume(returning: pick)
        continuation = nil
    }

    /// The fixed-size frame centered on the pointer, kept on `screen` (view coordinates).
    fileprivate func fixedFrame(in screen: NSScreen) -> CGRect {
        let size = CGSize(width: min(fixedSize.width, screen.frame.width), height: min(fixedSize.height, screen.frame.height))
        let local = CGPoint(x: pointer.x - screen.frame.minX, y: pointer.y - screen.frame.minY)
        var origin = CGPoint(x: local.x - size.width / 2, y: local.y - size.height / 2)
        origin.x = min(max(origin.x, 0), screen.frame.width - size.width)
        origin.y = min(max(origin.y, 0), screen.frame.height - size.height)
        return CGRect(origin: origin, size: size).integral
    }

    fileprivate var prompt: String {
        switch mode {
        case .allInOne: "Click a window or drag over an area  ·  Return for the whole screen"
        case .region: "Drag over the area to capture"
        case .window: "Click the window to capture"
        case .fixedSize: "Click to capture \(Int(fixedSize.width)) × \(Int(fixedSize.height))"
        case .screen: "Click to capture this screen"
        }
    }
}

private final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        setFrame(screen.frame, display: false)
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// One screen's still picture with the selection drawn over it.
private final class OverlayView: NSView {
    private let screen: NSScreen
    private let image: CGImage
    private unowned let owner: CaptureOverlay
    private var start: CGPoint?
    private var current: CGPoint?
    private var dragging = false
    private let tint = NSColor.systemBlue

    init(frame: CGRect, screen: NSScreen, image: CGImage, owner: CaptureOverlay) {
        self.screen = screen
        self.image = image
        self.owner = owner
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    private var dragRect: CGRect? {
        guard dragging, let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(start.x - current.x), height: abs(start.y - current.y)).integral
    }

    /// What would be captured right now, in this view's coordinates.
    private var highlight: CGRect? {
        if let dragRect { return dragRect }
        switch owner.mode {
        case .fixedSize:
            return NSMouseInRect(owner.pointer, screen.frame, false) ? owner.fixedFrame(in: screen) : nil
        case .allInOne, .window:
            guard let window = owner.hovered else { return nil }
            let local = window.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            let visible = local.intersection(bounds)
            return visible.isEmpty ? nil : visible
        case .screen:
            return NSMouseInRect(owner.pointer, screen.frame, false) ? bounds : nil
        case .region:
            return nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(image, in: bounds)

        let dim = NSBezierPath(rect: bounds)
        let selection = highlight
        if let selection { dim.append(NSBezierPath(rect: selection).reversed) }
        NSColor.black.withAlphaComponent(0.35).setFill()
        dim.fill()

        if let selection {
            tint.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            border.stroke()
            if !dragging, owner.mode != .fixedSize, owner.mode != .screen, let window = owner.hovered {
                tint.withAlphaComponent(0.12).setFill()
                NSBezierPath(rect: selection).fill()
                let name = [window.ownerName, window.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
                drawLabel("\(name)  \(Int(window.frame.width)) × \(Int(window.frame.height))",
                          at: CGPoint(x: selection.midX, y: selection.midY), centered: true)
            } else {
                drawLabel("\(Int(selection.width)) × \(Int(selection.height))",
                          at: CGPoint(x: selection.maxX, y: selection.minY), centered: false)
            }
        }
        if !dragging && owner.mode != .fixedSize && owner.mode != .screen { drawGuides() }
        if NSMouseInRect(owner.pointer, screen.frame, false) && !dragging { drawPrompt() }
    }

    /// Thin lines through the pointer, for lining up an area.
    private func drawGuides() {
        guard owner.mode == .region || (owner.mode == .allInOne && owner.hovered == nil),
              NSMouseInRect(owner.pointer, screen.frame, false) else { return }
        let p = CGPoint(x: owner.pointer.x - screen.frame.minX, y: owner.pointer.y - screen.frame.minY)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 0, y: p.y)); path.line(to: CGPoint(x: bounds.maxX, y: p.y))
        path.move(to: CGPoint(x: p.x, y: 0)); path.line(to: CGPoint(x: p.x, y: bounds.maxY))
        path.lineWidth = 1
        NSColor.white.withAlphaComponent(0.45).setStroke()
        path.stroke()
        drawLabel("\(Int(p.x)), \(Int(bounds.height - p.y))", at: CGPoint(x: p.x + 14, y: p.y - 6), centered: false, anchorLeft: true)
    }

    private func drawPrompt() {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        let text = NSAttributedString(string: "\(owner.prompt)  ·  Esc to cancel", attributes: attrs)
        let size = text.size()
        let box = CGRect(x: bounds.midX - size.width / 2 - 14, y: bounds.maxY - 120, width: size.width + 28, height: size.height + 14)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        text.draw(at: CGPoint(x: box.minX + 14, y: box.minY + 7))
    }

    private func drawLabel(_ string: String, at point: CGPoint, centered: Bool, anchorLeft: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        let text = NSAttributedString(string: string, attributes: attrs)
        let size = text.size()
        var box: CGRect
        if centered {
            box = CGRect(x: point.x - size.width / 2 - 6, y: point.y - size.height / 2 - 3, width: size.width + 12, height: size.height + 6)
        } else if anchorLeft {
            box = CGRect(x: point.x, y: point.y - size.height - 4, width: size.width + 10, height: size.height + 4)
        } else {
            box = CGRect(x: point.x - size.width - 10, y: point.y - size.height - 10, width: size.width + 10, height: size.height + 4)
            if box.minY < bounds.minY + 2 { box.origin.y = point.y + 4 }
        }
        box.origin.x = min(max(box.origin.x, 4), bounds.maxX - box.width - 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: box.minX + (centered ? 6 : 5), y: box.minY + (centered ? 3 : 2)))
    }

    // MARK: Events

    private func global(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x + screen.frame.minX, y: p.y + screen.frame.minY)
    }

    override func mouseMoved(with event: NSEvent) { owner.pointerMoved(to: global(event)) }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        start = convert(event.locationInWindow, from: nil)
        current = start
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard owner.mode == .allInOne || owner.mode == .region, let start else { return }
        let p = convert(event.locationInWindow, from: nil)
        current = CGPoint(x: min(max(p.x, 0), bounds.maxX), y: min(max(p.y, 0), bounds.maxY))
        if !dragging, hypot(current!.x - start.x, current!.y - start.y) > 4 { dragging = true }
        owner.pointerMoved(to: global(event))
    }

    override func mouseUp(with event: NSEvent) {
        defer { start = nil; current = nil; dragging = false }
        if let rect = dragRect {
            guard rect.width >= 3, rect.height >= 3 else { return owner.finish(nil) }
            return finishRegion(rect)
        }
        switch owner.mode {
        case .allInOne, .window:
            if let window = owner.hovered { owner.finish(.window(window)) }
            else if owner.mode == .allInOne { finishScreen() }
        case .fixedSize:
            finishRegion(owner.fixedFrame(in: screen))
        case .screen:
            finishScreen()
        case .region:
            break
        }
    }

    private func finishRegion(_ rect: CGRect) {
        let topLeftRect = CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
        guard let cropped = image.crop(points: topLeftRect, displaySize: screen.frame.size) else { return owner.finish(nil) }
        owner.finish(.region(ScreenRegion(displayID: screen.displayID, rect: topLeftRect), image: cropped,
                             globalFrame: rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)))
    }

    private func finishScreen() {
        owner.finish(.screen(screen.displayID, image: image, globalFrame: screen.frame))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: owner.finish(nil) // Esc
        case 36, 76: // Return, Enter: the whole screen under the pointer
            if owner.mode == .allInOne || owner.mode == .screen {
                if NSMouseInRect(owner.pointer, screen.frame, false) { finishScreen() }
                else { (NSApp.windows.compactMap { $0.contentView as? OverlayView }.first { $0.containsPointer })?.finishScreen() }
            }
        default: super.keyDown(with: event)
        }
    }

    fileprivate var containsPointer: Bool { NSMouseInRect(owner.pointer, screen.frame, false) }

    override func cancelOperation(_ sender: Any?) { owner.finish(nil) }
    override func rightMouseDown(with event: NSEvent) { owner.finish(nil) }
}
