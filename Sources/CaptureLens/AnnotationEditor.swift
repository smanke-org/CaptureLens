import AppKit
import CaptureLensKit
import Observation
import SwiftUI

/// The annotation tools for the capture open in the library: which tool is picked, the
/// style new marks get, what's selected. Marks are saved with the capture as they change
/// (and sync with it); the picture itself is never touched.
@Observable
@MainActor
final class AnnotationEditor {
    static let shared = AnnotationEditor()

    enum Tool: Equatable {
        case select
        case draw(Annotation.Kind)
    }

    var tool: Tool = .select
    /// The style new marks get; changing it restyles the selected mark too.
    var style: AnnotationStyle = Preferences.shared.annotationStyle {
        didSet {
            guard style != oldValue else { return }
            Preferences.shared.annotationStyle = style
            if let id = selection { change(id, action: "Change Style") { $0.style = self.style } }
        }
    }
    var stamp = "✅"
    var selection: UUID?
    /// Off shows the picture as captured, without marks (copying and saving still include them).
    var showAnnotations = true
    /// The capture being edited.
    private(set) var itemID: UUID?
    /// Undo for annotation changes, apart from the window's: every change is exactly one step.
    @ObservationIgnored let undoManager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.levelsOfUndo = 100
        return manager
    }()
    /// Bumped on every change, so Undo and Redo buttons update.
    private(set) var revision = 0

    static let stamps = ["✅", "❌", "⚠️", "⭐️", "👍", "👎", "❓", "💡", "🔥", "➡️", "Approved", "Draft", "Done", "Rejected"]

    var annotations: [Annotation] { itemID.flatMap { LibraryStore.shared.entry($0)?.annotations } ?? [] }
    var selected: Annotation? { selection.flatMap { id in annotations.first { $0.id == id } } }

    func open(_ id: UUID) {
        guard id != itemID else { return }
        itemID = id
        selection = nil
        // Undo belongs to the capture it was made on.
        undoManager.removeAllActions()
        revision += 1
    }

    func pick(_ newTool: Tool) {
        tool = newTool
        if newTool != .select { selection = nil }
    }

    /// Selecting a mark shows its style in the toolbar, so changes apply to it.
    func select(_ id: UUID?) {
        selection = id
        if let mark = selected, mark.style != style {
            // Set without restyling: it's already this mark's style.
            let keep = selection
            selection = nil
            style = mark.style
            selection = keep
        }
    }

    // MARK: Changes, each undoable

    /// Replaces the capture's annotations, saving the capture and recording an undo step.
    func commit(_ new: [Annotation], action: String) {
        guard let id = itemID, var item = LibraryStore.shared.entry(id), item.annotations != new else { return }
        let old = item.annotations
        item.annotations = new
        LibraryStore.shared.update(item)
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated {
                guard editor.itemID == id else { return }
                editor.commit(old, action: action)
            }
        }
        undoManager.setActionName(action)
        undoManager.endUndoGrouping()
        if let selection, !new.contains(where: { $0.id == selection }) { self.selection = nil }
        revision += 1
    }

    func undo() {
        guard undoManager.canUndo else { return }
        undoManager.undo()
        revision += 1
    }

    func redo() {
        guard undoManager.canRedo else { return }
        undoManager.redo()
        revision += 1
    }

    func change(_ id: UUID, action: String, _ body: (inout Annotation) -> Void) {
        var marks = annotations
        guard let index = marks.firstIndex(where: { $0.id == id }) else { return }
        body(&marks[index])
        commit(marks, action: action)
    }

    func deleteSelection() {
        guard let id = selection else { return }
        commit(annotations.filter { $0.id != id }, action: "Delete Annotation")
        selection = nil
    }

    func removeAll() {
        commit([], action: "Remove All Annotations")
    }

    /// Brings the selected mark in front of the others, or sends it behind.
    func reorder(toFront: Bool) {
        guard let id = selection else { return }
        var marks = annotations
        guard let index = marks.firstIndex(where: { $0.id == id }) else { return }
        let mark = marks.remove(at: index)
        if toFront { marks.append(mark) } else { marks.insert(mark, at: 0) }
        commit(marks, action: toFront ? "Bring to Front" : "Send to Back")
    }

    // MARK: Quick styles

    func saveQuickStyle() {
        let prefs = Preferences.shared
        guard !prefs.quickStyles.contains(style) else { return }
        prefs.quickStyles.append(style)
    }

    func removeQuickStyle(_ quick: AnnotationStyle) {
        Preferences.shared.quickStyles.removeAll { $0 == quick }
    }
}

