import AppKit
import CaptureLensKit
import ScreenCaptureKit

/// The Screen Recording permission ScreenCaptureKit needs.
enum ScreenAccess {
    static var granted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards macOS only lists the app in
    /// System Settings, so the caller should offer to open it.
    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Explains what to do when capture is refused. Only called from something the user did.
    @MainActor
    static func explainDenied() {
        let alert = NSAlert()
        alert.messageText = "CaptureLens needs Screen Recording access"
        alert.informativeText = "CaptureLens takes pictures of your screen, which macOS only allows once you switch CaptureLens on in System Settings › Privacy & Security › Screen & System Audio Recording. Captures stay in your library on this Mac (and your other Macs, if you sync)."
        alert.addButton(withTitle: "Not Now")
        let open = alert.addButton(withTitle: "Open System Settings")
        open.keyEquivalent = ""
        alert.layout()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
        if alert.runModal() == .alertSecondButtonReturn { openSettings() }
    }
}

struct GrabError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Pictures of the screen through ScreenCaptureKit, always leaving out CaptureLens's own
/// windows (the selection overlay, the countdown, the preview).
enum ScreenGrabber {
    /// A picture of one window on its own, even where other windows cover it, at full
    /// pixel resolution. `shadow` keeps the drop shadow around it, on transparency.
    /// Also returns the area the picture covers, in global Cocoa coordinates (bigger than the
    /// window with its shadow).
    static func captureWindow(_ windowID: CGWindowID, shadow: Bool) async throws -> (CGImage, CGRect) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw GrabError(message: "That window has closed.")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.ignoreShadowsSingleWindow = !shadow
        config.showsCursor = false
        config.captureResolution = .best
        config.shouldBeOpaque = false
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int(filter.contentRect.width * scale))
        config.height = max(1, Int(filter.contentRect.height * scale))
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        // contentRect is in global display coordinates, origin at the top left of the main display.
        let r = filter.contentRect
        let mainHeight = await MainActor.run { NSScreen.screens.first?.frame.height ?? 0 }
        return (image, CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height))
    }

    /// One display, as it is now.
    static func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw GrabError(message: "That display is no longer connected.")
        }
        let own = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(display.frame.width * scale)
        config.height = Int(display.frame.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// A picture of every display, keyed by display ID, at full pixel resolution.
    static func captureAllScreens() async throws -> [CGDirectDisplayID: CGImage] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let own = content.applications.filter { $0.processID == getpid() }
        var images: [CGDirectDisplayID: CGImage] = [:]
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(display.frame.width * scale)
            config.height = Int(display.frame.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            images[display.displayID] = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
        return images
    }

}

/// An area of one screen the user picked.
struct ScreenRegion: Codable, Equatable {
    var displayID: CGDirectDisplayID
    /// In the display's points, origin at its top left (ScreenCaptureKit's convention).
    var rect: CGRect

    @MainActor var screen: NSScreen? { NSScreen.screens.first { $0.displayID == displayID } }

    /// The same area in Cocoa's global coordinates (origin at the bottom left of the main
    /// screen), for placing windows around it.
    @MainActor var globalFrame: CGRect? {
        guard let screen else { return nil }
        return CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    /// The same area of the live screen, cropped from a fresh picture of its display.
    func capture() async throws -> CGImage {
        let full = try await ScreenGrabber.captureDisplay(displayID)
        guard let crop = full.crop(points: rect, displaySize: await MainActor.run { screen?.frame.size }) else {
            throw GrabError(message: "That area is no longer on screen.")
        }
        return crop
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

extension CGImage {
    /// The part of a whole-display picture covering `points` (display points, origin top left).
    func crop(points: CGRect, displaySize: CGSize?) -> CGImage? {
        guard let displaySize, displaySize.width > 0 else { return nil }
        let sx = CGFloat(width) / displaySize.width, sy = CGFloat(height) / displaySize.height
        let pixels = CGRect(x: points.minX * sx, y: points.minY * sy, width: points.width * sx, height: points.height * sy)
            .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !pixels.isEmpty else { return nil }
        return cropping(to: pixels)
    }

    /// Vision reads small text far better when it is a few dozen pixels tall, so a
    /// one-line selection is enlarged before reading.
    func upscaledForReading(minHeight: Int = 120) -> CGImage {
        guard height < minHeight else { return self }
        let factor = min(4, Int(ceil(Double(minHeight) / Double(max(height, 1)))))
        guard factor > 1,
              let context = CGContext(data: nil, width: width * factor, height: height * factor, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return self }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width * factor, height: height * factor))
        context.draw(self, in: CGRect(x: 0, y: 0, width: width * factor, height: height * factor))
        return context.makeImage() ?? self
    }

    /// A copy no larger than `maxSide` pixels on its longer side, for library thumbnails.
    func thumbnail(maxSide: Int = 480) -> CGImage {
        let longest = max(width, height)
        guard longest > maxSide else { return self }
        let scale = Double(maxSide) / Double(longest)
        let w = max(1, Int(Double(width) * scale)), h = max(1, Int(Double(height) * scale))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return self }
        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? self
    }

    var pngData: Data? {
        NSBitmapImageRep(cgImage: self).representation(using: .png, properties: [:])
    }
}

/// The mouse pointer at the moment of a capture, for the separate cursor layer.
struct CursorSnapshot {
    let png: Data
    /// In points.
    let size: CGSize
    /// The pointer's top-left corner in global Cocoa coordinates (origin bottom left).
    let topLeft: CGPoint

    /// What the pointer looks like and where it is right now.
    @MainActor static func current() -> CursorSnapshot? {
        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        let image = cursor.image
        guard image.size.width > 0, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let mouse = NSEvent.mouseLocation
        let hot = cursor.hotSpot
        return CursorSnapshot(png: png, size: image.size, topLeft: CGPoint(x: mouse.x - hot.x, y: mouse.y + hot.y))
    }

    /// As a layer of a capture whose top-left corner is at `origin` (global Cocoa
    /// coordinates) and which is `size` points large; nil if the pointer is outside it.
    func layer(captureTopLeft origin: CGPoint, size captureSize: CGSize, visible: Bool) -> CursorLayer? {
        let x = topLeft.x - origin.x
        let y = origin.y - topLeft.y
        let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        guard frame.intersects(CGRect(origin: .zero, size: captureSize)) else { return nil }
        return CursorLayer(png: png, width: size.width, height: size.height, x: x, y: y, visible: visible)
    }
}

/// A window on screen, front to back, as the window picker sees it.
struct ScreenWindow {
    let id: CGWindowID
    /// In global Cocoa coordinates (origin bottom left of the main screen).
    let frame: CGRect
    let ownerName: String?
    let ownerPID: pid_t
    let title: String?

    /// Ordinary app windows on screen, frontmost first, leaving out CaptureLens's own.
    @MainActor static func onScreen() -> [ScreenWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let own = getpid()
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 40, bounds.height > 30 else { return nil }
            let cocoa = CGRect(x: bounds.minX, y: mainHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            return ScreenWindow(id: id, frame: cocoa, ownerName: info[kCGWindowOwnerName as String] as? String,
                                ownerPID: pid, title: info[kCGWindowName as String] as? String)
        }
    }
}
