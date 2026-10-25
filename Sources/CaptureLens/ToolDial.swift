import AppKit
import CaptureLensKit
import Observation
import SwiftUI

// MARK: - The floating toolbar

/// Where the floating toolbar sits over the picture; it's dragged there by its grip.
enum PalettePlacement: String, CaseIterable {
    case left, right, bottom

    var title: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .bottom: "Bottom"
        }
    }
}

/// The markup tools floating over the picture, on its left, right or bottom edge. Drag the
/// grip to move it; it stays where it's put.
struct FloatingToolPalette: View {
    @AppStorage("editor.palettePlacement", store: AppDefaults.store) private var placementRaw = PalettePlacement.left.rawValue
    @State private var drag: CGSize = .zero

    private var placement: PalettePlacement { PalettePlacement(rawValue: placementRaw) ?? .left }

    var body: some View {
        GeometryReader { geo in
            let horizontal = placement == .bottom
            Group {
                if horizontal {
                    HStack(spacing: 0) { grip(geo.size, horizontal: true); ToolPalette(horizontal: true) }
                } else {
                    VStack(spacing: 0) { grip(geo.size, horizontal: false); ToolPalette() }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
            .offset(drag)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(10)
        }
        .coordinateSpace(name: "palette-area")
    }

    private var alignment: Alignment {
        switch placement {
        case .left: .leading
        case .right: .trailing
        case .bottom: .bottom
        }
    }

    /// The handle: drag it toward an edge to move the toolbar there.
    private func grip(_ area: CGSize, horizontal: Bool) -> some View {
        Image(systemName: horizontal ? "line.3.horizontal" : "line.3.horizontal")
            .rotationEffect(.degrees(horizontal ? 90 : 0))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: horizontal ? 18 : 92, height: horizontal ? 60 : 16)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .named("palette-area"))
                    .onChanged { drag = $0.translation }
                    .onEnded { value in
                        let p = value.location
                        let edge: PalettePlacement = p.y > area.height * 0.72 ? .bottom : (p.x < area.width / 2 ? .left : .right)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            placementRaw = edge.rawValue
                            drag = .zero
                        }
                    }
            )
            .contextMenu {
                ForEach(PalettePlacement.allCases, id: \.self) { edge in
                    Button("Move to the \(edge.title)") { placementRaw = edge.rawValue }
                }
            }
            .help("Drag to move the toolbar to the left, right or bottom of the picture")
            .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
    }
}

/// With the dial chosen: which tool is in use, and how to open the dial (a click here opens it too).
struct DialHint: View {
    @State private var editor = AnnotationEditor.shared
    @State private var prefs = Preferences.shared

    var body: some View {
        Button {
            NotificationCenter.default.post(name: ZoomingScrollView.openDialNotification, object: nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: editor.tool.symbol)
                Text(editor.tool.title).fontWeight(.medium)
                Text("·").foregroundStyle(.secondary)
                Text(prefs.dialTrigger.hint).foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .help("Open the tool dial")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(12)
    }
}

extension DialTrigger {
    var hint: String {
        switch self {
        case .rightClick: "Right-click for tools"
        case .commandOption: "Hold ⌘⌥ for tools"
        case .either: "Right-click or hold ⌘⌥ for tools"
        }
    }
}

// MARK: - The dial

/// What the open dial shares with its scroll view: the tool under the pointer (picked when
/// ⌘⌥ is let go) and how to close it.
@Observable
@MainActor
final class ToolDialState {
    var hovered: AnnotationEditor.Tool?
    /// Opened by holding ⌘⌥: letting go picks the tool under the pointer.
    var held = false
    @ObservationIgnored var close: () -> Void = {}
}

/// The tools in rings around the pointer: the ones used most on the inside, the rest
/// around them, colors closest to the middle and line widths underneath. The middle shows
/// the tool in use; clicking it closes the dial.
struct ToolDialView: View {
    let state: ToolDialState
    @State private var editor = AnnotationEditor.shared

    static let size = CGSize(width: 404, height: 452)
    private static let center = CGPoint(x: 202, y: 202)
    private static let innerCount = 8

    private enum Action: Hashable { case rotateLeft, rotateRight, smartRedact, simplify, adjust }