// MARK: - The drawing layer

/// Draws a capture's annotations over its picture and handles the tools. Flipped, so its
/// space is the capture's points with the origin at the top left, as annotations are stored.
final class AnnotationLayerView: NSView, NSTextViewDelegate, NSMenuItemValidation {
    var editor: AnnotationEditor { AnnotationEditor.shared }
    /// The picture, for magnifiers.
    var baseImage: CGImage?

    /// The marks as they look mid-drag; nil when showing what's saved.
    private var live: [Annotation]?
    private var drag: Drag?
    private var textView: NSTextView?
    private var editingID: UUID?

    private enum Drag {
        case drawing(Annotation, start: CGPoint)
        case moving(UUID, last: CGPoint, original: [Annotation])
        case handle(UUID, Handle, original: [Annotation])
    }

    enum Handle: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight, from, to, tail
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var marks: [Annotation] { live ?? editor.annotations }
    private var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }
    /// Handles and tolerances stay the same size on screen at any zoom.
    private var onScreen: CGFloat { 1 / max(magnification, 0.05) }

    func refresh() { needsDisplay = true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if editor.showAnnotations || live != nil {
            AnnotationRenderer.draw(marks, in: ctx, canvas: bounds.size, base: baseImage)
        }
        if let id = editor.selection, let mark = marks.first(where: { $0.id == id }), editingID != id {
            drawSelection(mark, in: ctx)
        }
    }

    private func drawSelection(_ mark: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        let line = onScreen
        ctx.setLineWidth(line)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineDash(phase: 0, lengths: [4 * line, 3 * line])
        ctx.stroke(mark.bounds.insetBy(dx: -4 * line, dy: -4 * line))
        ctx.setLineDash(phase: 0, lengths: [])
        for (_, point) in handles(of: mark) {
            let size = 8 * line
            let box = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: box)
            ctx.strokeEllipse(in: box)
        }
        ctx.restoreGState()
    }

    private func handles(of mark: Annotation) -> [(Handle, CGPoint)] {
        switch mark.kind {
        case .line, .arrow:
            return [(.from, mark.from), (.to, mark.to)]
        case .pen, .highlighter:
            return []
        default:
            let r = mark.rect.standardized
            var list: [(Handle, CGPoint)] = [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.topRight, CGPoint(x: r.maxX, y: r.minY)),
                                             (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.bottomRight, CGPoint(x: r.maxX, y: r.maxY))]
            if mark.kind == .callout { list.append((.tail, mark.tail)) }
            return list
        }
    }

    // MARK: Hit testing

    /// With the select tool, only marks and handles take clicks; everywhere else they go to
    /// the picture underneath, so its text can still be selected and copied.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let local = superview.map({ convert(point, from: $0) }), bounds.contains(local) || textView != nil else { return nil }
        if let textView, let hit = textView.hitTest(convert(local, to: textView.superview)) { return hit }
        if editor.tool != .select { return self }
        if handle(at: local) != nil || mark(at: local) != nil || textView != nil { return self }
        return nil
    }

    private func mark(at point: CGPoint) -> Annotation? {
        guard editor.showAnnotations else { return nil }
        return marks.reversed().first { $0.hit(point, tolerance: 6 * onScreen) }
    }

    private func handle(at point: CGPoint) -> (UUID, Handle)? {
        guard let id = editor.selection, let mark = marks.first(where: { $0.id == id }) else { return nil }
        let reach = 8 * onScreen
        return handles(of: mark).first { hypot($0.1.x - point.x, $0.1.y - point.y) <= reach }.map { (id, $0.0) }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if textView != nil { endTextEditing() }
        window?.makeFirstResponder(self)
        LibraryLock.shared.touch()
        switch editor.tool {
        case .select:
            if let (id, handle) = handle(at: point) {
                drag = .handle(id, handle, original: editor.annotations)
            } else if let hit = mark(at: point) {
                editor.select(hit.id)
                if event.clickCount == 2 && hit.kind.hasText {
                    beginTextEditing(hit)
                    return
                }
                drag = .moving(hit.id, last: point, original: editor.annotations)
            } else {
                editor.select(nil)
            }
        case .draw(let kind):
            editor.select(nil)
            var mark = Annotation(kind: kind, rect: CGRect(origin: point, size: .zero), from: point, to: point,
                                  tail: point, points: [point], stamp: editor.stamp, style: editor.style)
            if kind == .magnify { mark.zoom = 2 }
            drag = .drawing(mark, start: point)
            live = editor.annotations + [mark]
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let constrain = event.modifierFlags.contains(.shift)
        switch drag {
        case .drawing(var mark, let start):
            switch mark.kind {
            case .line, .arrow:
                mark.to = Annotation.lineEnd(from: start, to: point, constrain: constrain)
            case .pen, .highlighter:
                mark.points.append(point)
            case .callout:
                // Drag out the bubble; its tail points back where the drag began.
                mark.rect = Annotation.rect(from: start, to: point, constrain: constrain)
                mark.tail = start
            default:
                mark.rect = Annotation.rect(from: start, to: point, constrain: constrain || mark.kind == .step || mark.kind == .magnify)
            }
            drag = .drawing(mark, start: start)
            live = editor.annotations + [mark]
        case .moving(let id, let last, let original):
            var marks = live ?? original
            if let index = marks.firstIndex(where: { $0.id == id }) { marks[index].offset(dx: point.x - last.x, dy: point.y - last.y) }
            live = marks
            drag = .moving(id, last: point, original: original)
        case .handle(let id, let handle, let original):
            var marks = original
            if let index = marks.firstIndex(where: { $0.id == id }) {
                Self.move(&marks[index], handle, to: point, constrain: constrain)
            }
            live = marks
        case nil:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; live = nil; needsDisplay = true }
        switch drag {
        case .drawing(var mark, let start):
            let size = mark.kind.isLinear ? hypot(mark.to.x - mark.from.x, mark.to.y - mark.from.y)
                : mark.kind.isFreehand ? CGFloat(mark.points.count) * 3 : max(mark.rect.width, mark.rect.height)
            if size < 4 {
                guard mark.kind.placesWithClick || mark.kind == .magnify || mark.kind == .spotlight else { return }
                mark.rect = Self.defaultRect(for: mark, at: start)
                if mark.kind == .callout { mark.tail = CGPoint(x: start.x - 30, y: start.y + 50) }
            }
            if mark.kind.hasText && mark.text.isEmpty {
                // Wide enough to type in; it grows to fit the words.
                mark.rect.size.width = max(mark.rect.width, 160)
                mark.rect.size.height = max(mark.rect.height, AnnotationRenderer.textSize("Ag", style: mark.style, width: 400).height + (mark.kind == .callout ? 16 : 0))
            }
            editor.commit(editor.annotations + [mark], action: "Add \(mark.kind.title)")
            editor.select(mark.id)
            if mark.kind.hasText {
                live = nil
                beginTextEditing(mark)
            }
        case .moving(let id, _, let original), .handle(let id, _, let original):
            if let final = live, final != original {
                editor.commit(final, action: drag.map { if case .moving = $0 { "Move Annotation" } else { "Resize Annotation" } } ?? "")
            }
            editor.select(id)
        case nil:
            break
        }
    }

    static func defaultRect(for mark: Annotation, at point: CGPoint) -> CGRect {
        let size: CGSize
        switch mark.kind {
        case .step: size = CGSize(width: max(28, mark.style.fontSize * 1.6), height: max(28, mark.style.fontSize * 1.6))
        case .stamp: size = AnnotationRenderer.isEmojiStamp(mark.stamp) ? CGSize(width: 56, height: 56) : CGSize(width: 150, height: 54)
        case .magnify: size = CGSize(width: 140, height: 140)
        case .spotlight: size = CGSize(width: 220, height: 140)
        default: size = CGSize(width: 180, height: 40)
        }
        return CGRect(x: point.x - (mark.kind == .text || mark.kind == .callout ? 0 : size.width / 2),
                      y: point.y - size.height / 2, width: size.width, height: size.height)
    }

    static func move(_ mark: inout Annotation, _ handle: Handle, to point: CGPoint, constrain: Bool) {
        switch handle {
        case .from: mark.from = Annotation.lineEnd(from: mark.to, to: point, constrain: constrain)
        case .to: mark.to = Annotation.lineEnd(from: mark.from, to: point, constrain: constrain)
        case .tail: mark.tail = point
        default:
            let r = mark.rect.standardized
            let anchor: CGPoint = switch handle {
            case .topLeft: CGPoint(x: r.maxX, y: r.maxY)
            case .topRight: CGPoint(x: r.minX, y: r.maxY)
            case .bottomLeft: CGPoint(x: r.maxX, y: r.minY)
            default: CGPoint(x: r.minX, y: r.minY)
            }
            mark.rect = Annotation.rect(from: anchor, to: point, constrain: constrain || mark.kind == .step || mark.kind == .magnify)
        }
    }

    // MARK: Undo, from Edit › Undo and ⌘Z while the picture has the keyboard

    @objc func undo(_ sender: Any?) { editor.undo(); needsDisplay = true }
    @objc func redo(_ sender: Any?) { editor.redo(); needsDisplay = true }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let manager = editor.undoManager
        switch item.action {
        case #selector(undo(_:)):
            item.title = manager.canUndo ? manager.undoMenuItemTitle : "Undo"
            return manager.canUndo
        case #selector(redo(_:)):
            item.title = manager.canRedo ? manager.redoMenuItemTitle : "Redo"
            return manager.canRedo
        default:
            return true
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case 51, 117: editor.deleteSelection() // Delete, Forward Delete
        case 53: // Esc
            if editor.selection != nil { editor.select(nil) } else { editor.pick(.select) }
        case 123, 124, 125, 126: // arrows nudge the selection
            guard let id = editor.selection else { return super.keyDown(with: event) }
            let (dx, dy): (CGFloat, CGFloat) = switch Int(event.keyCode) {
            case 123: (-step, 0)
            case 124: (step, 0)
            case 125: (0, step)
            default: (0, -step)
            }
            editor.change(id, action: "Move Annotation") { $0.offset(dx: dx, dy: dy) }
        case 36, 76: // Return edits a selected text or callout
            if let mark = editor.selected, mark.kind.hasText { beginTextEditing(mark) } else { super.keyDown(with: event) }
        default:
            // Single letters pick tools, as in most drawing apps.
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let key = event.charactersIgnoringModifiers?.lowercased(), let tool = Self.toolKeys[key] else {
                return super.keyDown(with: event)
            }
            editor.pick(tool)
        }
        needsDisplay = true
    }

    static let toolKeys: [String: AnnotationEditor.Tool] = [
        "v": .select, "r": .draw(.rectangle), "o": .draw(.ellipse), "l": .draw(.line), "a": .draw(.arrow),
        "t": .draw(.text), "c": .draw(.callout), "s": .draw(.step), "p": .draw(.pen), "h": .draw(.highlighter),
        "f": .draw(.spotlight), "m": .draw(.magnify), "k": .draw(.stamp),
    ]

    override func resetCursorRects() {
        if editor.tool != .select { addCursorRect(bounds, cursor: .crosshair) }
    }

    // MARK: Typing text

    func beginTextEditing(_ mark: Annotation) {
        endTextEditing()
        editingID = mark.id
        let callout = mark.kind == .callout
        let frame = callout ? mark.rect.standardized.insetBy(dx: 10, dy: 8) : mark.rect.standardized
        let view = NSTextView(frame: frame)
        view.delegate = self
        view.drawsBackground = false
        view.isRichText = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.font = NSFont.systemFont(ofSize: mark.style.fontSize, weight: mark.style.bold ? .bold : .regular)
        let color = callout || mark.style.filled ? mark.style.color.contrasting : mark.style.color
        view.textColor = NSColor(cgColor: color.cgColor)
        view.insertionPointColor = view.textColor ?? .labelColor
        view.string = mark.text
        view.isVerticallyResizable = true
        view.maxSize = CGSize(width: frame.width, height: .greatestFiniteMagnitude)
        addSubview(view)
        textView = view
        window?.makeFirstResponder(view)
        view.selectAll(nil)
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        // Grow the box to fit as the words come.
        guard let view = textView, let id = editingID, let mark = editor.annotations.first(where: { $0.id == id }) else { return }
        let padding: CGFloat = mark.kind == .callout ? 16 : 0
        let needed = AnnotationRenderer.textSize(view.string, style: mark.style, width: view.frame.width).height
        if needed + padding > mark.rect.height {
            view.frame.size.height = needed
        }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            endTextEditing()
            return true
        }
        return false
    }

    func textDidEndEditing(_ notification: Notification) { endTextEditing() }

    func endTextEditing() {
        guard let view = textView, let id = editingID else { return }
        textView = nil
        editingID = nil
        let text = view.string
        view.removeFromSuperview()
        var marks = editor.annotations
        if let index = marks.firstIndex(where: { $0.id == id }) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // An empty text box isn't worth keeping.
                marks.remove(at: index)
            } else {
                marks[index].text = text
                let padding: CGFloat = marks[index].kind == .callout ? 16 : 0
                let inner = marks[index].rect.width - (marks[index].kind == .callout ? 20 : 0)
                let height = AnnotationRenderer.textSize(text, style: marks[index].style, width: inner).height + padding
                marks[index].rect.size.height = max(marks[index].rect.height, height)
            }
            editor.commit(marks, action: "Edit Text")
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}

