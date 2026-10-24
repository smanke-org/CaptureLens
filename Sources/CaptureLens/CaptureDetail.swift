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

private struct SingleCaptureView: View {
    @Bindable var state: LibraryState
    let item: CaptureItem
    @State private var store = LibraryStore.shared
    @State private var zoomToFit = 0

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                CaptureCanvas(item: item, fitRequest: zoomToFit)
                    .frame(minHeight: 200)
                HStack(spacing: 12) {
                    Button { if let png = Flattener.png(item) { Clipboard.copy(png: png); Notice.shared.show("Copied") } } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button { Exporter.save(item) } label: { Label("Save As…", systemImage: "square.and.arrow.up") }
                    Button { store.toggleFavorite([item.id]) } label: {
                        Label(item.favorite ? "Favorite" : "Favorite", systemImage: item.favorite ? "star.fill" : "star")
                    }
                    .help(item.favorite ? "Remove from Favorites" : "Add to Favorites")
                    Spacer()
                    Button { zoomToFit += 1 } label: { Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                        .help("Zoom to fit. Pinch or ⌘-scroll to zoom.")
                    Button(role: .destructive) { state.confirmDelete = [item.id] } label: { Label("Delete", systemImage: "trash") }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            CaptureInspector(state: state, item: item)
                .frame(minHeight: 180, idealHeight: 300)
        }
    }
}

private struct MultipleCapturesView: View {
    @Bindable var state: LibraryState
    let items: [CaptureItem]
    @State private var store = LibraryStore.shared
    @State private var newTag = ""

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("\(items.count) captures selected").font(.title3.weight(.semibold))
            HStack {
                TextField("Add a tag to all", text: $newTag).textFieldStyle(.roundedBorder).frame(width: 200)
                    .onSubmit(addTag)
                Button("Add Tag", action: addTag).disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
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

    private func addTag() {
        store.setTags(Set(items.map(\.id)), add: [newTag])
        newTag = ""
    }
}

// MARK: - Picture

/// The picture at its real size in a zoomable scroll view, with Live Text over it and the
/// pointer as a separate layer you can drag.
struct CaptureCanvas: NSViewRepresentable {
    let item: CaptureItem
    /// Changes when the Fit button is pressed.
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
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        let clip = CenteringClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        context.coordinator.attach(to: scroll)
        context.coordinator.load(item)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(item)
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
        private let cursorView = CursorLayerView()
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
            if item.id != itemID { load(item) } else { updateCursor(item) }
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
        func fit() {
            guard let scroll, canvas.bounds.width > 0 else { return }
            let available = scroll.contentSize
            let factor = min(1, min((available.width - 24) / canvas.bounds.width, (available.height - 24) / canvas.bounds.height))
            scroll.magnification = max(scroll.minMagnification, factor)
        }
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
            Section("Source") {
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
    @State private var newTag = ""

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
            HStack {
                TextField("Add a tag", text: $newTag)
                    .onSubmit(add)
                let suggestions = LibraryQuery.tagCounts(store.items).map(\.tag)
                    .filter { tag in !item.tags.contains { LibraryQuery.fold($0) == LibraryQuery.fold(tag) } }
                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions, id: \.self) { tag in Button(tag) { store.setTags([item.id], add: [tag]) } }
                    } label: { Image(systemName: "tag") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Add a tag you've used before")
                }
            }
        }
    }

    private func add() {
        // Commas add several at once.
        store.setTags([item.id], add: newTag.split(separator: ",").map(String.init))
        newTag = ""
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
        case png = "PNG", jpeg = "JPEG", heic = "HEIC", tiff = "TIFF"

        var type: UTType {
            switch self {
            case .png: .png
            case .jpeg: .jpeg
            case .heic: .heic
            case .tiff: .tiff
            }
        }
    }

    /// Asks where to save the capture (with its pointer, if shown) and in which format.
    static func save(_ item: CaptureItem) {
        guard let image = Flattener.image(item) else { return NSSound.beep() }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: Format.allCases.map(\.rawValue))
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
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else { return NSSound.beep() }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        if !CGImageDestinationFinalize(destination) { Notice.shared.show(error: "Couldn't save the picture") }
        withExtendedLifetime(handler) {}
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
