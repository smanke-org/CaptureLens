import AppKit

/// A short rounded note that floats above everything, which clicks pass through:
/// "Saved to the library", "That window has closed", and so on.
@MainActor
final class Notice {
    static let shared = Notice()

    private let panel: NSPanel
    private let background = NSView()
    private let label = NSTextField(labelWithString: "")
    private var fadeTimer: Timer?
    private var generation = 0

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let content = NSView()
        content.wantsLayer = true
        panel.contentView = content
        background.wantsLayer = true
        background.layer?.cornerCurve = .continuous
        background.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.88).cgColor
        content.addSubview(background)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        background.addSubview(label)
    }

    /// Shows `text` just below `near` (a global rect such as the selection), or near the
    /// bottom of the screen with the pointer.
    func show(_ text: String, symbol: String = "checkmark.circle.fill", tint: NSColor = .systemGreen,
              near: CGRect? = nil, duration: TimeInterval = 1.6) {
        guard Preferences.shared.showNotice || tint == .systemOrange || tint == .systemRed else { return }
        let fontSize: CGFloat = 14
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let string = NSMutableAttributedString()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: fontSize, weight: .semibold).applying(.init(paletteColors: [tint]))) {
            let attachment = NSTextAttachment()
            attachment.image = image
            string.append(NSAttributedString(attachment: attachment))
            string.append(NSAttributedString(string: "  "))
        }
        string.append(NSAttributedString(string: text))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        string.addAttributes([.font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph],
                             range: NSRange(location: 0, length: string.length))
        label.attributedStringValue = string

        let screen = screenFor(near)
        let maxText = min(520, screen.visibleFrame.width - 80)
        let measured = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: maxText, height: 200)) ?? string.size()
        let textSize = NSSize(width: min(ceil(measured.width) + 2, maxText), height: ceil(measured.height))
        let padX: CGFloat = 16, padY: CGFloat = 9
        let size = NSSize(width: textSize.width + padX * 2, height: textSize.height + padY * 2)

        var origin: NSPoint
        if let near {
            origin = NSPoint(x: near.midX - size.width / 2, y: near.minY - size.height - 10)
            if origin.y < screen.visibleFrame.minY + 8 { origin.y = near.maxY + 10 }
            if origin.y + size.height > screen.visibleFrame.maxY { origin.y = near.midY - size.height / 2 }
        } else {
            origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.minY + 90)
        }
        origin.x = min(max(origin.x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)

        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        background.frame = NSRect(origin: .zero, size: size)
        background.layer?.cornerRadius = min(size.height / 2, 18)
        label.frame = NSRect(x: padX, y: padY, width: size.width - padX * 2, height: textSize.height)
        panel.contentView?.needsDisplay = true
        panel.displayIfNeeded()

        generation += 1
        let shown = generation
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.3
                    self.panel.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        guard self.generation == shown else { return }
                        self.panel.orderOut(nil)
                    }
                })
            }
        }
    }

    func show(error text: String, near: CGRect? = nil) {
        show(text, symbol: "exclamationmark.triangle.fill", tint: .systemOrange, near: near, duration: 2.2)
    }

    private func screenFor(_ rect: CGRect?) -> NSScreen {
        let point = rect.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

/// Feedback sounds.
@MainActor
enum Sounds {
    static func success() {
        guard Preferences.shared.playSound else { return }
        NSSound(named: "Pop")?.play()
    }

    static func tick() {
        guard Preferences.shared.playSound else { return }
        NSSound(named: "Tink")?.play()
    }

    static func failure() {
        guard Preferences.shared.playSound else { return }
        NSSound(named: "Basso")?.play()
    }

    /// The camera shutter macOS plays for its own screenshots.
    static func shutter() {
        guard Preferences.shared.playSound else { return }
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        if let sound = NSSound(contentsOfFile: path, byReference: true) { sound.play() } else { NSSound(named: "Pop")?.play() }
    }
}