extension AnnotationRenderer {
    static func isEmojiStamp(_ text: String) -> Bool {
        text.count == 1 && text.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x238C }
    }
}

// MARK: - Toolbar

/// The tools above the picture: what to draw, its color, size and style, and quick styles.
struct AnnotationToolbar: View {
    @State private var editor = AnnotationEditor.shared
    @State private var prefs = Preferences.shared

    private static let tools: [Annotation.Kind] = [.rectangle, .ellipse, .arrow, .line, .text, .callout, .step, .pen,
                                                   .highlighter, .spotlight, .magnify, .stamp]

    var body: some View {
        HStack(spacing: 2) {
            toolButton(.select, symbol: "cursorarrow", help: "Select, move and resize (V)")
            Divider().frame(height: 18).padding(.horizontal, 3)
            ForEach(Self.tools, id: \.self) { kind in
                toolButton(.draw(kind), symbol: kind.symbol, help: "\(kind.title) (\(key(for: kind)))")
            }
            Divider().frame(height: 18).padding(.horizontal, 3)
            colorMenu
            sizeMenu
            if editor.tool == .draw(.stamp) || editor.selected?.kind == .stamp {
                stampMenu
            }
            if editor.selected?.kind == .magnify, let id = editor.selection {
                Menu {
                    ForEach([1.5, 2, 3, 4], id: \.self) { zoom in
                        Button("\(zoom.formatted())×") { editor.change(id, action: "Change Zoom") { $0.zoom = zoom } }
                    }
                } label: { Image(systemName: "plus.magnifyingglass") }
                .menuStyle(.borderlessButton).fixedSize().help("How much the magnifier enlarges")
            }
            quickStyleMenu
            Spacer(minLength: 4)
            let _ = editor.revision
            Button { editor.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!editor.undoManager.canUndo)
                .help(editor.undoManager.canUndo ? editor.undoManager.undoMenuItemTitle : "Undo")
            Button { editor.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!editor.undoManager.canRedo)
                .help(editor.undoManager.canRedo ? editor.undoManager.redoMenuItemTitle : "Redo")
            if editor.selection != nil {
                Button { editor.deleteSelection() } label: { Image(systemName: "trash") }
                    .help("Delete the selected annotation (Delete)")
            }
            Button { editor.showAnnotations.toggle() } label: {
                Image(systemName: editor.showAnnotations ? "eye" : "eye.slash")
            }
            .help(editor.showAnnotations ? "Hide annotations to see the picture as captured" : "Show annotations")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func key(for kind: Annotation.Kind) -> String {
        AnnotationLayerView.toolKeys.first { $0.value == .draw(kind) }?.key.uppercased() ?? ""
    }

    private func toolButton(_ tool: AnnotationEditor.Tool, symbol: String, help: String) -> some View {
        let on = editor.tool == tool
        return Button { editor.pick(tool) } label: {
            Image(systemName: symbol)
                .frame(width: 24, height: 22)
                .background(on ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(on ? Color.accentColor : .primary)
        }
        .help(help)
    }

    private var colorMenu: some View {
        Menu {
            ForEach(AnnotationStyle.palette, id: \.self) { color in
                Button { editor.style.color = color } label: {
                    Label { Text(Self.name(color)) } icon: { Image(nsImage: Self.swatch(color)) }
                }
            }
            Divider()
            Button("Other Color…") { ColorPanelBridge.shared.open() }
        } label: {
            Image(nsImage: Self.swatch(editor.style.color, size: 16))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Color")
    }

    private var sizeMenu: some View {
        Menu {
            Section("Line") {
                ForEach([2.0, 3, 4, 6, 8, 12], id: \.self) { width in
                    Button { editor.style.lineWidth = width } label: {
                        if editor.style.lineWidth == width { Label("\(Int(width)) pt", systemImage: "checkmark") } else { Text("\(Int(width)) pt") }
                    }
                }
            }
            Section("Text") {
                ForEach([12.0, 14, 16, 20, 24, 32, 48], id: \.self) { size in
                    Button { editor.style.fontSize = size } label: {
                        if editor.style.fontSize == size { Label("\(Int(size)) pt", systemImage: "checkmark") } else { Text("\(Int(size)) pt") }
                    }
                }
            }
            Divider()
            Toggle("Bold Text", isOn: $editor.style.bold)
            Toggle("Fill Shapes and Text", isOn: $editor.style.filled)
            Toggle("Shadow", isOn: $editor.style.shadow)
            if editor.selection != nil {
                Divider()
                Button("Bring to Front") { editor.reorder(toFront: true) }
                Button("Send to Back") { editor.reorder(toFront: false) }
            }
        } label: {
            Image(systemName: "lineweight")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Line width, text size and style")
    }

    private var stampMenu: some View {
        Menu {
            ForEach(AnnotationEditor.stamps, id: \.self) { stamp in
                Button(stamp) {
                    editor.stamp = stamp
                    if let id = editor.selection, editor.selected?.kind == .stamp {
                        editor.change(id, action: "Change Stamp") { $0.stamp = stamp }
                    }
                }
            }
        } label: { Text(editor.stamp).font(.callout) }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Which stamp")
    }

    private var quickStyleMenu: some View {
        Menu {
            ForEach(prefs.quickStyles, id: \.self) { quick in
                Button { editor.style = quick } label: {
                    Label { Text(Self.describe(quick)) } icon: { Image(nsImage: Self.swatch(quick.color)) }
                }
            }
            Divider()
            Button("Save Current Style") { editor.saveQuickStyle() }
                .disabled(prefs.quickStyles.contains(editor.style))
            if prefs.quickStyles.contains(editor.style) {
                Button("Remove Current Style") { editor.removeQuickStyle(editor.style) }
            }
        } label: {
            Image(systemName: "paintpalette")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Quick styles: saved colors and sizes, one click away")
    }

    static func describe(_ style: AnnotationStyle) -> String {
        var parts = [name(style.color), "\(Int(style.lineWidth)) pt", "text \(Int(style.fontSize))"]
        if style.filled { parts.append("filled") }
        return parts.joined(separator: ", ")
    }

    static func name(_ color: RGBA) -> String {
        switch color {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .black: "Black"
        case .white: "White"
        default: "Custom"
        }
    }

    /// A round color sample for menus.
    static func swatch(_ color: RGBA, size: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(cgColor: color.cgColor)?.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// The system color panel, feeding the annotation color.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()

    func open() {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.showsAlpha = true
        panel.color = NSColor(cgColor: AnnotationEditor.shared.style.color.cgColor) ?? .systemRed
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) {
        guard let c = panel.color.usingColorSpace(.sRGB) else { return }
        AnnotationEditor.shared.style.color = RGBA(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent),
                                                   Double(c.alphaComponent))
    }
}
