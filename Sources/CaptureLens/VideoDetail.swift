import AppKit
@preconcurrency import AVFoundation
import AVKit
import CaptureLensKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// A recording in the library: the player, and with Edit on, a timeline for trimming its
/// ends and cutting sections out of the middle. Nothing is cut from the movie itself; the
/// finished video is made when it's copied, dragged or saved.
struct VideoPane: View {
    let item: CaptureItem
    @State private var model = VideoModel()
    @State private var editor = AnnotationEditor.shared
    @State private var videos = VideoStore.shared
    @State private var prefs = Preferences.shared

    private var info: VideoInfo { item.video ?? VideoInfo(duration: 0) }

    var body: some View {
        VStack(spacing: 0) {
            if model.missing {
                missing
            } else if model.player == nil {
                ProgressView(videos.opening.contains(item.id) ? "Opening the video…" : "Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PlayerView(player: model.player!)
                    .frame(minHeight: 160)
                if !editor.showResult {
                    Divider()
                    VideoTimeline(item: item, model: model)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    VideoEditBar(item: item, model: model)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                } else {
                    Divider()
                    Text("The finished video: \(VideoModel.format(info.resultDuration))\(info.edits.isEmpty ? "" : " (trimmed or cut from \(VideoModel.format(info.duration)))")")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(8)
                }
            }
        }
        .task(id: item.id) {
            editor.open(item.id)
            await model.load(item, result: editor.showResult)
        }
        .onChange(of: editor.showResult) { _, result in model.rebuild(info, result: result) }
        .onChange(of: info.edits) { _, _ in if editor.showResult { model.rebuild(info, result: true) } }
        .onChange(of: videos.revision) { _, _ in
            if model.missing { Task { await model.load(item, result: editor.showResult) } }
        }
        .onDisappear { model.player?.pause() }
    }

    private var missing: some View {
        ZStack {
            if let image = LibraryStore.shared.fullImage(item.id) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).opacity(0.35).padding()
            }
            VStack(spacing: 8) {
                Image(systemName: "video.slash").font(.largeTitle).foregroundStyle(.secondary)
                Text("This video is on another Mac").font(.headline)
                Text(item.video?.staysOnMac == true
                     ? "It was imported on another Mac, and imported videos stay on the Mac that has them. Its name, tags and notes are here."
                     : prefs.syncVideos
                     ? "It arrives once the Mac that recorded it has synced it. Its name, tags and notes are here already."
                     : "Turn on “Sync video files” in Settings › Library on both Macs to play it here.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The movie, a player for it, and pictures along it for the timeline.
@Observable
@MainActor
final class VideoModel {
    private(set) var player: AVPlayer?
    private(set) var asset: AVAsset?
    private(set) var frames: [CGImage] = []
    private(set) var missing = false
    /// Where playback is, in the original recording's seconds.
    private(set) var time: Double = 0
    @ObservationIgnored private var info = VideoInfo(duration: 0)
    @ObservationIgnored private var showingResult = false
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var loadedID: UUID?

    func load(_ item: CaptureItem, result: Bool) async {
        info = item.video ?? VideoInfo(duration: 0)
        guard let url = await VideoStore.shared.playableURL(item.id) else {
            missing = true
            return
        }
        missing = false
        loadedID = item.id
        let asset = AVURLAsset(url: url)
        self.asset = asset
        if info.duration <= 0, let seconds = try? await asset.load(.duration).seconds { info.duration = seconds }
        let player = AVPlayer()
        self.player = player
        rebuild(info, result: result)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = time.seconds.isFinite ? time.seconds : 0
                self.time = self.showingResult ? self.info.edits.originalTime(forResult: seconds, duration: self.info.duration) : seconds
            }
        }
        frames = await Self.filmstrip(asset, duration: info.duration, count: 14)
    }

    /// Plays the original (to edit) or the finished video.
    func rebuild(_ info: VideoInfo, result: Bool) {
        self.info = info
        showingResult = result
        guard let asset, let player else { return }
        let keep = time
        Task {
            let shown = result ? ((try? await VideoExport.composition(of: asset, info: info)) ?? asset) : asset
            player.replaceCurrentItem(with: AVPlayerItem(asset: shown))
            let at = result ? info.edits.resultTime(forOriginal: keep, duration: info.duration) : keep
            await player.seek(to: CMTime(seconds: at, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// Moves playback to `seconds` of the original.
    func seek(_ seconds: Double) {
        time = seconds
        let at = showingResult ? info.edits.resultTime(forOriginal: seconds, duration: info.duration) : seconds
        player?.seek(to: CMTime(seconds: at, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    static func filmstrip(_ asset: AVAsset, duration: Double, count: Int) async -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        var images: [CGImage] = []
        for i in 0..<count {
            let at = duration * (Double(i) + 0.5) / Double(count)
            if let image = try? await generator.image(at: CMTime(seconds: at, preferredTimescale: 600)).image { images.append(image) }
        }
        return images
    }

    static func format(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let rest = total - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, rest)
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFrameSteppingButtons = true
        view.allowsPictureInPicturePlayback = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

// MARK: - Timeline

/// Pictures along the recording, with its trimmed ends dimmed and cut sections hatched.
/// Drag the yellow handles to trim; with Cut Out on, drag across a section to take it out;
/// otherwise dragging moves the playhead. Click a cut to select it, Delete removes it.
private struct VideoTimeline: View {
    let item: CaptureItem
    let model: VideoModel
    @State private var editor = AnnotationEditor.shared
    @State private var drag: DragKind?
    @State private var liveEdits: VideoEdits?
    @FocusState private var focused: Bool

    enum DragKind { case start, end, cut(from: Double), scrub }

    private var info: VideoInfo { item.video ?? VideoInfo(duration: 1) }
    private var edits: VideoEdits { liveEdits ?? info.edits }
    private var duration: Double { max(info.duration, 0.01) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = self.duration
            let x: (Double) -> CGFloat = { CGFloat($0 / duration) * width }
            let t: (CGFloat) -> Double = { min(max(Double($0 / max(width, 1)) * duration, 0), duration) }
            ZStack(alignment: .topLeading) {
                strip(width: width, height: geo.size.height)
                // Trimmed-off ends.
                Rectangle().fill(.black.opacity(0.6)).frame(width: x(edits.trimStart), height: geo.size.height)
                let end = edits.trimEnd ?? duration
                Rectangle().fill(.black.opacity(0.6)).frame(width: max(0, width - x(end)), height: geo.size.height).offset(x: x(end))
                // Cut sections.
                ForEach(edits.cuts) { cut in
                    let selected = editor.selectedVideoCut == cut.id
                    Rectangle()
                        .fill(Color.red.opacity(0.35))
                        .overlay(Hatching().stroke(Color.red.opacity(0.7), lineWidth: 1))
                        .overlay(Rectangle().strokeBorder(selected ? Color.accentColor : .red, lineWidth: selected ? 2.5 : 1))
                        .frame(width: max(2, x(cut.end) - x(cut.start)), height: geo.size.height)
                        .offset(x: x(cut.start))
                }
                handle(at: x(edits.trimStart), height: geo.size.height, leading: true)
                handle(at: x(end), height: geo.size.height, leading: false)
                // Playhead.
                Rectangle().fill(.white).frame(width: 2, height: geo.size.height + 8)
                    .shadow(radius: 1)
                    .offset(x: x(model.time) - 1, y: -4)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let start = t(value.startLocation.x), now = t(value.location.x)
                if drag == nil {
                    let reach = 10 / max(width, 1) * duration
                    if abs(start - edits.trimStart) <= reach { drag = .start }
                    else if abs(start - (edits.trimEnd ?? duration)) <= reach { drag = .end }
                    else if editor.cuttingVideo { drag = .cut(from: start) }
                    else {
                        drag = .scrub
                        editor.selectedVideoCut = edits.cuts.first { $0.start <= start && start <= $0.end }?.id
                    }
                }
                var new = info.edits
                switch drag {
                case .start: new.trimStart = min(now, (new.trimEnd ?? duration) - 0.1); model.seek(new.trimStart)
                case .end: new.trimEnd = max(now, new.trimStart + 0.1); model.seek(new.trimEnd! - 0.01)
                case .cut(let from): new.cuts.append(TimeCut(start: from, end: now))
                case .scrub, nil: model.seek(now); return
                }
                liveEdits = new
            }.onEnded { _ in
                defer { drag = nil; liveEdits = nil }
                guard var new = liveEdits else { return }
                if case .cut = drag, let cut = new.cuts.last {
                    guard cut.end - cut.start >= 0.1 else { return }
                    editor.selectedVideoCut = cut.id
                }
                if new.trimEnd.map({ $0 >= duration - 0.01 }) == true { new.trimEnd = nil }
                let action = switch drag { case .start, .end: "Trim"; default: "Cut Out" }
                editor.commitVideo(new, action: action)
            })
        }
        .frame(height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onDeleteCommand { editor.removeSelectedVideoCut() }
        .onTapGesture { focused = true }
    }

    private func strip(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            if model.frames.isEmpty {
                Rectangle().fill(Color.secondary.opacity(0.2))
            } else {
                ForEach(Array(model.frames.enumerated()), id: \.offset) { _, frame in
                    Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(model.frames.count), height: height).clipped()
                }
            }
        }
        .frame(width: width, height: height)
    }

    private func handle(at x: CGFloat, height: CGFloat, leading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.yellow)
            .frame(width: 8, height: height)
            .overlay(Capsule().fill(.black.opacity(0.5)).frame(width: 2, height: height * 0.4))
            .offset(x: leading ? x : x - 8)
            .help(leading ? "Drag to trim the start" : "Drag to trim the end")
    }
}

private struct Hatching: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 8
        }
        return path
    }
}

/// Under the timeline: undo, set the ends at the playhead, cut out, save a frame.
private struct VideoEditBar: View {
    let item: CaptureItem
    let model: VideoModel
    @State private var editor = AnnotationEditor.shared

    private var info: VideoInfo { item.video ?? VideoInfo(duration: 0) }

    var body: some View {
        HStack(spacing: 10) {
            let _ = editor.revision
            Button { editor.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!editor.undoManager.canUndo).help("Undo")
            Button { editor.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!editor.undoManager.canRedo).help("Redo")
            Divider().frame(height: 16)
            Button("Start Here") {
                var edits = info.edits
                edits.trimStart = min(model.time, (edits.trimEnd ?? info.duration) - 0.1)
                editor.commitVideo(edits, action: "Trim")
            }
            .help("Trim off everything before the playhead")
            Button("End Here") {
                var edits = info.edits
                edits.trimEnd = max(model.time, edits.trimStart + 0.1)
                editor.commitVideo(edits, action: "Trim")
            }
            .help("Trim off everything after the playhead")
            Toggle(isOn: $editor.cuttingVideo) { Label("Cut Out", systemImage: "scissors") }
                .toggleStyle(.button)
                .help("Drag across the timeline to cut that section out")
            if editor.selectedVideoCut != nil {
                Button("Remove Cut") { editor.removeSelectedVideoCut() }
            }
            if !info.edits.isEmpty {
                Button("Reset") { editor.commitVideo(VideoEdits(), action: "Reset Video") }
                    .help("Put back everything trimmed or cut")
            }
            Spacer(minLength: 8)
            Text("\(VideoModel.format(model.time)) · plays \(VideoModel.format(info.resultDuration))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1)
            Button { saveFrame() } label: { Label("Save Frame", systemImage: "camera") }
                .help("Add the frame at the playhead to the library as a picture")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private func saveFrame() {
        guard let asset = model.asset else { return }
        let time = model.time
        Task {
            guard let frame = await VideoStore.frame(of: asset, at: time),
                  var picture = LibraryStore.shared.add(image: frame, kind: .region, scale: item.scale, source: item.source, cursor: nil)
            else { return Notice.shared.show(error: "Couldn't take that frame") }
            picture.name = "\(item.name) at \(VideoModel.format(time))"
            picture.nameIsAutomatic = false
            LibraryStore.shared.update(picture)
            Notice.shared.show("Frame saved to the library", symbol: "camera")
        }
    }
}

extension AnnotationEditor {
    /// Changes a recording's trims and cuts, as one undoable step.
    func commitVideo(_ new: VideoEdits, action: String) {
        guard let id = item?.id, var current = item, var info = current.video, info.edits != new else { return }
        let old = info.edits
        info.edits = new
        current.video = info
        LibraryStore.shared.update(current)
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated {
                guard editor.item?.id == id else { return }
                editor.commitVideo(old, action: action)
            }
        }
        undoManager.setActionName(action)
        undoManager.endUndoGrouping()
        if let cut = selectedVideoCut, !new.cuts.contains(where: { $0.id == cut }) { selectedVideoCut = nil }
        bumpRevision()
    }

    func removeSelectedVideoCut() {
        guard let cut = selectedVideoCut, var edits = item?.video?.edits else { return }
        edits.cuts.removeAll { $0.id == cut }
        commitVideo(edits, action: "Remove Cut")
    }
}

// MARK: - Exporting

/// Making the finished video (trimmed and cut) as an MP4 or an animated GIF.
enum VideoExport {
    enum Format: String, CaseIterable {
        case mp4 = "MP4", gif = "GIF"
        var type: UTType { self == .mp4 ? .mpeg4Movie : .gif }
    }

    /// The parts that stay, joined; the movie itself when nothing was left out.
    nonisolated static func composition(of asset: AVAsset, info: VideoInfo) async throws -> AVAsset {
        guard !info.edits.isEmpty else { return asset }
        let composition = AVMutableComposition()
        var at = CMTime.zero
        for part in info.edits.kept(of: info.duration) {
            let range = CMTimeRange(start: CMTime(seconds: part.lowerBound, preferredTimescale: 600),
                                    end: CMTime(seconds: part.upperBound, preferredTimescale: 600))
            try await composition.insertTimeRange(range, of: asset, at: at)
            at = at + range.duration
        }
        return composition
    }

    /// Writes the finished video as MP4.
    nonisolated static func writeMP4(source: URL, info: VideoInfo, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        if info.edits.isEmpty {
            try FileManager.default.copyItem(at: source, to: url)
            return
        }
        let shown = try await composition(of: AVURLAsset(url: source), info: info)
        // Without re-encoding when it can (fast); otherwise at the best quality.
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] {
            guard let session = AVAssetExportSession(asset: shown, presetName: preset) else { continue }
            do {
                try await session.export(to: url, as: .mp4)
                return
            } catch {
                try? FileManager.default.removeItem(at: url)
                if preset == AVAssetExportPresetHighestQuality { throw error }
            }
        }
    }

    /// Writes the finished video as an animated GIF, at most `maxWidth` pixels across.
    nonisolated static func writeGIF(source: URL, info: VideoInfo, to url: URL, maxWidth: CGFloat = 960, fps: Double = 12) async throws {
        let shown = try await composition(of: AVURLAsset(url: source), info: info)
        let generator = AVAssetImageGenerator(asset: shown)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        let times = GIFPlan.frameTimes(duration: info.resultDuration, fps: fps)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, times.count, nil) else {
            throw GrabError(message: "Couldn't write the GIF.")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = 1 / fps
        for time in times {
            guard let frame = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image else { continue }
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw GrabError(message: "Couldn't write the GIF.") }
    }

    /// The movie as a file that plays, found without waiting on the main thread (for drags
    /// and sharing, which need a file right away).
    @MainActor static func playableNow(_ id: UUID) -> URL? {
        let store = VideoStore.shared
        guard let stored = store.storedFile(id) else { return nil }
        guard stored.sealed else { return stored.url }
        let copy = store.playbackFolder.appending(path: "\(id.uuidString).mp4")
        if FileManager.default.fileExists(atPath: copy.path) { return copy }
        guard let key = LibraryStore.shared.db?.sealKey else { return nil }
        try? FileManager.default.createDirectory(at: store.playbackFolder, withIntermediateDirectories: true)
        return (try? ChunkedSeal.open(stored.url, to: copy, key: key)) != nil ? copy : nil
    }

    /// The finished video in a temporary file named after the capture. Waits for it (cutting
    /// without re-encoding is quick).
    @MainActor static func temporaryFile(_ item: CaptureItem) -> URL? {
        guard let source = playableNow(item.id), let info = item.video else { return nil }
        let folder = FileManager.default.temporaryDirectory.appending(path: "CaptureLens Drag/\(item.id.uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(item.name).mp4")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ok = false
        Task.detached {
            ok = (try? await writeMP4(source: source, info: info, to: url)) != nil
            done.signal()
        }
        done.wait()
        return ok ? url : nil
    }

    /// Copies the finished video (as a file) to the clipboard.
    @MainActor static func copy(_ item: CaptureItem) {
        Notice.shared.show("Preparing the video…", symbol: "video")
        Task {
            guard let source = await VideoStore.shared.playableURL(item.id), let info = item.video else {
                return Notice.shared.show(error: "The video isn't on this Mac")
            }
            let folder = FileManager.default.temporaryDirectory.appending(path: "CaptureLens Copy/\(item.id.uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: "\(item.name).mp4")
            do {
                try await writeMP4(source: source, info: info, to: url)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
                Notice.shared.show("Copied the video")
            } catch {
                Notice.shared.show(error: "Couldn't copy the video: \(error.localizedDescription)")
            }
        }
    }

    /// Asks where to save the finished video, as MP4 or GIF.
    @MainActor static func save(_ item: CaptureItem) {
        guard let info = item.video, VideoStore.shared.has(item.id) else { return Notice.shared.show(error: "The video isn't on this Mac") }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: Format.allCases.map(\.rawValue))
        let last = Format(rawValue: AppDefaults.store.string(forKey: "export.videoFormat") ?? "") ?? .mp4
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
        withExtendedLifetime(handler) {}
        let format = Format(rawValue: popup.titleOfSelectedItem ?? "") ?? .mp4
        AppDefaults.store.set(format.rawValue, forKey: "export.videoFormat")
        Notice.shared.show(format == .gif ? "Making the GIF…" : "Saving the video…", symbol: "video")
        Task {
            guard let source = await VideoStore.shared.playableURL(item.id) else { return }
            do {
                if format == .gif { try await writeGIF(source: source, info: info, to: url) }
                else { try await writeMP4(source: source, info: info, to: url) }
                Notice.shared.show("Saved", symbol: "checkmark.circle")
            } catch {
                Notice.shared.show(error: "Couldn't save the video: \(error.localizedDescription)")
            }
        }
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