    var body: some View {
        let ranked = ToolUse.ranked()
        let inner = Array(ranked.prefix(Self.innerCount))
        let outer = Array(ranked.dropFirst(Self.innerCount))
        let actions: [Action] = [.rotateLeft, .rotateRight, .adjust, .smartRedact, .simplify]
        let outerCount = outer.count + actions.count
        ZStack(alignment: .topLeading) {
            Circle()
                .fill(.regularMaterial)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
                .frame(width: 396, height: 396)
                .position(Self.center)
            Circle()
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                .frame(width: 282, height: 282)
                .position(Self.center)

            ForEach(Array(AnnotationStyle.palette.enumerated()), id: \.offset) { index, color in
                swatch(color).position(point(index, of: AnnotationStyle.palette.count, radius: 62))
            }
            ForEach(Array(inner.enumerated()), id: \.offset) { index, tool in
                toolButton(tool, size: 50).position(point(index, of: inner.count, radius: 112))
            }
            ForEach(Array(outer.enumerated()), id: \.offset) { index, tool in
                toolButton(tool, size: 40).position(point(index, of: outerCount, radius: 168))
            }
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                actionButton(action).position(point(outer.count + index, of: outerCount, radius: 168))
            }
            hub.position(Self.center)
            widths.position(x: Self.center.x, y: 428)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    /// Evenly round a ring, starting at the top.
    private func point(_ index: Int, of count: Int, radius: CGFloat) -> CGPoint {
        let angle = (-90 + Double(index) * 360 / Double(max(count, 1))) * .pi / 180
        return CGPoint(x: Self.center.x + radius * cos(angle), y: Self.center.y + radius * sin(angle))
    }

    private var hub: some View {
        Button { state.close() } label: {
            VStack(spacing: 2) {
                Image(systemName: editor.tool.symbol).font(.system(size: 20))
                Text(editor.tool.title).font(.system(size: 9, weight: .semibold)).lineLimit(1)
            }
            .frame(width: 70, height: 70)
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(Circle().strokeBorder(Color(cgColor: editor.style.color.cgColor), lineWidth: 3))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Close the dial (Esc)")
    }

    private func toolButton(_ tool: AnnotationEditor.Tool, size: CGFloat) -> some View {
        let on = editor.tool == tool
        let hovered = state.hovered == tool
        return Button {
            editor.pick(tool)
            state.close()
        } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: size * 0.4))
                .frame(width: size, height: size)
                .background(Circle().fill(on ? Color.accentColor : (hovered ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.07))))
                .foregroundStyle(on ? Color.white : Color.primary)
                .overlay(alignment: .bottomTrailing) {
                    if let key = tool.shortcut {
                        Text(key)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(on ? Color.white.opacity(0.85) : Color.secondary)
                            .offset(x: -size * 0.12, y: -size * 0.08)
                    }
                }
                .contentShape(Circle())
                .scaleEffect(hovered ? 1.12 : 1)
                .animation(.easeOut(duration: 0.1), value: hovered)
        }
        .buttonStyle(.plain)
        .help(tool.title + (tool.shortcut.map { " (\($0))" } ?? ""))
        .onHover { inside in
            if inside { state.hovered = tool } else if state.hovered == tool { state.hovered = nil }
        }
    }

    @ViewBuilder private func actionButton(_ action: Action) -> some View {
        switch action {
        case .rotateLeft, .rotateRight:
            let clockwise = action == .rotateRight
            Button {
                editor.editEdits(clockwise ? "Rotate Right" : "Rotate Left") { $0 = $0.rotated(clockwise: clockwise) }
            } label: { face(clockwise ? "rotate.right" : "rotate.left") }
                .buttonStyle(.plain)
                .help(clockwise ? "Rotate right" : "Rotate left")
        case .adjust:
            AdjustMenu(compact: true).clipShape(Circle())
        case .smartRedact:
            Menu {
                Button("Hide Sensitive Info with Black Boxes") { editor.smartRedact(with: .redact); state.close() }
                Button("Hide Sensitive Info with Blur") { editor.smartRedact(with: .blur); state.close() }
                Button("Hide Sensitive Info with Pixels") { editor.smartRedact(with: .pixelate); state.close() }
            } label: { face("wand.and.stars") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Smart Redact: find email addresses, phone numbers, card numbers and more, and hide them")
        case .simplify:
            Menu {
                Button("Simplify in Its Own Colors") { editor.simplify(.original); state.close() }
                Button("Simplify in Grays") { editor.simplify(.grays); state.close() }
                if editor.annotations.contains(where: { $0.kind == .simplify }) {
                    Divider()
                    Button("Remove Simplify") { editor.removeSimplify(); state.close() }
                }
            } label: { face("rectangle.3.group") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Simplify: redraw the picture as plain shapes")
        }
    }

    private func face(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16))
            .frame(width: 40, height: 40)
            .background(Circle().fill(Color.primary.opacity(0.07)))
            .contentShape(Circle())
    }

    private func swatch(_ color: RGBA) -> some View {
        let on = editor.style.color == color
        return Button { editor.style.color = color } label: {
            Circle()
                .fill(Color(cgColor: color.cgColor))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
                .frame(width: 22, height: 22)
                .padding(3)
                .overlay(Circle().strokeBorder(on ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(AnnotationToolbar.name(color))
    }

    /// Line widths, and the system colors for any other color.
    private var widths: some View {
        HStack(spacing: 6) {
            ForEach([2.0, 4, 8, 12], id: \.self) { width in
                let on = editor.style.lineWidth == width
                Button { editor.style.lineWidth = width } label: {
                    Capsule()
                        .fill(Color.primary)
                        .frame(width: 18, height: max(2, width / 2))
                        .frame(width: 34, height: 26)
                        .background(Capsule().fill(on ? Color.accentColor.opacity(0.25) : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(Int(width)) pt lines")
            }
            Divider().frame(height: 18)
            Button { ColorPanelBridge.shared.open() } label: {
                Image(systemName: "paintpalette").frame(width: 30, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Other color…")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
    }
}

// MARK: - Opening and closing it

extension ZoomingScrollView {
    static let openDialNotification = Notification.Name("CaptureLensOpenDial")
}

/// The open dial, if any: which window shows it, where (window coordinates) and the state it
/// shares with the picture that opened it. The window's content draws it with `DialOverlay`.
@Observable
@MainActor
final class DialPresenter {
    static let shared = DialPresenter()

    struct Request {
        let windowNumber: Int
        let frame: CGRect
        let state: ToolDialState
    }

    var request: Request?
    /// Where each window's overlay is (window coordinates), to keep the dial inside it.
    @ObservationIgnored var overlayAreas: [Int: CGRect] = [:]
}

/// Draws the open dial over the area it's put on (the library's grid and picture, or the
/// pop-out window), positioned from the window coordinates the picture asked for.
struct DialOverlay: View {
    @State private var presenter = DialPresenter.shared
    /// This overlay's window, and its place in it (window coordinates).
    @State private var windowNumber = 0
    @State private var area = CGRect.zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let request = presenter.request, request.windowNumber == windowNumber, windowNumber != 0 {
                ToolDialView(state: request.state)
                    .position(x: request.frame.midX - area.minX, y: area.maxY - request.frame.midY)
            }
        }
        .allowsHitTesting(presenter.request?.windowNumber == windowNumber)
        .background(AreaReader { number, frame in
            windowNumber = number
            area = frame
        })
    }
}

/// Reports which window a view is in and where (window coordinates), and records it so the
/// picture can keep the dial inside it.
private struct AreaReader: NSViewRepresentable {
    let report: (Int, CGRect) -> Void

    final class Probe: NSView {
        var report: (Int, CGRect) -> Void = { _, _ in }
        private var last: (Int, CGRect)?

        // It covers the whole area, so clicks must go through it to what's underneath.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            send()
        }

        override func layout() {
            super.layout()
            send()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            send()
        }

        private func send() {
            guard let window else { return }
            let now = (window.windowNumber, convert(bounds, to: nil))
            if let last, last.0 == now.0, last.1 == now.1 { return }
            last = now
            DialPresenter.shared.overlayAreas[now.0] = now.1
            DispatchQueue.main.async { [report] in report(now.0, now.1) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.report = report
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.report = report
        probe.needsLayout = true
    }
}
