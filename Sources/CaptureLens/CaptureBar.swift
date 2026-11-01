import AppKit
import SwiftUI

/// The capture bar: capture buttons floating above every window, on every Space and over
/// full-screen apps, while it's turned on (the menus, Settings › Capture, its shortcut or
/// `snaganything://capturebar`). It steps aside as soon as any capture starts, however it
/// was started, and comes back once the capture is saved or cancelled. Captures leave out
/// SnagAnything's own windows, so it never shows in a picture either way.
@MainActor
final class CaptureBar: NSObject, NSWindowDelegate {
    static let shared = CaptureBar()

    private var panel: CaptureBarPanel?
    private var showWork: DispatchWorkItem?
    private var saveWork: DispatchWorkItem?
    /// The bar is being put in place by SnagAnything, not dragged.
    private var placing = false
    /// The position this Mac saved last, so it isn't mistaken for one from another Mac.
    private var savedPosition: CaptureBarPosition?
    private var started = false

    /// The name of the button under the pointer, in a panel of its own beside the bar.
    private var labelPanel: NSPanel?
    private var labelHost: NSHostingController<BarLabelView>?
    /// The button the label is for, or is about to be for.
    private var labelOwner: UUID?
    private var labelWork: DispatchWorkItem?

    func start() {
        guard !started else { return }
        started = true
        observePreferences()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CaptureBar.shared.place() }
        }
        refresh()
    }

    func toggle() { Preferences.shared.showCaptureBar.toggle() }

    /// A capture of any kind is under way, from its countdown or overlay until it's saved,
    /// cancelled or the recording stops.
    private var captureUnderway: Bool {
        CaptureEngine.shared.isBusy || CaptureOverlay.shared.isSelecting || ScreenRecorder.shared.isActive
            || StepRecorder.shared.isRecording || ScrollCapture.shared.isRunning
    }

    /// Hides the bar the moment a capture starts; shows it again a moment after the last one
    /// ends (so a capture handing over to the next step, a pick turning into a scrolling
    /// capture, say, doesn't flash it).
    func refresh() {
        guard started else { return }
        showWork?.cancel()
        showWork = nil
        guard Preferences.shared.showCaptureBar, !captureUnderway else {
            hideLabel()
            panel?.orderOut(nil)
            return
        }
        guard panel?.isVisible != true else { return }
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let bar = CaptureBar.shared
                bar.showWork = nil
                guard Preferences.shared.showCaptureBar, !bar.captureUnderway else { return }
                bar.show()
            }
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func show() {
        if panel == nil {
            let panel = CaptureBarPanel()
            panel.delegate = self
            let hosting = NSHostingController(rootView: CaptureBarView())
            hosting.sizingOptions = [.preferredContentSize]
            panel.contentViewController = hosting
            panel.setContentSize(hosting.view.fittingSize)
            self.panel = panel
        }
        applyLook()
        place()
        panel?.orderFrontRegardless()
    }

    // MARK: Position

    /// Puts the bar where the saved position says, inside its screen's free space. The first
    /// time, that's the top middle of the main screen, under the menu bar.
    func place() {
        guard let panel else { return }
        let position = Preferences.shared.captureBarPosition
        guard let screen = position.flatMap({ p in NSScreen.screens.first { $0.localizedName == p.screen } })
            ?? NSScreen.screens.first else { return }
        let free = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = panel.frame.size
        let origin = CGPoint(x: free.minX + max(0, free.width - size.width) * (position?.x ?? 0.5),
                             y: free.minY + max(0, free.height - size.height) * (position?.y ?? 1))
        placing = true
        panel.setFrameOrigin(CGPoint(x: origin.x.rounded(), y: origin.y.rounded()))
        placing = false
    }

    /// Keeps where the bar was dragged to, as fractions of its screen's free space, then pulls
    /// it fully back onto that screen if it was left hanging off an edge.
    private func savePosition() {
        guard let panel else { return }
        let frame = panel.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? panel.screen else { return }
        let free = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        func fraction(_ value: CGFloat, _ start: CGFloat, _ room: CGFloat) -> Double {
            room <= 0 ? 0.5 : (Double((value - start) / room) * 1000).rounded() / 1000
        }
        let x = min(1, max(0, fraction(frame.minX, free.minX, free.width - frame.width)))
        let y = min(1, max(0, fraction(frame.minY, free.minY, free.height - frame.height)))
        let position = CaptureBarPosition(screen: screen.localizedName, x: x, y: y)
        savedPosition = position
        Preferences.shared.captureBarPosition = position
        place()
    }

    /// Called once a drag of the grip ends.
    func dragEnded() {
        saveWork?.cancel()
        saveWork = nil
        savePosition()
    }

    func windowDidMove(_ notification: Notification) {
        guard !placing else { return }
        hideLabel()
        // Moved some other way (a Space or screen change): keep it, once it settles.
        saveWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { CaptureBar.shared.dragEnded() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Turned on its side, a new size, or a preset added: the new size keeps the same spot.
    func windowDidResize(_ notification: Notification) {
        hideLabel()
        place()
    }

    /// Follows the settings, including ones arriving from another Mac.
    private func observePreferences() {
        withObservationTracking {
            let prefs = Preferences.shared
            _ = prefs.showCaptureBar
            _ = prefs.captureBarLayout
            _ = prefs.captureBarPosition
            _ = prefs.captureBarLook
        } onChange: {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let bar = CaptureBar.shared
                    bar.applyLook()
                    bar.refresh()
                    if Preferences.shared.captureBarPosition != bar.savedPosition { bar.place() }
                    bar.observePreferences()
                }
            }
        }
    }

    /// Light or Dark whatever the app's look, or nil to follow it. The label matches the bar.
    private func applyLook() {
        let appearance = Preferences.shared.captureBarLook.nsAppearance
        panel?.appearance = appearance
        labelPanel?.appearance = appearance
    }

    // MARK: Hover labels

    /// The pointer came onto a button (`frame`: where it is in the bar, from the top left).
    /// The first label waits a moment, like a tooltip; moving along the bar, the next one
    /// follows straight away.
    func hoverBegan(_ owner: UUID, title: String, shortcut: String?, frame: CGRect) {
        labelWork?.cancel()
        labelOwner = owner
        let showing = labelPanel?.isVisible == true
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let bar = CaptureBar.shared
                guard bar.labelOwner == owner else { return }
                bar.showLabel(title: title, shortcut: shortcut, frame: frame)
            }
        }
        labelWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (showing ? 0 : 0.35), execute: work)
    }

    /// The pointer left a button: the label goes, unless it's moved straight onto another.
    func hoverEnded(_ owner: UUID) {
        guard labelOwner == owner else { return }
        labelOwner = nil
        labelWork?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let bar = CaptureBar.shared
                if bar.labelOwner == nil { bar.hideLabel() }
            }
        }
        labelWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func hideLabel() {
        labelWork?.cancel()
        labelWork = nil
        labelOwner = nil
        labelPanel?.orderOut(nil)
    }

    /// Puts the label outside the bar so it never covers a button: under a horizontal bar
    /// (over it near the bottom of the screen), beside a vertical one (on the left near the
    /// right edge), lined up with the button.
    private func showLabel(title: String, shortcut: String?, frame: CGRect) {
        guard let panel, panel.isVisible, let content = panel.contentView else { return }
        let view = BarLabelView(title: title, shortcut: shortcut)
        if labelPanel == nil {
            let label = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            label.isFloatingPanel = true
            label.level = .statusBar
            label.hidesOnDeactivate = false
            label.isReleasedWhenClosed = false
            label.ignoresMouseEvents = true
            label.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            label.backgroundColor = .clear
            label.isOpaque = false
            label.hasShadow = true
            let host = NSHostingController(rootView: view)
            label.contentViewController = host
            labelPanel = label
            labelHost = host
            applyLook()
        }
        guard let label = labelPanel, let host = labelHost else { return }
        host.rootView = view
        let size = host.view.fittingSize
        label.setContentSize(size)

        // SwiftUI's frame is from the top left of the bar's content.
        let local = content.isFlipped ? frame : CGRect(x: frame.minX, y: content.bounds.height - frame.maxY,
                                                         width: frame.width, height: frame.height)
        let button = panel.convertToScreen(content.convert(local, to: nil))
        let bar = panel.frame
        let screen = (NSScreen.screens.first { $0.frame.contains(CGPoint(x: bar.midX, y: bar.midY)) } ?? panel.screen)?.visibleFrame
            ?? bar.insetBy(dx: -1000, dy: -1000)
        let gap: CGFloat = 6
        var origin: CGPoint
        if Preferences.shared.captureBarLayout == .vertical {
            origin = CGPoint(x: bar.maxX + gap, y: button.midY - size.height / 2)
            if origin.x + size.width > screen.maxX { origin.x = bar.minX - gap - size.width }
            origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        } else {
            origin = CGPoint(x: button.midX - size.width / 2, y: bar.minY - gap - size.height)
            if origin.y < screen.minY { origin.y = bar.maxY + gap }
            origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        }
        label.setFrameOrigin(CGPoint(x: origin.x.rounded(), y: origin.y.rounded()))
        label.orderFrontRegardless()
    }

    // MARK: Menus

    func run(_ preset: CapturePreset) {
        hideLabel()
        CaptureEngine.shared.run(preset)
    }

    /// Every preset, and the other ways to capture, in a menu at the pointer.
    func showCaptureMenu() {
        hideLabel()
        let menu = NSMenu()
        let prefs = Preferences.shared
        for preset in prefs.presets {
            menu.addItem(ActionMenuItem(preset.name, symbol: preset.delay > 0 ? "timer" : preset.mode.symbol,
                                        hotKey: preset.hotKey) { CaptureBar.shared.run(preset) })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Capture Text", symbol: "text.viewfinder", hotKey: prefs.captureTextHotKey) {
            CaptureEngine.shared.captureText()
        })
        let again = ActionMenuItem("Capture Same Area Again", symbol: "arrow.counterclockwise",
                                   hotKey: prefs.captureAgainHotKey) { CaptureEngine.shared.captureAgain() }
        menu.addItem(again)
        menu.addItem(ActionMenuItem("Record Steps…", symbol: "list.number") { StepRecorder.shared.start() })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Right-clicking the grip: color highlighting, the size of the buttons, which way the
    /// bar runs, and its settings.
    func gripMenu() -> NSMenu {
        hideLabel()
        let prefs = Preferences.shared
        let menu = NSMenu()
        let colors = ActionMenuItem("Color Highlighting") { prefs.captureBarColors.toggle() }
        colors.state = prefs.captureBarColors ? .on : .off
        menu.addItem(colors)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Icon Size"))
        for size in CaptureBarSize.allCases {
            let item = ActionMenuItem(size.title) { prefs.captureBarSize = size }
            item.state = prefs.captureBarSize == size ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Appearance"))
        for look in CaptureBarLook.allCases {
            let item = ActionMenuItem(look.title) { prefs.captureBarLook = look }
            item.state = prefs.captureBarLook == look ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Layout"))
        for layout in CaptureBarLayout.allCases {
            let item = ActionMenuItem(layout.title) { prefs.captureBarLayout = layout }
            item.state = prefs.captureBarLayout == layout ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Capture Bar Settings…") { SettingsWindow.shared.show(tab: "Capture") })
        menu.addItem(ActionMenuItem("Hide Capture Bar") { prefs.showCaptureBar = false })
        return menu
    }

    #if DEBUG
    var debugPanel: NSPanel? { panel }
    var debugLabel: String {
        guard let label = labelPanel, label.isVisible else { return "none" }
        let text = [labelHost?.rootView.title, labelHost?.rootView.shortcut].compactMap { $0 }.joined(separator: " ")
        return "'\(text)' \(NSStringFromRect(label.frame))"
    }
    #endif
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, symbol: String? = nil, hotKey: HotKey? = nil, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        if let shortcut = hotKey?.menuKeyEquivalent {
            keyEquivalent = shortcut.key
            keyEquivalentModifierMask = shortcut.mask
        }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

/// A borderless panel that never activates SnagAnything, so clicking a button leaves the
/// app being captured in front.
final class CaptureBarPanel: NSPanel {
    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 300, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        // Above other apps' floating windows, below menus and the capture overlay. (After
        // isFloatingPanel, which sets the level back to .floating.)
        level = .statusBar
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        becomesKeyOnlyIfNeeded = true
        title = "Capture Bar"
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - The bar

/// Design: the Capture button (the first preset, with every other way to capture behind its
/// arrow) in the accent color, then tinted groups: red for video and steps, teal for text,
/// and plain for capturing the same area again and opening the library. With color
/// highlighting off, or in Dark mode (where the tints look muddy), every group is plain gray.
struct CaptureBarView: View {
    @State private var prefs = Preferences.shared
    @Environment(\.colorScheme) private var colorScheme

    private var vertical: Bool { prefs.captureBarLayout == .vertical }
    private var size: CaptureBarSize { prefs.captureBarSize }
    private var stack: AnyLayout { vertical ? AnyLayout(VStackLayout(spacing: 5)) : AnyLayout(HStackLayout(spacing: 5)) }
    private var colored: Bool { prefs.captureBarColors && colorScheme == .light }
    private func tint(_ color: Color) -> Color? { colored ? color : nil }

    var body: some View {
        stack {
            GripHandle(vertical: vertical, size: size)
            CaptureSplitButton(preset: prefs.presets.first, vertical: vertical, size: size, colored: colored)
            BarSegment(tint: tint(.red), vertical: vertical) {
                ForEach(prefs.presets.filter { $0.mode == .recording }) { preset in
                    BarButton(title: preset.name, symbol: "record.circle", hotKey: preset.hotKey, size: size) {
                        CaptureBar.shared.run(preset)
                    }
                }
                BarButton(title: "Record Steps", symbol: "list.number", hotKey: nil, size: size) { StepRecorder.shared.start() }
            }
            BarSegment(tint: tint(.teal), vertical: vertical) {
                BarButton(title: "Capture Text", symbol: "text.viewfinder", hotKey: prefs.captureTextHotKey, size: size) {
                    CaptureEngine.shared.captureText()
                }
            }
            BarSegment(tint: nil, vertical: vertical) {
                BarButton(title: "Capture Same Area Again", symbol: "arrow.counterclockwise", hotKey: prefs.captureAgainHotKey,
                          size: size) { CaptureEngine.shared.captureAgain() }
                BarButton(title: "Open Library", symbol: "photo.on.rectangle", hotKey: prefs.libraryHotKey, size: size) {
                    LibraryWindow.shared.show()
                }
            }
        }
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
        .fixedSize()
        .contextMenu {
            Toggle("Color Highlighting", isOn: $prefs.captureBarColors)
            Picker("Icon Size", selection: $prefs.captureBarSize) {
                ForEach(CaptureBarSize.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Appearance", selection: $prefs.captureBarLook) {
                ForEach(CaptureBarLook.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Layout", selection: $prefs.captureBarLayout) {
                ForEach(CaptureBarLayout.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Divider()
            Button("Capture Bar Settings…") { SettingsWindow.shared.show(tab: "Capture") }
            Button("Hide Capture Bar") { prefs.showCaptureBar = false }
        }
    }
}

/// The name (and shortcut) of the button under the pointer.
struct BarLabelView: View {
    let title: String
    let shortcut: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            if let shortcut {
                Text(shortcut).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
        .fixedSize()
    }
}

/// Shows the bar's own label beside it while the pointer is over this button, in place of
/// a tooltip (which would sit on top of the button).
private struct BarLabel: ViewModifier {
    let title: String
    let shortcut: String?
    @State private var id = UUID()
    @State private var frame = CGRect.zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .onHover { inside in
                if inside {
                    CaptureBar.shared.hoverBegan(id, title: title, shortcut: shortcut, frame: frame)
                } else {
                    CaptureBar.shared.hoverEnded(id)
                }
            }
            .accessibilityLabel(title)
    }
}

extension View {
    fileprivate func barLabel(_ title: String, _ hotKey: HotKey? = nil) -> some View {
        modifier(BarLabel(title: title, shortcut: hotKey?.display))
    }
}

/// Drag here to move the bar; right-click for its options.
private struct GripHandle: View {
    let vertical: Bool
    let size: CaptureBarSize

    var body: some View {
        let dots = Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                GridRow {
                    Circle().frame(width: 2.5, height: 2.5)
                    Circle().frame(width: 2.5, height: 2.5)
                }
            }
        }
        .foregroundStyle(.tertiary)
        dots
            .rotationEffect(.degrees(vertical ? 90 : 0))
            .frame(width: vertical ? size.button : 12, height: vertical ? 12 : size.button)
            .overlay(WindowDragArea())
            .barLabel("Drag to move · right-click for options")
    }
}

/// Moves the window with the pointer, and remembers where it was left. Right-click (or
/// ⌃-click) opens the bar's options.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { return showMenu(event) }
            CaptureBar.shared.hideLabel()
            window?.performDrag(with: event)
            CaptureBar.shared.dragEnded()
        }
        override func rightMouseDown(with event: NSEvent) { showMenu(event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        private func showMenu(_ event: NSEvent) {
            NSMenu.popUpContextMenu(CaptureBar.shared.gripMenu(), with: event, for: self)
        }
    }
}

/// The first preset, with the menu of every other way to capture behind its arrow.
private struct CaptureSplitButton: View {
    let preset: CapturePreset?
    let vertical: Bool
    let size: CaptureBarSize
    let colored: Bool
    @State private var hoverMain = false
    @State private var hoverMenu = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let stack = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        let tint = colored ? Color.accentColor : Color.primary
        stack {
            Button {
                if let preset { CaptureBar.shared.run(preset) }
            } label: {
                Group {
                    if vertical {
                        Image(systemName: "camera.viewfinder").font(.system(size: size.icon + 1, weight: .medium))
                            .frame(width: size.button, height: size.button - 2)
                    } else {
                        Label(preset?.name ?? "Capture", systemImage: "camera.viewfinder")
                            .font(.system(size: size.text, weight: .medium))
                            .padding(.horizontal, size.button * 0.36)
                            .frame(height: size.button)
                    }
                }
                .background(tint.opacity(hoverMain ? 0.12 : 0))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoverMain = $0 }
            .barLabel(preset?.name ?? "Capture", preset?.hotKey)

            Rectangle()
                .fill(tint.opacity(colored ? 0.35 : 0.18))
                .frame(width: vertical ? size.button * 0.7 : 0.5, height: vertical ? 0.5 : size.button * 0.65)

            Button {
                CaptureBar.shared.showCaptureMenu()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: size.icon * 0.67, weight: .semibold))
                    .frame(width: vertical ? size.button : size.button * 0.78, height: vertical ? size.button * 0.65 : size.button)
                    .background(tint.opacity(hoverMenu ? 0.12 : 0))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoverMenu = $0 }
            .barLabel("All presets and more")
        }
        // Black on the tint (white in Dark mode); the color stays in the background.
        .foregroundStyle(Color.primary)
        .background(tint.opacity(colored ? 0.13 : 0.05), in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(tint.opacity(colored ? 0.35 : 0.14), lineWidth: 0.5))
    }
}

/// A group of buttons on a faint tint of its color.
private struct BarSegment<Content: View>: View {
    let tint: Color?
    let vertical: Bool
    @ViewBuilder let content: Content

    var body: some View {
        let stack = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        stack { content }
            .padding(1)
            .foregroundStyle(Color.primary)
            .background((tint ?? Color.primary).opacity(tint == nil ? 0.05 : 0.12),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct BarButton: View {
    let title: String
    let symbol: String
    let hotKey: HotKey?
    let size: CaptureBarSize
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            CaptureBar.shared.hideLabel()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size.icon))
                .frame(width: size.button, height: size.button)
                .background(Color.primary.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .barLabel(title, hotKey)
    }
}
