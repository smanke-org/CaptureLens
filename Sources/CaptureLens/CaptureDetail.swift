import AppKit
import CaptureLensKit
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// The selected capture: the picture (with Live Text, so its text can be selected and
/// copied right there) above its name, tags, notes and where it came from.
struct CaptureDetail: View {
    @Bindable var state: LibraryState
    @State private var store = LibraryStore.shared

    var body: some View {
        let selected = state.selectedItems
        Group {
            if selected.count == 1, let item = selected.first {
                SingleCaptureView(state: state, item: item).id(item.id)
            } else if selected.count > 1 {
                MultipleCapturesView(state: state, items: selected)
            } else {
                ContentUnavailableView("No Capture Selected", systemImage: "photo",
                                       description: Text("Click a capture to see it, its text and its details."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SingleCaptureView: View {
    @Bindable var state: LibraryState
    let item: CaptureItem
    /// Just the picture and its tools, for the pop-out editor window.
    var pictureOnly = false
    @State private var editorWindow = EditorWindow.shared
    @State private var store = LibraryStore.shared
    @State private var zoomToFit = 0
    @State private var editor = AnnotationEditor.shared
    /// A pane folded away to give the other all the room; remembered between captures.
    @AppStorage("library.collapsedPane", store: AppDefaults.store) private var collapsedRaw = ""
    private var collapsed: Pane? {
        get { Pane(rawValue: collapsedRaw) }
        nonmutating set { withAnimation(.easeInOut(duration: 0.2)) { collapsedRaw = newValue?.rawValue ?? "" } }
    }

    enum Pane: String { case picture, details }

    private var details: some View {
        CaptureInspector(state: state, item: item)
            .frame(minHeight: 180, idealHeight: 300)
    }

    private func fit() { zoomToFit += 1 }

    static let barFontSize: CGFloat = 16

    /// Edit/Result, then whatever fits.
    private func barRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            // On: mark up the original. Off: the finished picture, as it's copied and saved.
            Toggle("Edit", isOn: Binding(get: { !editor.showResult }, set: { editor.showResult = !$0 }))
                .toggleStyle(.switch)
                .fixedSize()
                .help(editor.showResult ? "Turn on to annotate and adjust the picture"
                                        : "Turn off to see the finished picture, as it's copied and saved")
            content()
        }
        // A quarter bigger than standard, so the buttons are easy to hit.
        .font(.system(size: Self.barFontSize))
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder private var actionButtons: some View {
        Button { copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
            .help("Copy")
        Button { Exporter.save(item) } label: { Label("Save As…", systemImage: "square.and.arrow.down") }
            .help("Save As…")
        ShareButton(items: { [item] }, pointSize: Self.barFontSize).fixedSize().help("Share")
        Button { store.toggleFavorite([item.id]) } label: {
            Label("Favorite", systemImage: item.favorite ? "star.fill" : "star")
        }
        .help(item.favorite ? "Remove from Favorites" : "Add to Favorites")
    }

    @ViewBuilder private var deleteAndPanes: some View {
        Button(role: .destructive) { state.confirmDelete = [item.id] } label: { Label("Delete", systemImage: "trash") }
            .help("Delete…")
        Divider().frame(height: 16)
        if pictureOnly {
            Button { editorWindow.close() } label: { Label("Bring Back", systemImage: "arrow.down.right.and.arrow.up.left") }
                .help("Put the picture back in the library window")
        } else {
            Button { collapsed = .details } label: { Label("Hide Details", systemImage: "chevron.down.circle") }
                .help("Hide the details, for more room to annotate")
            Button { collapsed = .picture } label: { Label("Hide Picture", systemImage: "chevron.up.circle") }
                .help("Hide the picture, for more room for the details")
            Button { editorWindow.open() } label: { Label("Open in Its Own Window", systemImage: "macwindow.badge.plus") }
                .help("Open the picture and its tools in a window of their own, as big as you like")
        }
    }

    /// Everything the narrow bar has no room for.
    private func moreMenu(includeZoom: Bool) -> some View {
        Menu {
            Button("Copy") { copy() }
            Button("Save As…") { Exporter.save(item) }
            Button("Share…") { ShareButton.shareAtPointer([item]) }
            Button(item.favorite ? "Remove from Favorites" : "Add to Favorites") { store.toggleFavorite([item.id]) }
            Divider()
            if includeZoom {
                Button("Zoom In") { CanvasZoom.shared.step(in: true) }
                Button("Zoom Out") { CanvasZoom.shared.step(in: false) }
            }
            Button("Zoom to Fit") { fit() }
            Divider()
            if pictureOnly {
                Button("Bring Back to the Library") { editorWindow.close() }
            } else {
                Button("Hide Details") { collapsed = .details }
                Button("Hide Picture") { collapsed = .picture }
                Button("Open in Its Own Window") { editorWindow.open() }
            }
            Divider()
            Button("Delete…", role: .destructive) { state.confirmDelete = [item.id] }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Copy, save, share, zoom and more")
    }

    private func copy() {
        if item.kind == .video { return VideoExport.copy(item) }
        if let png = Flattener.png(item) { Clipboard.copy(png: png); Notice.shared.show("Copied"); ActivityStore.shared.record(ActivityKey.copies) }
    }

    private var pictureArea: some View {
        VStack(spacing: 0) {
            if item.kind == .video {
                VideoPane(item: item).frame(minHeight: 200)
            } else if editor.showResult {
                ResultBar(item: item)
                Divider()
                ResultCanvas(item: item, fitRequest: zoomToFit + CanvasZoom.shared.fitRequested)
                    .frame(minHeight: 200)
            } else {
                AnnotationToolbar()
                Divider()
                HStack(spacing: 0) {
                    ToolPalette()
                    Divider()
                    CaptureCanvas(item: item, fitRequest: zoomToFit + CanvasZoom.shared.fitRequested, editor: editorState)
                }
                .frame(minHeight: 200)
            }
            // The whole bar when there's room; in a narrow window the less used buttons move into
            // a ⋯ menu, then zooming too, so the bar never pushes the column past the window.
            ViewThatFits(in: .horizontal) {
                if item.kind == .video {
                    // A video has no zooming; its player fits the space.
                    barRow { actionButtons; Spacer(minLength: 4); deleteAndPanes }
                    barRow { Spacer(minLength: 4); moreMenu(includeZoom: false) }
                } else {
                    barRow { actionButtons; Spacer(minLength: 4); ZoomControls(fit: fit); deleteAndPanes }
                    barRow { actionButtons; Spacer(minLength: 4); ZoomControls(fit: fit, compact: true); deleteAndPanes }
                    barRow { Spacer(minLength: 4); ZoomControls(fit: fit, compact: true); moreMenu(includeZoom: false) }
                    barRow { Spacer(minLength: 4); moreMenu(includeZoom: true) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// What the drawing layer shows, so it redraws when any of it changes.
    private var editorState: CaptureCanvas.EditorState {
        .init(tool: editor.tool, selection: editor.selection, showAnnotations: editor.showAnnotations, style: editor.style)
    }

    var body: some View {
        Group {
            if pictureOnly {
                pictureArea
            } else if editorWindow.isOpen {
                // The picture is in its own window; the details get all the room here.
                VStack(spacing: 0) {
                    CollapsedPaneBar(title: "Picture", symbol: "macwindow", edge: .top, note: "In its own window",
                                     actionTitle: "Bring Back") { editorWindow.close() }
                    Divider()
                    details
                }
            } else {
            switch collapsed {
            case .picture:
                VStack(spacing: 0) {
                    CollapsedPaneBar(title: "Picture", symbol: "photo", edge: .top) { collapsed = nil }
                    Divider()
                    details
                }
            case .details:
                VStack(spacing: 0) {
                    pictureArea
                    Divider()
                    CollapsedPaneBar(title: "Details", symbol: "info.circle", edge: .bottom) { collapsed = nil }
                }
            case nil:
                VSplitView {
                    pictureArea
                    details
                }
            }
            }
        }
        .sheet(isPresented: $editor.showResize) { ResizeSheet() }
    }
}

/// A folded-away pane: its name and a button (or a click anywhere on it) to bring it back.
private struct CollapsedPaneBar: View {
    let title: String
    let symbol: String
    let edge: VerticalEdge
    var note: String? = nil
    var actionTitle: String? = nil
    let restore: () -> Void

    var body: some View {
        Button(action: restore) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(title).font(.callout.weight(.medium))
                if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Label(actionTitle ?? "Show \(title)", systemImage: edge == .bottom ? "chevron.up.circle" : "chevron.down.circle")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
        .help("Show the \(title.lowercased()) again")
    }
}

/// Above the finished picture: its size and what's been done to it.
private struct ResultBar: View {
    let item: CaptureItem

    var body: some View {
        let size = item.edits.outputSize(for: item.pointSize)
        HStack(spacing: 10) {
            Text("\(Int(size.width)) × \(Int(size.height)) points").monospacedDigit()
            if !summary.isEmpty { Text(summary).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            AdjustMenu()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var summary: String {
        let e = item.edits
        var parts: [String] = []
        if e.crop != nil { parts.append("cropped") }
        if !e.cuts.isEmpty { parts.append("\(e.cuts.count) cut-out\(e.cuts.count == 1 ? "" : "s")") }
        if e.rotation != 0 { parts.append("turned \(e.rotation * 90)°") }
        if abs(e.outputScale - 1) > 0.001 { parts.append("\(Int((e.outputScale * 100).rounded()))%") }
        if e.edges != nil { parts.append("edges") }
        if e.border != nil { parts.append("border") }
        if e.removeBackground { parts.append("background removed") }
        if !item.annotations.isEmpty { parts.append("\(item.annotations.count) mark\(item.annotations.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// The finished picture, zoomable, on a checkerboard so transparency shows.
struct ResultCanvas: NSViewRepresentable {
    let item: CaptureItem
    let fitRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 8
        scroll.backgroundColor = .underPageBackgroundColor
        let clip = CenteringClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        context.coordinator.scroll = scroll
        scroll.documentView = context.coordinator.imageView
        CanvasZoom.shared.attach(scroll)
        context.coordinator.show(item)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.show(item)
        context.coordinator.fitOnceSized()
        if context.coordinator.lastFit != fitRequest {
            context.coordinator.lastFit = fitRequest
            context.coordinator.fit()
        }
    }

    @MainActor
    final class Coordinator {
        weak var scroll: NSScrollView?
        let imageView = CheckerImageView()
        var lastFit = 0
        private var shown: CaptureItem?

        func show(_ item: CaptureItem) {
            guard item != shown else { return }
            let first = shown?.id != item.id
            shown = item
            guard let image = Flattener.image(item) else { return }
            let pointsPerPixel = 1 / max(item.scale * item.edits.outputScale, 0.01)
            let size = CGSize(width: CGFloat(image.width) * pointsPerPixel, height: CGFloat(image.height) * pointsPerPixel)
            imageView.image = NSImage(cgImage: image, size: size)
            imageView.frame = CGRect(origin: .zero, size: size)
            if first {
                fitted = false
                fitOnceSized()
            }
        }

        private var fitted = false

        /// Fits the picture as soon as the view has its real size (it's tiny at first).
        func fitOnceSized() {
            guard !fitted, let scroll else { return }
            guard scroll.contentSize.width > 80, scroll.contentSize.height > 80 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.fitOnceSized() }
                return
            }
            fitted = true
            fit()
        }

        func fit() {
            guard let scroll, imageView.frame.width > 0 else { return }
            let available = scroll.contentSize
            let factor = min(1, min((available.width - 24) / imageView.frame.width, (available.height - 24) / imageView.frame.height))
            scroll.magnification = max(scroll.minMagnification, factor)
        }
    }
}

/// An image view that draws a checkerboard behind see-through parts.
final class CheckerImageView: NSImageView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        imageScaling = .scaleAxesIndependently
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let square: CGFloat = 8
        NSColor(white: 0.85, alpha: 1).setFill()
        bounds.fill()
        NSColor(white: 0.7, alpha: 1).setFill()
        var y: CGFloat = 0, row = 0
        while y < bounds.height {
            var x: CGFloat = row % 2 == 0 ? 0 : square
            while x < bounds.width {
                NSRect(x: x, y: y, width: square, height: square).fill()
                x += square * 2
            }
            y += square
            row += 1
        }
        super.draw(dirtyRect)
    }
}

private struct MultipleCapturesView: View {
    @Bindable var state: LibraryState
    let items: [CaptureItem]
    @State private var store = LibraryStore.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("\(items.count) captures selected").font(.title3.weight(.semibold))
            TagPicker(placeholder: "Add a tag to all") { tags in store.setTags(Set(items.map(\.id)), add: tags) }
                .frame(maxWidth: 360)
            HStack {
                Button("Make a Guide…") { state.makeGuide(from: items) }
                Button("Export…") { state.export = ExportRequest(items: items.map(\.id)) }
            }
            HStack {
                Button(items.allSatisfy(\.favorite) ? "Remove from Favorites" : "Add to Favorites") {
                    store.toggleFavorite(Set(items.map(\.id)))
                }
                Button("Delete…", role: .destructive) { state.confirmDelete = Set(items.map(\.id)) }
            }
        }
        .padding()
    }
}

// MARK: - Picture

/// The picture at its real size in a zoomable scroll view, with Live Text over it and the
/// pointer as a separate layer you can drag.
struct CaptureCanvas: NSViewRepresentable {
    let item: CaptureItem
    /// Changes when the Fit button is pressed.
    let fitRequest: Int
    let editor: EditorState

    struct EditorState: Equatable {
        var tool: AnnotationEditor.Tool
        var selection: UUID?
        var showAnnotations: Bool
        var style: AnnotationStyle
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ZoomingScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 8
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        let clip = CenteringClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        context.coordinator.attach(to: scroll)
        context.coordinator.load(item)
        CanvasZoom.shared.attach(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(item)
        context.coordinator.editorChanged(editor)
        if context.coordinator.lastFit != fitRequest {
            context.coordinator.lastFit = fitRequest
            context.coordinator.fit()
        }
    }

    @MainActor
    final class Coordinator {
        var lastFit = 0
        private weak var scroll: NSScrollView?
        private let canvas = FlippedView()
        private let imageView = NSImageView()
        private let overlay = ImageAnalysisOverlayView()
        private let annotationLayer = AnnotationLayerView()
        private let cursorView = CursorLayerView()
        private var lastEditor: EditorState?
        private var itemID: UUID?
        private var analysisTask: Task<Void, Never>?
        private static let analyzer = ImageAnalyzer()

        func attach(to scroll: NSScrollView) {
            self.scroll = scroll
            imageView.imageScaling = .scaleAxesIndependently
            imageView.imageFrameStyle = .none
            imageView.wantsLayer = true
            imageView.layer?.shadowOpacity = 0.25
            imageView.layer?.shadowRadius = 6
            imageView.layer?.shadowOffset = CGSize(width: 0, height: -2)
            canvas.addSubview(imageView)
            overlay.trackingImageView = imageView
            overlay.preferredInteractionTypes = .automatic
            overlay.autoresizingMask = [.width, .height]
            imageView.addSubview(overlay)
            canvas.addSubview(annotationLayer)
            canvas.addSubview(cursorView)
            scroll.documentView = canvas
        }

        func load(_ item: CaptureItem) {
            itemID = item.id
            guard let image = LibraryStore.shared.fullImage(item.id) else { return }
            imageView.image = image
            let size = image.size
            canvas.frame = CGRect(origin: .zero, size: size)
            imageView.frame = canvas.bounds
            overlay.frame = imageView.bounds
            overlay.analysis = nil
            AnnotationEditor.shared.open(item.id)
            annotationLayer.frame = canvas.bounds
            annotationLayer.baseImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            annotationLayer.refresh()
            updateCursor(item)
            DispatchQueue.main.async { self.fit() }
            analysisTask?.cancel()
            guard ImageAnalyzer.isSupported else { return }
            analysisTask = Task {
                let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])
                guard let analysis = try? await Self.analyzer.analyze(image, orientation: .up, configuration: configuration),
                      !Task.isCancelled, self.itemID == item.id else { return }
                self.overlay.analysis = analysis
            }
        }

        func update(_ item: CaptureItem) {
            if item.id != itemID { load(item) } else { updateCursor(item); annotationLayer.refresh() }
        }

        func editorChanged(_ state: EditorState) {
            guard state != lastEditor else { return }
            let toolChanged = state.tool != lastEditor?.tool
            lastEditor = state
            annotationLayer.refresh()
            if toolChanged {
                annotationLayer.window?.invalidateCursorRects(for: annotationLayer)
                // Drawing tools take the keyboard too (Delete, arrows, tool letters).
                if state.tool != .select { annotationLayer.window?.makeFirstResponder(annotationLayer) }
            }
        }

        private func updateCursor(_ item: CaptureItem) {
            guard let layer = item.cursor, layer.visible else { cursorView.isHidden = true; return }
            cursorView.isHidden = false
            cursorView.image = NSImage(data: layer.png)
            cursorView.frame = layer.frame
            cursorView.onMoved = { origin in
                guard var current = LibraryStore.shared.entry(item.id), var cursor = current.cursor else { return }
                cursor.x = origin.x
                cursor.y = origin.y
                current.cursor = cursor
                LibraryStore.shared.update(current)
            }
        }

        /// Zooms so the whole picture shows, never past 100%.
        private var fitTries = 0

        func fit() {
            guard let scroll, canvas.bounds.width > 0 else { return }
            let available = scroll.contentSize
            // Just shown, the view may not have its size yet; fitting then would shrink the
            // picture to almost nothing. Wait for it.
            guard available.width > 80, available.height > 80 else {
                if fitTries < 20 {
                    fitTries += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.fit() }
                }
                return
            }
            fitTries = 0
            let factor = min(1, min((available.width - 24) / canvas.bounds.width, (available.height - 24) / canvas.bounds.height))
            scroll.magnification = max(scroll.minMagnification, factor)
        }
    }
}

/// How far the picture is zoomed, shared by whichever canvas is showing (Edit or Result),
/// so the zoom slider and buttons work on it and follow pinches and ⌘-scrolls.
@Observable
@MainActor
final class CanvasZoom {
    static let shared = CanvasZoom()

    static let range: ClosedRange<Double> = 0.05...8
    private(set) var magnification: Double = 1
    /// Bumped to fit the picture from outside its view (a new window, say).
    var fitRequested = 0
    @ObservationIgnored private weak var scroll: NSScrollView?
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// The canvas now showing.
    func attach(_ scroll: NSScrollView) {
        self.scroll = scroll
        if let observer { NotificationCenter.default.removeObserver(observer) }
        scroll.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteChange() }
        }
        noteChange()
    }

    func noteChange() {
        guard let scroll, abs(scroll.magnification - magnification) > 0.0005 else { return }
        magnification = scroll.magnification
    }

    /// Zooms to `value`, keeping the middle of what's in view in the middle.
    func set(_ value: Double) {
        guard let scroll else { return }
        let clamped = min(max(value, Self.range.lowerBound), Self.range.upperBound)
        let visible = scroll.contentView.bounds
        let center = CGPoint(x: visible.midX, y: visible.midY)
        scroll.setMagnification(clamped, centeredAt: scroll.contentView.convert(center, to: scroll.documentView))
        noteChange()
    }

    /// Steps through the usual zoom levels.
    func step(in zoomIn: Bool) {
        let levels: [Double] = [0.05, 0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8]
        let current = magnification
        let next = zoomIn ? levels.first { $0 > current + 0.001 } : levels.last { $0 < current - 0.001 }
        set(next ?? current)
    }
}

/// Zoom out, a zoom slider, zoom in, the zoom level, and Fit.
struct ZoomControls: View {
    let fit: () -> Void
    /// Without the slider and Fit, for a narrow bar.
    var compact = false
    @State private var zoom = CanvasZoom.shared

    var body: some View {
        HStack(spacing: 6) {
            Button { zoom.step(in: false) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                .disabled(zoom.magnification <= CanvasZoom.range.lowerBound + 0.001)
                .help("Zoom out")
            if !compact {
            Slider(value: Binding(get: { log2(zoom.magnification) }, set: { zoom.set(pow(2, $0)) }),
                   in: log2(CanvasZoom.range.lowerBound)...log2(CanvasZoom.range.upperBound))
                .frame(width: 100)
                .help("Zoom. Pinch or ⌘-scroll also zoom.")
            }
            Button { zoom.step(in: true) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                .disabled(zoom.magnification >= CanvasZoom.range.upperBound - 0.001)
                .help("Zoom in")
            Menu {
                ForEach([0.25, 0.5, 1, 2, 4], id: \.self) { level in
                    Button("\(Int(level * 100))%") { zoom.set(level) }
                }
                Divider()
                Button("Zoom to Fit", action: fit)
            } label: {
                Text("\(Int((zoom.magnification * 100).rounded()))%").monospacedDigit().frame(minWidth: 38)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Pick a zoom level")
            if !compact {
                Button(action: fit) { Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                    .help("Zoom to fit")
            }
        }
    }
}

/// The Edit view's scroll view: scrolling (mouse wheel or trackpad) zooms around the pointer
/// instead of moving the picture. Holding ⇧ scrolls as usual, to move around a zoomed picture.
///
/// Holding Space with the pointer over the picture turns the pointer into a hand, whatever
/// the tool: drag to move around the picture, let go of Space to carry on. Space still types
/// a space while a text box, the notes or any other text field is being typed in.
final class ZoomingScrollView: NSScrollView {
    private var monitor: Any?
    /// Space is held, so a drag moves the picture.
    private var panning = false
    /// Mid-drag, and where the pointer was last, in the window; the drag carries on if Space
    /// is let go first.
    private var grabbing = false
    private var lastPoint = CGPoint.zero

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return endPanning() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                                              .mouseMoved, .cursorUpdate]) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) }
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else {
            if panning, !grabbing { endPanning() }
            return event
        }
        switch event.type {
        case .keyDown where event.keyCode == 49: // Space
            if panning { return nil } // the key repeating
            guard window.isKeyWindow, isPointerOver(event), !isTyping(in: window),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            panning = true
            window.disableCursorRects()
            NSCursor.openHand.set()
            return nil
        case .keyUp where event.keyCode == 49:
            guard panning else { return event }
            if !grabbing { endPanning() } else { panning = false }
            return nil
        case .leftMouseDown where panning && isPointerOver(event):
            grabbing = true
            lastPoint = event.locationInWindow
            NSCursor.closedHand.set()
            return nil
        case .leftMouseDragged where grabbing:
            let point = event.locationInWindow
            pan(by: CGPoint(x: point.x - lastPoint.x, y: point.y - lastPoint.y))
            lastPoint = point
            return nil
        case .leftMouseUp where grabbing:
            grabbing = false
            if panning { NSCursor.openHand.set() } else { endPanning() }
            return nil
        case .mouseMoved, .cursorUpdate:
            guard panning else { return event }
            NSCursor.openHand.set()
            return nil
        default:
            return event
        }
    }

    private func endPanning() {
        guard panning || grabbing || window?.areCursorRectsEnabled == false else { return }
        panning = false
        grabbing = false
        window?.enableCursorRects()
        window?.invalidateCursorRects(for: self)
        window?.resetCursorRects()
        NSCursor.arrow.set()
    }

    private func isPointerOver(_ event: NSEvent) -> Bool {
        bounds.contains(convert(event.locationInWindow, from: nil))
    }

    /// Typing in a text box on the picture, or in any field, rather than editing the picture.
    private func isTyping(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        return responder is NSText || responder is NSTextField
    }

    #if DEBUG
    var debugPanning: (panning: Bool, grabbing: Bool) { (panning, grabbing) }
    #endif

    /// Moves the picture with the pointer: `delta` is in window points, up positive.
    private func pan(by delta: CGPoint) {
        let clip = contentView
        let scale = max(magnification, 0.01)
        var origin = clip.bounds.origin
        origin.x -= delta.x / scale
        origin.y += (clip.isFlipped ? delta.y : -delta.y) / scale
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        reflectScrolledClipView(clip)
    }

    override func scrollWheel(with event: NSEvent) {
        guard allowsMagnification, !event.modifierFlags.contains(.shift) else { return super.scrollWheel(with: event) }
        // A trackpad's coasting after the fingers lift would keep zooming; ignore it.
        guard event.momentumPhase.isEmpty else { return }
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        guard delta != 0 else { return }
        // Trackpads send many small, precise steps; mouse wheels a few big ones.
        let factor = exp(delta * (event.hasPreciseScrollingDeltas ? 0.01 : 0.12))
        let target = min(max(magnification * factor, minMagnification), maxMagnification)
        guard let document = documentView else { return }
        let pointer = document.convert(event.locationInWindow, from: nil)
        setMagnification(target, centeredAt: pointer)
        CanvasZoom.shared.noteChange()
    }
}

/// Keeps a document smaller than the view in the middle, rather than in the corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The pointer layer: drag it to move it.
final class CursorLayerView: NSImageView {
    var onMoved: ((CGPoint) -> Void)?
    private var grab: CGPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageScaling = .scaleAxesIndependently
        toolTip = "The pointer. Drag to move it; hide it or change its size in the details below."
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        grab = superview?.convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab, let point = superview?.convert(event.locationInWindow, from: nil) else { return }
        setFrameOrigin(CGPoint(x: frame.minX + point.x - grab.x, y: frame.minY + point.y - grab.y))
        self.grab = point
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
        grab = nil
        onMoved?(frame.origin)
    }
}

// MARK: - Details

struct CaptureInspector: View {
    @Bindable var state: LibraryState
    let item: CaptureItem
    @State private var store = LibraryStore.shared
    @State private var name = ""
    @State private var notes = ""
    @State private var showText = false
    /// Where the capture came from folds away like its text; open to start, remembered.
    @AppStorage("library.details.sourceOpen", store: AppDefaults.store) private var showSource = true
    @FocusState private var nameFocused: Bool

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Name", text: $name)
                        .focused($nameFocused)
                        .onSubmit { store.rename(item.id, to: name) }
                    if store.analyzing.contains(item.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { store.suggestName(item.id) } label: { Image(systemName: "apple.intelligence") }
                            .buttonStyle(.borderless)
                            .help(AutoNamer.unavailableReason ?? "Suggest a name from what's in the capture")
                    }
                }
                TagEditor(item: item)
                VStack(alignment: .leading, spacing: 4) {
                    Text("More Info").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $notes)
                        .font(.body)
                        .frame(minHeight: 60)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.25)))
                }
            }
            Section {
                DisclosureGroup(isExpanded: $showSource) {
                LabeledContent("Captured", value: item.created.formatted(date: .long, time: .standard))
                LabeledContent("Type", value: item.kind.title)
                if let app = item.source.appName {
                    LabeledContent("App") {
                        HStack(spacing: 4) {
                            if let id = item.source.bundleID { AppIcon(bundleID: id) }
                            Text(app)
                        }
                    }
                }
                if let title = item.source.windowTitle { LabeledContent("Window", value: title) }
                if let url = item.source.url, let link = URL(string: url) {
                    LabeledContent("Web page") {
                        Link(item.source.pageTitle ?? url, destination: link).lineLimit(1).truncationMode(.middle)
                    }
                }
                LabeledContent("Size", value: "\(Int(item.pointSize.width)) × \(Int(item.pointSize.height)) points (\(item.pixelWidth) × \(item.pixelHeight) pixels)")
                if let display = item.source.displayName { LabeledContent("Display", value: display) }
                } label: {
                    // Folded, the app and date say where it came from at a glance.
                    HStack {
                        Text("Source")
                        if !showSource {
                            Spacer()
                            Text([item.source.appName, item.created.formatted(date: .abbreviated, time: .omitted)].compactMap { $0 }.joined(separator: " · "))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            if item.cursor != nil {
                Section("Pointer") {
                    Toggle("Show the pointer", isOn: cursorBinding(\.visible))
                    if item.cursor?.visible == true {
                        LabeledContent("Size") {
                            Slider(value: cursorBinding(\.size), in: 0.5...4)
                        }
                        Text("Drag the pointer in the picture to move it. It's added when you copy, drag or save the capture.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                DisclosureGroup(isExpanded: $showText) {
                    if item.recognizedText.isEmpty {
                        Text(store.analyzing.contains(item.id) ? "Reading…" : "No text found.").foregroundStyle(.secondary)
                    } else {
                        Text(item.recognizedText).textSelection(.enabled).font(.callout)
                        Button("Copy All Text") { Clipboard.copy(text: item.recognizedText) }
                    }
                } label: {
                    Text("Text in the capture")
                }
            } footer: {
                Text("You can also select text right in the picture and copy it.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { name = item.name; notes = item.notes; if state.renaming == item.id { nameFocused = true; state.renaming = nil } }
        .onChange(of: item.name) { _, new in if !nameFocused { name = new } }
        .onChange(of: state.renaming) { _, id in if id == item.id { nameFocused = true; state.renaming = nil } }
        .onChange(of: nameFocused) { _, focused in if !focused { store.rename(item.id, to: name) } }
        .onChange(of: notes) { _, new in saveNotes(new) }
        .onDisappear { store.rename(item.id, to: name); saveNotes(notes) }
    }

    private func saveNotes(_ text: String) {
        guard var current = store.entry(item.id), current.notes != text else { return }
        current.notes = text
        store.update(current)
    }

    private func cursorBinding<T>(_ path: WritableKeyPath<CursorLayer, T>) -> Binding<T> {
        Binding(get: { item.cursor![keyPath: path] }, set: { value in
            guard var current = store.entry(item.id), current.cursor != nil else { return }
            current.cursor![keyPath: path] = value
            store.update(current)
        })
    }
}

/// The capture's tags as removable tokens, plus a field to add one (with suggestions from
/// tags already in use).
struct TagEditor: View {
    let item: CaptureItem
    @State private var store = LibraryStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !item.tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(item.tags, id: \.self) { tag in
                        HStack(spacing: 3) {
                            Text(tag)
                            Button { store.setTags([item.id], remove: [tag]) } label: { Image(systemName: "xmark").font(.caption2) }
                                .buttonStyle(.plain)
                                .help("Remove this tag")
                        }
                        .font(.callout)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
            }
            TagPicker(exclude: item.tags) { tags in store.setTags([item.id], add: tags) }
        }
    }
}

/// Adds tags: pick one you've used before from the list, or type a name to make a new one.
/// Typing narrows the list; Return takes the highlighted tag, or creates the typed one.
struct TagPicker: View {
    /// Tags already there, left out of the list.
    var exclude: [String] = []
    var placeholder = "Add a tag"
    let add: ([String]) -> Void
    @State private var store = LibraryStore.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    private var typed: String { text.trimmingCharacters(in: .whitespaces) }

    private var matches: [String] {
        let taken = Set(exclude.map(LibraryQuery.fold))
        let all = LibraryQuery.tagCounts(store.items).map(\.tag).filter { !taken.contains(LibraryQuery.fold($0)) }
        guard !typed.isEmpty else { return all }
        let query = LibraryQuery.fold(typed)
        // Names starting with what's typed first, then names containing it.
        return all.filter { LibraryQuery.fold($0).hasPrefix(query) } + all.filter {
            let name = LibraryQuery.fold($0)
            return !name.hasPrefix(query) && name.contains(query)
        }
    }

    /// The typed name isn't a tag yet.
    private var isNew: Bool {
        !typed.isEmpty && !LibraryQuery.tagCounts(store.items).contains { LibraryQuery.fold($0.tag) == LibraryQuery.fold(typed) }
            && !exclude.contains { LibraryQuery.fold($0) == LibraryQuery.fold(typed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(placeholder, text: $text, prompt: Text("Type a new tag, or pick one below"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .focused($focused)
                .onSubmit(submit)
            let list = matches
            if !list.isEmpty || isNew {
                FlowLayout(spacing: 6) {
                    if isNew {
                        Button { take(typed) } label: {
                            Label("Create “\(typed)”", systemImage: "plus")
                                .chip(tint: .accentColor, strong: true)
                        }
                        .buttonStyle(.plain)
                        .help("Make a new tag with this name")
                    }
                    ForEach(list.prefix(24), id: \.self) { tag in
                        Button { take(tag) } label: {
                            Label(tag, systemImage: "tag").chip(tint: .secondary, strong: !isNew && tag == list.first && !typed.isEmpty)
                        }
                        .buttonStyle(.plain)
                        .help("Add “\(tag)”")
                    }
                }
            } else if typed.isEmpty && LibraryQuery.tagCounts(store.items).isEmpty {
                Text("No tags yet. Type a name and press Return to make the first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Return: the typed name if it's new (commas make several), else the best match.
    private func submit() {
        guard !typed.isEmpty else { return }
        if typed.contains(",") {
            add(typed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            text = ""
        } else if !isNew, let best = matches.first {
            take(best)
        } else {
            take(typed)
        }
        focused = true
    }

    private func take(_ tag: String) {
        add([tag])
        text = ""
    }
}

private extension View {
    func chip(tint: Color, strong: Bool) -> some View {
        font(.callout)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(strong ? 0.25 : 0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(strong ? tint.opacity(0.6) : .clear))
    }
}

/// Lays out views left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Saving

@MainActor
enum Exporter {
    enum Format: String, CaseIterable {
        case png = "PNG", jpeg = "JPEG", heic = "HEIC", tiff = "TIFF", gif = "GIF", bmp = "BMP", pdf = "PDF"

        var type: UTType {
            switch self {
            case .png: .png
            case .jpeg: .jpeg
            case .heic: .heic
            case .tiff: .tiff
            case .gif: .gif
            case .bmp: .bmp
            case .pdf: .pdf
            }
        }

        /// The formats this Mac can write.
        static var available: [Format] {
            let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
            return allCases.filter { $0 == .pdf || writable.contains($0.type.identifier) }
        }
    }

    /// Asks where to save the capture (with its pointer, if shown) and in which format.
    static func save(_ item: CaptureItem) {
        if item.kind == .video { return VideoExport.save(item) }
        guard let image = Flattener.image(item) else { return NSSound.beep() }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: Format.available.map(\.rawValue))
        let last = Format(rawValue: AppDefaults.store.string(forKey: "export.format") ?? "") ?? .png
        popup.selectItem(withTitle: last.rawValue)
        panel.allowedContentTypes = [last.type]
        let accessory = NSStackView(views: [NSTextField(labelWithString: "Format:"), popup])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = accessory
        let handler = FormatHandler(panel: panel)
        popup.target = handler
        popup.action = #selector(FormatHandler.changed(_:))
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let format = Format(rawValue: popup.titleOfSelectedItem ?? "") ?? .png
        AppDefaults.store.set(format.rawValue, forKey: "export.format")
        if write(image, of: item, as: format, to: url) { ActivityStore.shared.record(ActivityKey.saves) } else { Notice.shared.show(error: "Couldn't save the picture") }
        withExtendedLifetime(handler) {}
    }

    /// Writes the finished picture in `format`; false if it couldn't.
    @discardableResult
    static func write(_ image: CGImage, of item: CaptureItem, as format: Format, to url: URL) -> Bool {
        if format == .pdf {
            // One page the size of the picture, in points.
            let pointsPerPixel = 1 / max(item.scale * item.edits.outputScale, 0.01)
            var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) * pointsPerPixel, height: CGFloat(image.height) * pointsPerPixel)
            guard let pdf = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle as String: item.name] as CFDictionary) else { return false }
            pdf.beginPDFPage(nil)
            pdf.interpolationQuality = .high
            pdf.draw(image, in: box)
            pdf.endPDFPage()
            pdf.closePDF()
            return true
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else { return false }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    @MainActor
    private final class FormatHandler: NSObject {
        weak var panel: NSSavePanel?
        init(panel: NSSavePanel) { self.panel = panel }
        @objc func changed(_ sender: NSPopUpButton) {
            if let format = Format(rawValue: sender.titleOfSelectedItem ?? "") { panel?.allowedContentTypes = [format.type] }
        }
    }
}

/// The picture and its tools in a window of their own, for room to work. It shows the capture
/// selected in the library (one editor at a time), and closing it puts the picture back.
@Observable
@MainActor
final class EditorWindow: NSObject, NSWindowDelegate {
    static let shared = EditorWindow()

    private(set) var isOpen = false
    @ObservationIgnored private var window: NSWindow?

    func open() {
        if window == nil {
            let hosting = NSHostingController(rootView: PoppedEditor(state: LibraryWindow.shared.state))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSScreen.fitting(NSSize(width: 1100, height: 800)))
            window.minSize = NSSize(width: 520, height: 420)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("CaptureLensEditor")
            if window.frame.origin == .zero { window.center() }
            self.window = window
        }
        let selected = LibraryWindow.shared.state.selectedItems
        window?.title = selected.count == 1 ? selected[0].name : "CaptureLens Editor"
        isOpen = true
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Fit the picture to the bigger room once it's laid out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { CanvasZoom.shared.fitRequested += 1 }
    }

    func close() {
        window?.close()
    }

    func setTitle(_ title: String) { window?.title = title }

    #if DEBUG
    var debugWindow: NSWindow? { window }
    #endif

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        // The window's views go, so the library's picture comes back fresh.
        window?.contentViewController = nil
        window = nil
        LibraryWindow.shared.window?.makeKeyAndOrderFront(nil)
    }
}

/// What the pop-out window shows: the selected capture's picture and tools.
private struct PoppedEditor: View {
    @Bindable var state: LibraryState
    @State private var store = LibraryStore.shared

    var body: some View {
        let selected = state.selectedItems
        Group {
            if selected.count == 1, let item = selected.first {
                SingleCaptureView(state: state, item: item, pictureOnly: true)
                    .id(item.id)
                    .onAppear { EditorWindow.shared.setTitle(item.name) }
                    .onChange(of: item.name) { _, name in EditorWindow.shared.setTitle(name) }
            } else {
                ContentUnavailableView("Select a Capture", systemImage: "photo",
                                       description: Text("Pick one capture in the library to edit it here."))
                    .onAppear { EditorWindow.shared.setTitle("CaptureLens Editor") }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}
