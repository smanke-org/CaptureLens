import AppKit
import ApplicationServices
import CaptureLensKit
import ScreenCaptureKit
import SwiftUI

/// Captures something longer than the screen: a web page, a long list, a document. After
/// picking the area (or window), you scroll it, or CaptureLens scrolls it for you, and the
/// frames are stitched into one tall picture (see `ScrollStitcher`).
@Observable
@MainActor
final class ScrollCapture {
    static let shared = ScrollCapture()

    private(set) var isRunning = false
    private(set) var height = 0
    private(set) var frames = 0
    private(set) var autoScrolling = false
    private(set) var note: String?

    @ObservationIgnored private var camera: RegionCamera?
    @ObservationIgnored private var worker: StitchWorker?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var panel: FloatingPanel?
    @ObservationIgnored private var outline: NSWindow?
    @ObservationIgnored private var finishWith: ((CGImage?) -> Void)?
    @ObservationIgnored private var unchangedInARow = 0
    @ObservationIgnored private var region: ScreenRegion?
    @ObservationIgnored private var globalFrame: CGRect = .zero

    /// Starts capturing `region` (also given as `frame`, global Cocoa coordinates). `done`
    /// gets the stitched picture, or nil if cancelled.
    func start(region: ScreenRegion, frame: CGRect, done: @escaping (CGImage?) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        height = 0
        frames = 0
        note = nil
        autoScrolling = false
        unchangedInARow = 0
        self.region = region
        globalFrame = frame
        finishWith = done
        camera = RegionCamera(displayID: region.displayID, sourceRect: region.rect)
        worker = StitchWorker()
        showOutline(frame)
        showPanel(near: frame)
        loop = Task { await run() }
    }

    private func run() async {
        while isRunning, let camera, let worker {
            do {
                let image = try await camera.capture()
                let result = await worker.add(image)
                frames += 1
                height = await worker.height
                switch result {
                case .unchanged:
                    unchangedInARow += 1
                    // Scrolling for you and nothing moves any more: the end of the page.
                    if autoScrolling && unchangedInARow >= 3 { return finish() }
                case .full:
                    note = "That's as tall as a capture can be."
                    return finish()
                case .lost:
                    note = "Scrolled too fast to follow. Scroll back a little."
                    unchangedInARow = 0
                default:
                    unchangedInARow = 0
                    if note != nil { note = nil }
                }
                if autoScrolling { scrollStep() }
            } catch {
                note = "Couldn't capture the area: \(error.localizedDescription)"
            }
            try? await Task.sleep(for: .milliseconds(autoScrolling ? 260 : 110))
        }
    }

    // MARK: Scrolling for you

    var canScrollForYou: Bool { AXIsProcessTrusted() }

    func toggleAutoScroll() {
        if autoScrolling { autoScrolling = false; return }
        guard canScrollForYou else {
            // macOS shows its prompt and lists CaptureLens in Privacy & Security.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            note = "Allow CaptureLens in Privacy & Security, then press Scroll for Me again. Or scroll yourself."
            return
        }
        // Scroll events go to whatever is under the pointer, so it moves to the middle of the area.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: globalFrame.midX, y: mainHeight - globalFrame.midY))
        unchangedInARow = 0
        autoScrolling = true
    }

    private func scrollStep() {
        // Less than the area's height, so each frame overlaps the last.
        let step = Int32(max(40, globalFrame.height * 0.45))
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -step, wheel2: 0, wheel3: 0)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        event?.location = CGPoint(x: globalFrame.midX, y: mainHeight - globalFrame.midY)
        event?.post(tap: .cghidEventTap)
    }

    // MARK: Ending

    func finish() {
        guard isRunning else { return }
        isRunning = false
        autoScrolling = false
        loop?.cancel()
        let worker = self.worker
        let done = finishWith
        tearDown()
        Task {
            let image = await worker?.image()
            done?(image)
        }
    }

    func cancel() {
        guard isRunning else { return }
        isRunning = false
        autoScrolling = false
        loop?.cancel()
        let done = finishWith
        tearDown()
        done?(nil)
    }

    private func tearDown() {
        panel?.orderOut(nil)
        outline?.orderOut(nil)
        panel = nil
        outline = nil
        camera = nil
        worker = nil
        finishWith = nil
    }

    // MARK: On screen

    /// A dashed frame around the area. CaptureLens's own windows are left out of every
    /// picture, so it never shows up in the capture.
    private func showOutline(_ frame: CGRect) {
        let window = NSWindow(contentRect: frame.insetBy(dx: -3, dy: -3), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = OutlineView()
        window.orderFrontRegardless()
        outline = window
    }

    private func showPanel(near frame: CGRect) {
        let panel = FloatingPanel(title: "Scrolling Capture", size: CGSize(width: 320, height: 120), resizable: false)
        panel.host(ScrollPanelView())
        panel.place(near: frame)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private final class OutlineView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 3
            path.setLineDash([8, 5], count: 2, phase: 0)
            NSColor.systemBlue.setStroke()
            path.stroke()
        }
    }
}

private struct ScrollPanelView: View {
    @State private var session = ScrollCapture.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.autoScrolling ? "Scrolling for you… it stops at the end." : "Scroll down slowly over the outlined area.")
                .font(.callout.weight(.medium))
            Text(session.frames == 0 ? "Starting…" : "\(session.height.formatted()) pixels tall so far")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if let note = session.note {
                Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(session.autoScrolling ? "Stop Scrolling" : "Scroll for Me") { session.toggleAutoScroll() }
                    .help(session.canScrollForYou ? "CaptureLens scrolls the area and stops at the end"
                          : "Needs your permission in Privacy & Security to send scroll events")
                Spacer()
                Button("Cancel") { session.cancel() }
                Button("Done") { session.finish() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// The stitcher on its own thread, so matching frames never holds up the screen.
actor StitchWorker {
    private let stitcher = ScrollStitcher()
    private var firstHeight = 0

    func add(_ image: CGImage) -> ScrollStitcher.Result {
        if firstHeight == 0 { firstHeight = image.height }
        return stitcher.add(image)
    }

    /// How tall the picture is so far, in pixels.
    var height: Int { max(stitcher.contentHeight, firstHeight) }
    func image() -> CGImage? { stitcher.image() }
}

/// Repeated pictures of one area of a display, leaving out CaptureLens's own windows.
final class RegionCamera: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    /// The area in the display's points, origin at its top left.
    let sourceRect: CGRect
    private var filter: SCContentFilter?

    init(displayID: CGDirectDisplayID, sourceRect: CGRect) {
        self.displayID = displayID
        self.sourceRect = sourceRect
    }

    /// Pixels per point of the display, once known.
    private(set) var scale: CGFloat = 2

    func capture() async throws -> CGImage {
        if filter == nil {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw GrabError(message: "That display is no longer connected.")
            }
            let own = content.applications.filter { $0.processID == getpid() }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        }
        guard let filter else { throw GrabError(message: "That display is no longer connected.") }
        let config = SCStreamConfiguration()
        scale = CGFloat(filter.pointPixelScale)
        config.sourceRect = sourceRect
        config.width = max(1, Int(sourceRect.width * scale))
        config.height = max(1, Int(sourceRect.height * scale))
        config.showsCursor = false
        config.captureResolution = .best
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            self.filter = nil
            throw error
        }
    }
}
