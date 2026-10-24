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

    enum Tool: Hashable {
        case select
        case draw(Annotation.Kind)
        /// Drag out (or adjust) the part to keep.
        case crop
        /// Drag across the strip to take out.
        case cut(CutOut.Axis)
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
    /// A cut-out strip picked with the select tool (Delete removes it).
    var selectedCut: UUID?
    /// How new cut-outs are joined; also changes the selected one.
    var seam: CutOut.Seam = .torn
    /// The library shows the finished picture rather than the one being marked up.
    var showResult = false
    var showResize = false
    var redacting = false
    /// What the smart tools found in the capture (its text and its separate parts), once looked.
    private(set) var analysis: SmartAnalysis?
    private(set) var analyzing = false
    var simplifying = false
    /// Off shows the picture as captured, without marks (copying and saving still include them).
    var showAnnotations = true
    /// For a recording: the cut section picked on the timeline, and whether dragging there cuts.
    var selectedVideoCut: UUID?
    var cuttingVideo = false
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
    var edits: ImageEdits { itemID.flatMap { LibraryStore.shared.entry($0)?.edits } ?? .none }
    var item: CaptureItem? { itemID.flatMap { LibraryStore.shared.entry($0) } }
    var selected: Annotation? { selection.flatMap { id in annotations.first { $0.id == id } } }

    func open(_ id: UUID) {
        guard id != itemID else { return }
        itemID = id
        analysis = nil
        selectedVideoCut = nil
        cuttingVideo = false
        selection = nil
        selectedCut = nil
        // Undo belongs to the capture it was made on.
        undoManager.removeAllActions()
        revision += 1
    }

    func pick(_ newTool: Tool) {
        tool = newTool
        if newTool != .select { selection = nil; selectedCut = nil }
        if newTool != .select { showResult = false }
        if case .draw(let kind) = newTool, kind.patches { analyze() }
    }

    // MARK: Smart tools

    struct SmartAnalysis {
        let itemID: UUID
        /// Lines of text, with their boxes in points.
        let lines: [(text: String, box: CGRect)]
        /// The separate parts of the picture, in points.
        let objects: [CGRect]
    }

    /// The capture's picture as stored, and its size in points.
    private var picture: (image: CGImage, canvas: CGSize)? {
        guard let item, let data = LibraryStore.shared.pngData(item.id), let image = AnnotationRenderer.image(from: data) else { return nil }
        return (image, item.pointSize)
    }

    /// Finds the capture's text and parts for Edit Text, Smart Move and Simplify (once per capture).
    func analyze(then done: ((SmartAnalysis) -> Void)? = nil) {
        if let analysis, analysis.itemID == itemID { done?(analysis); return }
        guard let id = itemID, let picture else { return }
        analyzing = true
        Task {
            let lines = (try? await Recognizer.lines(in: picture.image)) ?? []
            let canvas = picture.canvas
            let boxes = lines.map { line in
                (text: line.text, box: CGRect(x: line.box.minX * canvas.width, y: (1 - line.box.maxY) * canvas.height,
                                              width: line.box.width * canvas.width, height: line.box.height * canvas.height))
            }
            let image = picture.image
            let objects = await Task.detached(priority: .userInitiated) { ObjectFinder.objects(in: image, canvas: canvas) }.value
            guard itemID == id else { return }
            let result = SmartAnalysis(itemID: id, lines: boxes, objects: objects)
            analysis = result
            analyzing = false
            revision += 1
            done?(result)
        }
    }

    /// The Edit Text mark for a recognized line, styled to match the picture.
    func editTextMark(text: String, box: CGRect) -> Annotation? {
        guard let picture else { return nil }
        return TextMatch.mark(text: text, box: box, in: picture.image, canvas: picture.canvas)
    }

    /// Redraws the capture as plain shapes (replacing an earlier Simplify).
    func simplify(_ colors: Simplifier.Colors) {
        guard let id = itemID, let picture else { return }
        simplifying = true
        analyze { analysis in
            let image = picture.image
            let canvas = picture.canvas, lines = analysis.lines.map(\.box)
            Task {
                defer { self.simplifying = false }
                let marks = await Task.detached(priority: .userInitiated) {
                    Simplifier.marks(in: image, canvas: canvas, textLines: lines, colors: colors)
                }.value
                guard self.itemID == id else { return }
                self.commit(self.annotations.filter { $0.kind != .simplify } + marks, action: "Simplify")
                Notice.shared.show(marks.isEmpty ? "Nothing to simplify" : "Simplified \(marks.count) part\(marks.count == 1 ? "" : "s")",
                                   symbol: "rectangle.3.group")
            }
        }
        if analyzing == false && analysis?.itemID != id { simplifying = false }
    }

    func removeSimplify() {
        commit(annotations.filter { $0.kind != .simplify }, action: "Remove Simplify")
    }

    /// Selecting a mark shows its style in the toolbar, so changes apply to it.
    func select(_ id: UUID?) {
        selection = id
        if let mark = selected, mark.kind.hasDrawingStyle, mark.style != style {
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

    /// Replaces the capture's adjustments, saving it and recording an undo step.
    func commitEdits(_ new: ImageEdits, action: String) {
        guard let id = itemID, var item = LibraryStore.shared.entry(id), item.edits != new else { return }
        let old = item.edits
        item.edits = new
        LibraryStore.shared.update(item)
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated {
                guard editor.itemID == id else { return }
                editor.commitEdits(old, action: action)
            }
        }
        undoManager.setActionName(action)
        undoManager.endUndoGrouping()
        if let selectedCut, !new.cuts.contains(where: { $0.id == selectedCut }) { self.selectedCut = nil }
        revision += 1
    }

    func editEdits(_ action: String, _ body: (inout ImageEdits) -> Void) {
        var new = edits
        body(&new)
        commitEdits(new, action: action)
    }

    func setSeam(_ seam: CutOut.Seam) {
        self.seam = seam
        if let id = selectedCut {
            editEdits("Change Seam") { edits in
                if let i = edits.cuts.firstIndex(where: { $0.id == id }) { edits.cuts[i].seam = seam }
            }
        }
    }

    /// Covers email addresses, card numbers and other sensitive text with `kind` marks.
    func smartRedact(with kind: Annotation.Kind) {
        guard let item, let data = LibraryStore.shared.pngData(item.id), let image = AnnotationRenderer.image(from: data) else { return }
        redacting = true
        Task {
            defer { redacting = false }
            let boxes = await Recognizer.sensitiveBoxes(in: image)
            let size = item.pointSize
            let pad: CGFloat = 3
            let marks = boxes.map { box in
                Annotation(kind: kind, rect: CGRect(x: box.minX * size.width - pad, y: box.minY * size.height - pad,
                                                    width: box.width * size.width + pad * 2, height: box.height * size.height + pad * 2),
                           style: AnnotationStyle(color: .black, lineWidth: 0, shadow: false))
            }
            guard itemID == item.id else { return }
            if marks.isEmpty {
                Notice.shared.show("Nothing sensitive found", symbol: "checkmark.shield")
            } else {
                commit(annotations + marks, action: "Smart Redact")
                Notice.shared.show("Hid \(marks.count) item\(marks.count == 1 ? "" : "s")", symbol: "eye.slash")
            }
        }
    }

    func bumpRevision() { revision += 1 }

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
    /// The adjustments as they look mid-drag (cropping, cutting).
    private var liveEdits: ImageEdits?
    private var drag: Drag?
    private var textView: NSTextView?
    private var editingID: UUID?
    /// Where the pointer is, for highlighting what the smart tools would pick.
    private var hover: CGPoint?

    private enum Drag {
        case drawing(Annotation, start: CGPoint)
        case moving(UUID, last: CGPoint, original: [Annotation])
        /// A part just picked up with Smart Move, saved when it's put down.
        case placing(UUID, last: CGPoint)
        case handle(UUID, Handle, original: [Annotation])
        case cropping(start: CGPoint, original: CGRect?, mode: CropMode)
        case cutting(CutOut.Axis, start: CGPoint)
    }

    private enum CropMode {
        case new
        case move
        case corner(Handle)
    }

    enum Handle: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight, from, to, tail
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var marks: [Annotation] { live ?? editor.annotations }
    private var edits: ImageEdits { liveEdits ?? editor.edits }
    private var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }
    /// Handles and tolerances stay the same size on screen at any zoom.
    private var onScreen: CGFloat { 1 / max(magnification, 0.05) }

    func refresh() { needsDisplay = true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if editor.showAnnotations || live != nil {
            // The text being typed shows in the text box, not twice.
            let shown = editingID.map { id in marks.map { $0.id == id ? $0.withoutText : $0 } } ?? marks
            AnnotationRenderer.draw(shown, in: ctx, canvas: bounds.size, base: baseImage)
        }
        drawSmartTargets(in: ctx)
        if let id = editor.selection, let mark = marks.first(where: { $0.id == id }), editingID != id {
            drawSelection(mark, in: ctx)
        }
        drawCuts(in: ctx)
        drawCrop(in: ctx)
    }

    /// With Edit Text or Smart Move, what they'd pick is outlined, the one under the pointer filled.
    private func drawSmartTargets(in ctx: CGContext) {
        guard drag == nil, textView == nil, case .draw(let kind) = editor.tool, kind == .editText || kind == .move else { return }
        let targets = smartTargets(for: kind)
        guard !targets.isEmpty else { return }
        let hovered = hover.flatMap { point in target(in: targets, at: point) }
        ctx.saveGState()
        ctx.setLineWidth(onScreen)
        ctx.setLineDash(phase: 0, lengths: [3 * onScreen, 3 * onScreen])
        ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor)
        for target in targets { ctx.stroke(target) }
        if let hovered {
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor)
            ctx.fill(hovered)
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setLineWidth(2 * onScreen)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.stroke(hovered)
        }
        ctx.restoreGState()
    }

    /// What Edit Text (lines of text) or Smart Move (parts) can pick, leaving out what's already been taken.
    private func smartTargets(for kind: Annotation.Kind) -> [CGRect] {
        guard let analysis = editor.analysis, analysis.itemID == editor.item?.id else { return [] }
        let taken = marks.filter { $0.kind == kind }.map(\.source)
        let all = kind == .editText ? analysis.lines.map { $0.box.insetBy(dx: -2, dy: -2) } : analysis.objects
        return all.filter { target in
            !taken.contains { used in
                let overlap = used.intersection(target)
                return !overlap.isNull && overlap.width * overlap.height > target.width * target.height * 0.5
            }
        }
    }

    /// The target under `point`: the smallest one there, or what snugly wraps it (a button
    /// around its label, a tag around its word), since that's what's usually meant.
    private func target(in targets: [CGRect], at point: CGPoint) -> CGRect? {
        func area(_ r: CGRect) -> CGFloat { r.width * r.height }
        let here = targets.filter { $0.contains(point) }.sorted { area($0) < area($1) }
        guard var best = here.first else { return nil }
        for outer in here.dropFirst() where outer.contains(best) && area(outer) <= area(best) * 4 { best = outer }
        return best
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard case .draw(let kind) = editor.tool, kind == .editText || kind == .move else { hover = nil; return }
        hover = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
    }

    /// Strips to be cut out, hatched so it's clear they won't be in the result.
    private func drawCuts(in ctx: CGContext) {
        for cut in edits.cuts {
            let band = Self.band(cut, in: bounds)
            ctx.saveGState()
            ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.18).cgColor)
            ctx.fill(band)
            ctx.clip(to: band)
            ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(1.5 * onScreen)
            let step = 12 * onScreen
            var x = band.minX - band.height
            while x < band.maxX {
                ctx.move(to: CGPoint(x: x, y: band.maxY))
                ctx.addLine(to: CGPoint(x: x + band.height, y: band.minY))
                x += step
            }
            ctx.strokePath()
            ctx.restoreGState()
            ctx.saveGState()
            let selected = editor.selectedCut == cut.id
            ctx.setStrokeColor((selected ? NSColor.controlAccentColor : NSColor.systemRed).cgColor)
            ctx.setLineWidth((selected ? 2.5 : 1) * onScreen)
            ctx.setLineDash(phase: 0, lengths: [5 * onScreen, 4 * onScreen])
            ctx.stroke(band)
            ctx.restoreGState()
        }
    }

    static func band(_ cut: CutOut, in bounds: CGRect) -> CGRect {
        cut.axis == .horizontal
            ? CGRect(x: bounds.minX, y: cut.from, width: bounds.width, height: cut.to - cut.from)
            : CGRect(x: cut.from, y: bounds.minY, width: cut.to - cut.from, height: bounds.height)
    }

    /// Outside the crop is dimmed; with the crop tool it gets handles and thirds.
    private func drawCrop(in ctx: CGContext) {
        guard let crop = edits.crop?.standardized else { return }
        let cropping = editor.tool == .crop
        ctx.saveGState()
        let outside = CGMutablePath()
        outside.addRect(bounds)
        outside.addRect(crop)
        ctx.addPath(outside)
        ctx.setFillColor(CGColor(gray: 0, alpha: cropping ? 0.6 : 0.45))
        ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.setLineWidth(1.5 * onScreen)
        ctx.stroke(crop)
        if cropping {
            ctx.setLineWidth(0.75 * onScreen)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.5))
            for i in 1...2 {
                let x = crop.minX + crop.width * CGFloat(i) / 3, y = crop.minY + crop.height * CGFloat(i) / 3
                ctx.move(to: CGPoint(x: x, y: crop.minY)); ctx.addLine(to: CGPoint(x: x, y: crop.maxY))
                ctx.move(to: CGPoint(x: crop.minX, y: y)); ctx.addLine(to: CGPoint(x: crop.maxX, y: y))
            }
            ctx.strokePath()
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            for (_, point) in Self.corners(of: crop) {
                let size = 10 * onScreen
                ctx.fill(CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
            }
        }
        ctx.restoreGState()
    }

    static func corners(of r: CGRect) -> [(Handle, CGPoint)] {
        [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.topRight, CGPoint(x: r.maxX, y: r.minY)),
         (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.bottomRight, CGPoint(x: r.maxX, y: r.maxY))]
    }

    private func drawSelection(_ mark: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        let line = onScreen
        ctx.setLineWidth(line)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineDash(phase: 0, lengths: [4 * line, 3 * line])
        ctx.stroke(mark.bounds.insetBy(dx: -4 * line, dy: -4 * line))
        if mark.kind.patches, mark.source != mark.rect {
            // Where it was taken from.
            ctx.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
            ctx.stroke(mark.source)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        }
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
        if handle(at: local) != nil || mark(at: local) != nil || cut(at: local) != nil || textView != nil { return self }
        return nil
    }

    private func cut(at point: CGPoint) -> CutOut? {
        edits.cuts.last { Self.band($0, in: bounds).contains(point) }
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
                editor.selectedCut = nil
                editor.select(hit.id)
                if event.clickCount == 2 && hit.kind.hasText {
                    beginTextEditing(hit)
                    return
                }
                drag = .moving(hit.id, last: point, original: editor.annotations)
            } else if let band = cut(at: point) {
                editor.select(nil)
                editor.selectedCut = band.id
            } else {
                editor.select(nil)
                editor.selectedCut = nil
            }
        case .crop:
            let crop = editor.edits.crop?.standardized
            let reach = 10 * onScreen
            if let crop, let corner = Self.corners(of: crop).first(where: { hypot($0.1.x - point.x, $0.1.y - point.y) <= reach }) {
                drag = .cropping(start: point, original: crop, mode: .corner(corner.0))
            } else if let crop, crop.contains(point) {
                drag = .cropping(start: point, original: crop, mode: .move)
            } else {
                drag = .cropping(start: point, original: crop, mode: .new)
            }
        case .cut(let axis):
            drag = .cutting(axis, start: point)
        case .draw(let kind):
            if kind == .editText || kind == .move, smartPick(kind, at: point, event: event) { break }
            editor.select(nil)
            var mark = Annotation(kind: kind, rect: CGRect(origin: point, size: .zero), from: point, to: point,
                                  tail: point, points: [point], stamp: editor.stamp, style: editor.style)
            if kind == .magnify { mark.zoom = 2 }
            if kind == .redact { mark.style = AnnotationStyle(color: .black, lineWidth: 0, shadow: false) }
            if kind.patches { mark.style.shadow = false; mark.style.filled = false }
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
        case .placing(let id, let last):
            var marks = live ?? editor.annotations
            if let index = marks.firstIndex(where: { $0.id == id }) { marks[index].offset(dx: point.x - last.x, dy: point.y - last.y) }
            live = marks
            drag = .placing(id, last: point)
        case .handle(let id, let handle, let original):
            var marks = original
            if let index = marks.firstIndex(where: { $0.id == id }) {
                Self.move(&marks[index], handle, to: point, constrain: constrain)
            }
            live = marks
        case .cropping(let start, let original, let mode):
            let canvas = bounds
            var crop: CGRect
            switch mode {
            case .new:
                crop = Annotation.rect(from: start, to: point, constrain: constrain)
            case .move:
                crop = original ?? canvas
                crop.origin.x = min(max(crop.minX + point.x - start.x, 0), canvas.width - crop.width)
                crop.origin.y = min(max(crop.minY + point.y - start.y, 0), canvas.height - crop.height)
            case .corner(let handle):
                let r = original ?? canvas
                let anchor: CGPoint = switch handle {
                case .topLeft: CGPoint(x: r.maxX, y: r.maxY)
                case .topRight: CGPoint(x: r.minX, y: r.maxY)
                case .bottomLeft: CGPoint(x: r.maxX, y: r.minY)
                default: CGPoint(x: r.minX, y: r.minY)
                }
                crop = Annotation.rect(from: anchor, to: point, constrain: constrain)
            }
            var new = editor.edits
            new.crop = crop.intersection(canvas)
            liveEdits = new
        case .cutting(let axis, let start):
            var new = editor.edits
            let from = axis == .horizontal ? start.y : start.x
            let to = axis == .horizontal ? point.y : point.x
            let limit = axis == .horizontal ? bounds.height : bounds.width
            new.cuts.append(CutOut(axis: axis, from: max(0, min(from, to)), to: min(limit, max(from, to)), seam: editor.seam))
            liveEdits = new
        case nil:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; live = nil; liveEdits = nil; needsDisplay = true }
        switch drag {
        case .cropping:
            guard var new = liveEdits else { return }
            if let crop = new.crop, crop.width < 8 || crop.height < 8 { new.crop = editor.edits.crop }
            editor.commitEdits(new, action: "Crop")
        case .cutting:
            guard let new = liveEdits, let cut = new.cuts.last, cut.to - cut.from >= 4 else { return }
            editor.commitEdits(new, action: "Cut Out")
            editor.selectedCut = cut.id
        case .drawing(var mark, let start):
            let size = mark.kind.isLinear ? hypot(mark.to.x - mark.from.x, mark.to.y - mark.from.y)
                : mark.kind.isFreehand ? CGFloat(mark.points.count) * 3 : max(mark.rect.width, mark.rect.height)
            if mark.kind.patches {
                // Dragged over an area by hand: that's what's taken (and painted out).
                guard size >= 4 else { return }
                mark.source = mark.rect.standardized
            }
            if size < 4 {
                guard mark.kind.placesWithClick || mark.kind == .magnify || mark.kind == .spotlight else { return }
                mark.rect = Self.defaultRect(for: mark, at: start)
                if mark.kind == .callout { mark.tail = CGPoint(x: start.x - 30, y: start.y + 50) }
            }
            if mark.kind.hasText && mark.text.isEmpty && mark.kind != .editText {
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
        case .placing(let id, _):
            if let final = live { editor.commit(final, action: "Smart Move") }
            editor.select(id)
        case .moving(let id, _, let original), .handle(let id, _, let original):
            if let final = live, final != original {
                editor.commit(final, action: drag.map { if case .moving = $0 { "Move Annotation" } else { "Resize Annotation" } } ?? "")
            }
            editor.select(id)
        case nil:
            break
        }
    }

    /// Edit Text and Smart Move pick what's under a click: an existing mark of theirs, or a
    /// line of text or part the picture was found to have. False leaves the click to drag out
    /// an area by hand.
    private func smartPick(_ kind: Annotation.Kind, at point: CGPoint, event: NSEvent) -> Bool {
        if let hit = mark(at: point), hit.kind == kind {
            editor.select(hit.id)
            if kind == .editText { beginTextEditing(hit) } else { drag = .moving(hit.id, last: point, original: editor.annotations) }
            return true
        }
        guard let picked = target(in: smartTargets(for: kind), at: point) else { return false }
        editor.select(nil)
        if kind == .editText {
            guard let line = editor.analysis?.lines.first(where: { $0.box.insetBy(dx: -2, dy: -2) == picked }),
                  let mark = editor.editTextMark(text: line.text, box: line.box) else { return false }
            editor.commit(editor.annotations + [mark], action: "Edit Text")
            editor.select(mark.id)
            beginTextEditing(mark)
        } else {
            let mark = Annotation(kind: .move, rect: picked, source: picked,
                                  style: AnnotationStyle(color: editor.style.color, lineWidth: 0, shadow: false))
            live = editor.annotations + [mark]
            drag = .placing(mark.id, last: point)
        }
        return true
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
        case 51, 117: // Delete, Forward Delete
            if let id = editor.selectedCut {
                editor.editEdits("Delete Cut-Out") { $0.cuts.removeAll { $0.id == id } }
            } else {
                editor.deleteSelection()
            }
        case 53: // Esc
            if editor.selection != nil || editor.selectedCut != nil { editor.select(nil); editor.selectedCut = nil } else { editor.pick(.select) }
        case 123, 124, 125, 126: // arrows nudge the selection
            guard let id = editor.selection else { return super.keyDown(with: event) }
            let (dx, dy): (CGFloat, CGFloat) = switch Int(event.keyCode) {
            case 123: (-step, 0)
            case 124: (step, 0)
            case 125: (0, step)
            default: (0, -step)
            }
            editor.change(id, action: "Move Annotation") { $0.offset(dx: dx, dy: dy) }
        case 36, 76: // Return edits a selected text or callout, or finishes cropping
            if editor.tool == .crop { editor.pick(.select) }
            else if let mark = editor.selected, mark.kind.hasText { beginTextEditing(mark) } else { super.keyDown(with: event) }
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
        "f": .draw(.spotlight), "m": .draw(.magnify), "k": .draw(.stamp), "b": .draw(.blur), "x": .draw(.pixelate),
        "d": .draw(.redact), "y": .crop, "e": .draw(.editText), "g": .draw(.move),
    ]

    override func resetCursorRects() {
        if editor.tool != .select { addCursorRect(bounds, cursor: .crosshair) }
    }

    // MARK: Typing text

    func beginTextEditing(_ mark: Annotation) {
        endTextEditing()
        editingID = mark.id
        let callout = mark.kind == .callout
        var frame = callout ? mark.rect.standardized.insetBy(dx: 10, dy: 8) : mark.rect.standardized
        if mark.kind == .editText {
            // Where the retyped line is drawn: centered up and down in its box.
            let line = AnnotationRenderer.textSize(mark.text.isEmpty ? "Ag" : mark.text, style: mark.style, width: 10_000)
            frame = CGRect(x: frame.minX, y: frame.midY - line.height / 2, width: max(frame.width, line.width), height: line.height)
        }
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
        if mark.kind == .editText {
            // One line that grows sideways, as the original was.
            view.isHorizontallyResizable = true
            view.textContainer?.widthTracksTextView = false
            view.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            view.minSize = frame.size
            view.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
        addSubview(view)
        textView = view
        window?.makeFirstResponder(view)
        view.selectAll(nil)
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        // Grow the box to fit as the words come.
        guard let view = textView, let id = editingID, let mark = editor.annotations.first(where: { $0.id == id }),
              mark.kind != .editText else { return }
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
            if marks[index].kind == .editText {
                // Left empty, it still paints out what was there.
                marks[index].text = text
                let size = AnnotationRenderer.textSize(text, style: marks[index].style, width: 10_000)
                marks[index].rect.size.width = max(marks[index].rect.width, size.width)
                marks[index].rect.size.height = max(marks[index].rect.height, size.height)
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

    var body: some View {
        HStack(spacing: 6) {
            // Style and context controls scroll sideways in a narrow window; undo, delete and show stay put.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { styleControls }
            }
            Spacer(minLength: 4)
            trailing
        }
        .buttonStyle(.borderless)
        .font(.system(size: 16))
        .imageScale(.large)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var styleControls: some View {
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
    }

    @ViewBuilder private var trailing: some View {
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
            Image(nsImage: Self.swatch(editor.style.color, size: 20))
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

/// The tools, in a column beside the picture, grouped by what they're for. Select is on
/// top; each group's tools follow under a small heading.
struct ToolPalette: View {
    @State private var editor = AnnotationEditor.shared

    enum Item: Hashable {
        case tool(AnnotationEditor.Tool, symbol: String, help: String)
        case rotate(clockwise: Bool)
        case adjustMenu
        case smartRedact
        case simplify
    }

    static let groups: [(title: String, items: [Item])] = [
        ("Shapes", [.rectangle, .ellipse, .line, .arrow].map(drawItem)),
        ("Text", [.text, .callout, .step, .stamp].map(drawItem)),
        ("Draw", [.pen, .highlighter].map(drawItem)),
        ("Focus", [.spotlight, .magnify].map(drawItem)),
        ("Hide", [.blur, .pixelate, .redact].map(drawItem) + [.smartRedact]),
        ("Smart", [.editText, .move].map(drawItem) + [.simplify]),
        ("Adjust", [
            .tool(.crop, symbol: "crop", help: "Crop: drag out the part to keep, drag the corners to adjust, Return when done (Y)"),
            .tool(.cut(.horizontal), symbol: "rectangle.split.1x2", help: "Cut out a strip across: drag over the rows to take out"),
            .tool(.cut(.vertical), symbol: "rectangle.split.2x1", help: "Cut out a strip down: drag over the columns to take out"),
            .rotate(clockwise: false), .rotate(clockwise: true), .adjustMenu,
        ]),
    ]

    static func drawItem(_ kind: Annotation.Kind) -> Item {
        let key = AnnotationLayerView.toolKeys.first { $0.value == .draw(kind) }?.key.uppercased()
        return .tool(.draw(kind), symbol: kind.symbol, help: kind.title + (key.map { " (\($0))" } ?? ""))
    }

    private let columns = [GridItem(.fixed(36), spacing: 4), GridItem(.fixed(36), spacing: 4)]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                button(.tool(.select, symbol: "cursorarrow", help: "Select, move and resize (V)"))
                ForEach(Self.groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.title.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                            ForEach(group.items, id: \.self) { item in button(item) }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .frame(width: 92)
        .buttonStyle(.borderless)
    }

    @ViewBuilder private func button(_ item: Item) -> some View {
        switch item {
        case .tool(let tool, let symbol, let help):
            let on = editor.tool == tool
            Button { editor.pick(tool) } label: { icon(symbol, on: on) }
                .help(help)
        case .rotate(let clockwise):
            Button {
                editor.editEdits(clockwise ? "Rotate Right" : "Rotate Left") { $0 = $0.rotated(clockwise: clockwise) }
            } label: { icon(clockwise ? "rotate.right" : "rotate.left", on: false) }
                .help(clockwise ? "Rotate right" : "Rotate left")
        case .adjustMenu:
            AdjustMenu(compact: true)
        case .smartRedact:
            Menu {
                Button("Hide Sensitive Info with Black Boxes") { editor.smartRedact(with: .redact) }
                Button("Hide Sensitive Info with Blur") { editor.smartRedact(with: .blur) }
                Button("Hide Sensitive Info with Pixels") { editor.smartRedact(with: .pixelate) }
            } label: { icon("wand.and.stars", on: false) }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Smart Redact: find email addresses, phone numbers, card numbers and more, and hide them")
        case .simplify:
            Menu {
                Button("Simplify in Its Own Colors") { editor.simplify(.original) }
                Button("Simplify in Grays") { editor.simplify(.grays) }
                if editor.annotations.contains(where: { $0.kind == .simplify }) {
                    Divider()
                    Button("Remove Simplify") { editor.removeSimplify() }
                }
            } label: {
                if editor.simplifying { ProgressView().controlSize(.small).frame(width: 36, height: 34) } else { icon("rectangle.3.group", on: false) }
            }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Simplify: redraw the picture as plain shapes, a bar for each line of text and a box for each part")
        }
    }

    private func icon(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18))
            .frame(width: 36, height: 34)
            .background(on ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(on ? Color.accentColor : .primary)
            .contentShape(Rectangle())
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

// MARK: - Adjust menu

/// Crop, cut-outs, rotation, size, border, edges, background and Smart Redact: changes to
/// the finished picture, each undoable and none touching the original.
struct AdjustMenu: View {
    /// Drawn as a large palette button, rather than a small toolbar one.
    var compact = false
    @State private var editor = AnnotationEditor.shared

    var body: some View {
        let edits = editor.edits
        Menu {
            Section {
                Button("Crop") { editor.pick(.crop) }
                if edits.crop != nil { Button("Remove Crop") { editor.editEdits("Remove Crop") { $0.crop = nil } } }
                Button("Rotate Left") { editor.editEdits("Rotate Left") { $0 = $0.rotated(clockwise: false) } }
                Button("Rotate Right") { editor.editEdits("Rotate Right") { $0 = $0.rotated(clockwise: true) } }
                Button("Resize…") { editor.showResize = true }
            }
            Section("Cut Out") {
                Button("Cut Out a Strip Across") { editor.pick(.cut(.horizontal)) }
                Button("Cut Out a Strip Down") { editor.pick(.cut(.vertical)) }
                Picker("Seam", selection: Binding(get: { editor.seam }, set: { editor.setSeam($0) })) {
                    ForEach(CutOut.Seam.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if !edits.cuts.isEmpty { Button("Remove All Cut-Outs") { editor.editEdits("Remove Cut-Outs") { $0.cuts = [] } } }
            }
            Section("Frame") {
                Menu("Border") {
                    Button("None") { editor.editEdits("Remove Border") { $0.border = nil } }
                    ForEach([("Thin", 2.0), ("Medium", 5.0), ("Thick", 10.0)], id: \.0) { name, width in
                        Button(name) {
                            editor.editEdits("Border") { edits in
                                var border = edits.border ?? Border(color: editor.style.color)
                                border.width = width
                                edits.border = border
                            }
                        }
                    }
                    Divider()
                    Button("Use the Annotation Color") {
                        editor.editEdits("Border Color") { $0.border = ($0.border ?? Border()).withColor(editor.style.color) }
                    }
                    Toggle("Rounded Corners", isOn: Binding(get: { (edits.border?.cornerRadius ?? 0) > 0 }, set: { on in
                        editor.editEdits("Rounded Corners") { var b = $0.border ?? Border(width: 0); b.cornerRadius = on ? 12 : 0; $0.border = b }
                    }))
                    Toggle("Shadow", isOn: Binding(get: { edits.border?.shadow == true }, set: { on in
                        editor.editEdits("Shadow") { var b = $0.border ?? Border(width: 0); b.shadow = on; $0.border = b }
                    }))
                }
                Menu("Edges") {
                    Button("None") { editor.editEdits("Remove Edges") { $0.edges = nil } }
                    ForEach(EdgeEffect.Kind.allCases, id: \.self) { kind in
                        Button(kind.title) {
                            editor.editEdits("Edges") { $0.edges = EdgeEffect(kind: kind, sides: $0.edges?.sides ?? [.bottom]) }
                        }
                    }
                    Divider()
                    ForEach(Self.sideChoices, id: \.0) { name, sides in
                        Toggle(name, isOn: Binding(get: { edits.edges?.sides == sides }, set: { _ in
                            editor.editEdits("Edges") { $0.edges = EdgeEffect(kind: $0.edges?.kind ?? .torn, sides: sides) }
                        }))
                    }
                }
                Toggle("Remove Background", isOn: Binding(get: { edits.removeBackground }, set: { on in
                    editor.editEdits(on ? "Remove Background" : "Restore Background") { $0.removeBackground = on }
                }))
            }
            Section("Smart Redact") {
                Button("Hide Sensitive Info with Black Boxes") { editor.smartRedact(with: .redact) }
                Button("Hide Sensitive Info with Blur") { editor.smartRedact(with: .blur) }
                Button("Hide Sensitive Info with Pixels") { editor.smartRedact(with: .pixelate) }
            }
            if !edits.isEmpty {
                Divider()
                Button("Reset All Adjustments") { editor.commitEdits(.none, action: "Reset Adjustments") }
            }
        } label: {
            if editor.redacting { ProgressView().controlSize(.small) } else if compact {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18))
                    .frame(width: 36, height: 34)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            } else { Image(systemName: "slider.horizontal.3") }
        }
        .modifier(MenuLook(tile: compact))
        .menuIndicator(compact ? .hidden : .visible)
        .fixedSize()
        .help("Adjust: crop, cut out, rotate, resize, border, edges, remove background, hide sensitive info")
    }

    /// In the palette the menu shows its label as a full tile; in a toolbar, as a small button.
    struct MenuLook: ViewModifier {
        let tile: Bool

        func body(content: Content) -> some View {
            if tile { content.menuStyle(.button).buttonStyle(.plain) } else { content.menuStyle(.borderlessButton) }
        }
    }

    static let sideChoices: [(String, Set<EdgeEffect.Side>)] = [
        ("Bottom", [.bottom]), ("Bottom and Right", [.bottom, .right]), ("Top and Bottom", [.top, .bottom]),
        ("All Sides", [.top, .bottom, .left, .right]),
    ]
}

private extension Border {
    func withColor(_ color: RGBA) -> Border {
        var copy = self
        copy.color = color
        if copy.width == 0 { copy.width = 5 }
        return copy
    }
}

// MARK: - Resize

/// Sets the size the finished picture comes out at.
struct ResizeSheet: View {
    @State private var editor = AnnotationEditor.shared
    @State private var width = 0
    @State private var height = 0
    @Environment(\.dismiss) private var dismiss

    /// The size before resizing (cropped, cut and turned), in points.
    private var natural: CGSize {
        guard let item = editor.item else { return CGSize(width: 1, height: 1) }
        var edits = item.edits
        edits.outputScale = 1
        return edits.outputSize(for: item.pointSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Resize").font(.headline)
            Text("The finished picture is \(Int(natural.width)) × \(Int(natural.height)) points at full size. The capture itself keeps all its pixels.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Width", value: Binding(get: { width }, set: { width = $0; height = Int((Double($0) * natural.height / natural.width).rounded()) }),
                          format: .number).frame(width: 80)
                Text("×")
                TextField("Height", value: Binding(get: { height }, set: { height = $0; width = Int((Double($0) * natural.width / natural.height).rounded()) }),
                          format: .number).frame(width: 80)
                Text("points").foregroundStyle(.secondary)
            }
            HStack {
                ForEach([25, 50, 75, 100, 150, 200], id: \.self) { percent in
                    Button("\(percent)%") { set(Double(percent) / 100) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Resize") {
                    let factor = Double(width) / Double(max(natural.width, 1))
                    editor.editEdits("Resize") { $0.outputScale = min(max(factor, 0.05), 4) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(width < 8 || height < 8)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { set(editor.edits.outputScale) }
    }

    private func set(_ factor: Double) {
        width = Int((natural.width * factor).rounded())
        height = Int((natural.height * factor).rounded())
    }
}
