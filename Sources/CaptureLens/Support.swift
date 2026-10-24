import AppKit
import CaptureLensKit
import Observation
import SwiftUI

/// What CaptureLens is doing right now, so an automatic update waits for a quiet moment.
@Observable
@MainActor
final class Activity {
    static let shared = Activity()
    private(set) var lastActive = Date.distantPast

    func touch() { lastActive = Date() }

    var busyReason: String? {
        if CaptureOverlay.shared.isSelecting { return "a capture is being taken" }
        if CaptureEngine.shared.isCounting { return "a capture is counting down" }
        if ScrollCapture.shared.isRunning { return "a scrolling capture is under way" }
        if StepRecorder.shared.isRecording { return "steps are being recorded" }
        if ScreenRecorder.shared.isActive { return "a video is being recorded" }
        if !LibraryStore.shared.analyzing.isEmpty { return "a capture is being named" }
        if LibraryStore.shared.isResealing { return "the library is being encrypted" }
        return nil
    }
}

/// Putting captures on the clipboard.
@MainActor
enum Clipboard {
    /// The picture as PNG and TIFF, for apps that only take one of them.
    static func copy(png: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pasteboard.writeObjects([item])
    }

    static func copy(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// A floating panel that hosts SwiftUI and doesn't steal focus until clicked.
@MainActor
class FloatingPanel: NSPanel {
    init(title: String, size: CGSize, resizable: Bool = true) {
        var style: NSWindow.StyleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        self.title = title
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { true }

    /// Shows SwiftUI content, sized to fit it, so placement works with the real size.
    func host<V: View>(_ view: V) {
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        contentViewController = hosting
        let fitting = hosting.view.fittingSize
        if fitting.width > 10 && fitting.height > 10 { setContentSize(fitting) }
    }

    /// Puts the panel beside `anchor` (a global rect) without covering it: below if there
    /// is room, else above, else to the right or left.
    func place(near anchor: CGRect?) {
        let size = frame.size
        let point = anchor.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var origin: CGPoint
        if let anchor {
            let gap: CGFloat = 12
            if anchor.minY - gap - size.height >= visible.minY {
                origin = CGPoint(x: anchor.minX, y: anchor.minY - gap - size.height)
            } else if anchor.maxY + gap + size.height <= visible.maxY {
                origin = CGPoint(x: anchor.minX, y: anchor.maxY + gap)
            } else if anchor.maxX + gap + size.width <= visible.maxX {
                origin = CGPoint(x: anchor.maxX + gap, y: anchor.maxY - size.height)
            } else {
                origin = CGPoint(x: anchor.minX - gap - size.width, y: anchor.maxY - size.height)
            }
        } else {
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrameOrigin(origin)
    }
}

extension NSScreen {
    /// `size` for a window's content, made smaller where the main screen (less the menu
    /// bar, the Dock and room for a title bar and toolbar) can't fit it: a 13-inch
    /// MacBook Air has about 870 points of height to give.
    @MainActor static func fitting(_ size: NSSize, chrome: CGFloat = 90) -> NSSize {
        guard let visible = NSScreen.main?.visibleFrame else { return size }
        return NSSize(width: min(size.width, visible.width - 40), height: min(size.height, visible.height - chrome))
    }
}
