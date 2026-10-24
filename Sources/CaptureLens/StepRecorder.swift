import AppKit
import CaptureLensKit
import SwiftUI

/// Records a how-to as you do it: at every click it captures the window you clicked in,
/// marks the spot with a numbered step and a ring, and names the step from the text under
/// the pointer ("Click “Save”"). The steps go into the library, tagged together, ready to
/// become a guide.
@Observable
@MainActor
final class StepRecorder {
    static let shared = StepRecorder()

    private(set) var isRecording = false
    private(set) var steps: [UUID] = []
    private(set) var tag = ""

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var panel: FloatingPanel?
    @ObservationIgnored private var lastClick = Date.distantPast
    /// Clicks are captured one after another, in order.
    @ObservationIgnored private var queue: Task<Void, Never>?

    func start() {
        guard !isRecording else { return }
        guard ScreenAccess.granted else {
            ScreenAccess.request()
            if !ScreenAccess.granted { ScreenAccess.explainDenied() }
            return
        }
        isRecording = true
        steps = []
        tag = "Steps " + Date().formatted(date: .abbreviated, time: .shortened)
        // Clicks in other apps; CaptureLens's own windows (this panel) don't report here.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            let point = NSEvent.mouseLocation
            MainActor.assumeIsolated { StepRecorder.shared.clicked(at: point) }
        }
        showPanel()
        Notice.shared.show("Recording steps: click through what you're showing", symbol: "record.circle")
    }

    func stop(makeGuide: Bool) {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.orderOut(nil)
        panel = nil
        let recorded = steps
        let title = tag
        Task {
            // Let the last capture land before the guide looks for it.
            await queue?.value
            guard !recorded.isEmpty else { return }
            if makeGuide {
                LibraryWindow.shared.show(select: recorded.last)
                LibraryWindow.shared.state.guide = GuideRequest(items: recorded, title: title.replacingOccurrences(of: "Steps ", with: "How To · "),
                                                                template: .steps)
            } else {
                LibraryWindow.shared.show(select: recorded.last)
            }
        }
    }

    private func clicked(at point: CGPoint) {
        // A double-click is one step.
        guard isRecording, Date().timeIntervalSince(lastClick) > 0.45 else { return }
        lastClick = Date()
        let windows = ScreenWindow.onScreen()
        let window = windows.first { $0.frame.contains(point) }
        let previous = queue
        queue = Task {
            await previous?.value
            await capture(at: point, window: window, windows: windows)
        }
    }

    private func capture(at point: CGPoint, window: ScreenWindow?, windows: [ScreenWindow]) async {
        let image: CGImage, frame: CGRect, display: CGDirectDisplayID?
        do {
            if let window {
                (image, frame) = try await ScreenGrabber.captureWindow(window.id, shadow: false)
                display = nil
            } else {
                guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return }
                image = try await ScreenGrabber.captureDisplay(screen.displayID)
                frame = screen.frame
                display = screen.displayID
            }
        } catch {
            NSLog("CaptureLens: step capture failed: \(error.localizedDescription)")
            return
        }
        let scale = frame.width > 0 ? Double(image.width) / frame.width : 2
        // The click in the picture's points, origin at its top left.
        let spot = CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
        let source = SourceInfo.describe(frame: frame, windows: windows, window: window, display: display)
        let label = await Self.label(near: spot, in: image, scale: scale)
        let number = steps.count + 1
        let action = label.map { "Click “\($0)”" } ?? "Click in \(source.windowTitle ?? source.appName ?? "the window")"
        let store = LibraryStore.shared
        guard var item = store.add(image: image, kind: window == nil ? .screen : .window, scale: scale, source: source, cursor: nil) else { return }
        ActivityStore.shared.recordCapture(item.kind, steps: true)
        item.name = "Step \(number): \(action)"
        item.nameIsAutomatic = false
        item.notes = action + (source.appName.map { " in \($0)" } ?? "") + "."
        item.tags = LibraryQuery.normalizedTags(item.tags + [tag])
        let ring = AnnotationStyle(color: .red, lineWidth: 3, shadow: true)
        let badge = CGRect(x: max(4, spot.x - 46), y: max(4, spot.y - 46), width: 30, height: 30)
        item.annotations = [
            Annotation(kind: .ellipse, rect: CGRect(x: spot.x - 20, y: spot.y - 20, width: 40, height: 40), style: ring),
            Annotation(kind: .step, rect: badge, style: AnnotationStyle(color: .red, fontSize: 16)),
        ]
        store.update(item)
        steps.append(item.id)
        Sounds.shutter()
    }

    /// The words under the click, read from a strip of the picture around it.
    static func label(near spot: CGPoint, in image: CGImage, scale: Double) async -> String? {
        let box = CGRect(x: spot.x - 180, y: spot.y - 24, width: 360, height: 48)
        let pixels = CGRect(x: box.minX * scale, y: box.minY * scale, width: box.width * scale, height: box.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixels.isEmpty, let strip = image.cropping(to: pixels), let lines = try? await Recognizer.lines(in: strip) else { return nil }
        // The line nearest the click (Vision's boxes are 0–1 with the origin at the bottom left).
        let click = CGPoint(x: (spot.x * scale - pixels.minX) / pixels.width, y: 1 - (spot.y * scale - pixels.minY) / pixels.height)
        let nearest = lines.min { a, b in
            hypot(a.box.midX - click.x, a.box.midY - click.y) < hypot(b.box.midX - click.x, b.box.midY - click.y)
        }
        guard let text = nearest?.text.trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 2 else { return nil }
        return text.count > 40 ? String(text.prefix(39)) + "…" : text
    }

    private func showPanel() {
        let panel = FloatingPanel(title: "Recording Steps", size: CGSize(width: 300, height: 90), resizable: false)
        panel.host(StepPanelView())
        if let screen = NSScreen.main {
            panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.maxX - panel.frame.width - 20, y: screen.visibleFrame.maxY - panel.frame.height - 20))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

private struct StepPanelView: View {
    @State private var recorder = StepRecorder.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "record.circle").foregroundStyle(.red).symbolEffect(.pulse)
                Text(recorder.steps.isEmpty ? "Click through what you're showing." : "\(recorder.steps.count) step\(recorder.steps.count == 1 ? "" : "s") recorded")
                    .font(.callout.weight(.medium))
            }
            HStack {
                Button("Stop") { recorder.stop(makeGuide: false) }
                Spacer()
                Button("Stop and Make a Guide") { recorder.stop(makeGuide: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(recorder.steps.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

// MARK: - Guides

/// Which captures to make a guide from, and how.
struct GuideRequest: Identifiable, Equatable {
    let id = UUID()
    var items: [UUID]
    var title: String
    var template: GuideTemplate
}

/// Lays captures out as a step-by-step guide, reference sheet or timeline, then exports it
/// as a PDF or picture, or saves it into the library.
struct GuideSheet: View {
    @State var request: GuideRequest
    @State private var store = LibraryStore.shared
    @State private var preview: NSImage?
    @Environment(\.dismiss) private var dismiss

    private var items: [CaptureItem] { request.items.compactMap { store.entry($0) } }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Make a Guide").font(.headline)
                Picker("Layout", selection: $request.template) {
                    ForEach(GuideTemplate.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                TextField("Title", text: $request.title)
                Text("Captures, in order").font(.caption).foregroundStyle(.secondary)
                List {
                    ForEach(items) { item in
                        HStack {
                            Text(item.name).lineLimit(1)
                            Spacer()
                            Button { remove(item.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                    .onMove { request.items.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minHeight: 180)
                Text("Drag to reorder. Each capture's name is its heading; its More Info notes go under it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Menu("Export") {
                        Button("PDF…") { export(pdf: true) }
                        Button("Picture (PNG)…") { export(pdf: false) }
                    }
                    .fixedSize()
                    Button("Save to Library") { saveToLibrary() }
                        .keyboardShortcut(.defaultAction)
                }
                .disabled(items.isEmpty)
            }
            .frame(width: 300)
            ScrollView {
                if let preview {
                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
                        .padding(8)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .frame(width: 360, height: 480)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
        .task(id: "\(request.template)|\(request.title)|\(request.items)") { await renderPreview() }
    }

    private func document() -> GuideRenderer.Document {
        let entries = items.compactMap { item -> GuideEntry? in
            guard let image = Flattener.image(item) else { return nil }
            let size = item.edits.outputSize(for: item.pointSize)
            return GuideEntry(image: image, pointSize: size, title: item.name, text: item.notes, date: item.created)
        }
        let dates = items.map(\.created)
        let subtitle = dates.min().map { $0.formatted(date: .long, time: .omitted) } ?? ""
        return GuideRenderer.Document(template: request.template, title: request.title, subtitle: subtitle, entries: entries)
    }

    private func renderPreview() async {
        try? await Task.sleep(for: .milliseconds(150))
        guard let image = GuideRenderer.image(document(), width: 900, scale: 1) else { return }
        preview = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
    }

    private func remove(_ id: UUID) {
        request.items.removeAll { $0 == id }
    }

    private func export(pdf: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = request.title
        panel.allowedContentTypes = [pdf ? .pdf : .png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let doc = document()
        let data = pdf ? GuideRenderer.pdf(doc) : GuideRenderer.image(doc).flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
        do {
            guard let data else { throw GrabError(message: "Couldn't make the guide.") }
            try data.write(to: url)
            dismiss()
        } catch {
            Notice.shared.show(error: error.localizedDescription)
        }
    }

    /// The guide as a picture in the library, tagged like its steps.
    private func saveToLibrary() {
        guard let image = GuideRenderer.image(document()) else { return }
        let tags = Set(items.flatMap(\.tags))
        if var item = store.add(image: image, kind: .imported, scale: 2, source: .init(), cursor: nil) {
            item.name = request.title
            item.nameIsAutomatic = false
            item.tags = LibraryQuery.normalizedTags(Array(tags) + ["Guide"])
            store.update(item)
            LibraryWindow.shared.state.reveal(item.id)
        }
        dismiss()
    }
}

// MARK: - Exporting many

/// Which captures to export at once.
struct ExportRequest: Identifiable, Equatable {
    let id = UUID()
    var items: [UUID]
}

/// Exports several captures in one go, all in the same format, size and frame.
struct BatchExportSheet: View {
    let request: ExportRequest
    @State private var format = Exporter.Format.png
    @State private var size = 1.0
    @State private var frame = FrameChoice.asIs
    @State private var naming = Naming.name
    @State private var working = false
    @Environment(\.dismiss) private var dismiss

    enum FrameChoice: String, CaseIterable {
        case asIs, border, shadow, torn

        var title: String {
            switch self {
            case .asIs: "As each capture is"
            case .border: "Add a thin border"
            case .shadow: "Add rounded corners and a shadow"
            case .torn: "Add a torn bottom edge"
            }
        }
    }

    enum Naming: String, CaseIterable {
        case name, dateName, numbered

        var title: String {
            switch self {
            case .name: "Capture name"
            case .dateName: "Date, then name"
            case .numbered: "Numbered (01, 02…), then name"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("Format", selection: $format) {
                        ForEach(Exporter.Format.available, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Size", selection: $size) {
                        Text("Full size").tag(1.0)
                        Text("75%").tag(0.75)
                        Text("50%").tag(0.5)
                        Text("25%").tag(0.25)
                    }
                    Picker("Frame", selection: $frame) {
                        ForEach(FrameChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("File names", selection: $naming) {
                        ForEach(Naming.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Export \(request.items.count) captures")
                } footer: {
                    Text("Each comes out as it looks in Result, with its marks and adjustments, plus the frame chosen here. The captures themselves don't change.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose Folder and Export…") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
            }
            .padding()
        }
        .frame(width: 460)
    }

    private func run() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        working = true
        let written = Self.export(request.items, format: format, size: size, frame: frame, naming: naming, to: folder)
        working = false
        Notice.shared.show("Exported \(written) of \(request.items.count) capture\(request.items.count == 1 ? "" : "s")", symbol: "square.and.arrow.down")
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        dismiss()
    }

    /// Writes each capture into `folder`; returns how many were written. Names never clash
    /// with each other or with files already there.
    @discardableResult
    static func export(_ ids: [UUID], format: Exporter.Format, size: Double, frame: FrameChoice, naming: Naming, to folder: URL) -> Int {
        let store = LibraryStore.shared
        let ext = format.type.preferredFilenameExtension ?? format.rawValue.lowercased()
        var written = 0
        var used = Set<String>()
        for (index, id) in ids.enumerated() {
            guard var item = store.entry(id) else { continue }
            // Recordings go out as their finished video, whatever the picture format.
            let video = item.kind == .video && VideoStore.shared.has(id)
            let ext = video ? "mp4" : ext
            let base = name(for: item, index: index + 1, naming: naming)
            var candidate = base
            var n = 2
            while used.contains(candidate.lowercased()) || FileManager.default.fileExists(atPath: folder.appending(path: "\(candidate).\(ext)").path) {
                candidate = "\(base) \(n)"
                n += 1
            }
            let target = folder.appending(path: "\(candidate).\(ext)")
            if video {
                guard let file = VideoExport.temporaryFile(item), (try? FileManager.default.copyItem(at: file, to: target)) != nil else { continue }
                used.insert(candidate.lowercased())
                written += 1
                continue
            }
            apply(frame, to: &item.edits)
            item.edits.outputScale *= size
            guard let image = Flattener.image(item) else { continue }
            used.insert(candidate.lowercased())
            if Exporter.write(image, of: item, as: format, to: target) { written += 1 }
        }
        ActivityStore.shared.record(ActivityKey.exports, count: written)
        return written
    }

    private static func name(for item: CaptureItem, index: Int, naming: Naming) -> String {
        let clean = item.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
        switch naming {
        case .name: return clean
        case .dateName: return "\(CaptureNaming.stamp(item.created)) \(clean)"
        case .numbered: return String(format: "%02d ", index) + clean
        }
    }

    static func apply(_ frame: FrameChoice, to edits: inout ImageEdits) {
        switch frame {
        case .asIs: break
        case .border: edits.border = Border(width: 2, color: RGBA(0.75, 0.75, 0.78))
        case .shadow: edits.border = Border(width: 0, color: .black, cornerRadius: 10, shadow: true)
        case .torn: edits.edges = EdgeEffect(kind: .torn, sides: [.bottom])
        }
    }
}
