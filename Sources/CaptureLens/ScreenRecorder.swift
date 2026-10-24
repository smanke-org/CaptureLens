import AppKit
@preconcurrency import AVFoundation
import CaptureLensKit
import Observation
@preconcurrency import ScreenCaptureKit
import SwiftUI

/// Records a video of an area, a window or a whole screen, with the Mac's sound, the
/// microphone, a camera bubble, and rings where the mouse clicks, as chosen in the control
/// bar. Pausing ends a piece of the recording; stopping joins the pieces into one movie
/// and saves it to the library.
@Observable
@MainActor
final class ScreenRecorder: NSObject {
    static let shared = ScreenRecorder()

    enum Phase: Equatable {
        case idle
        /// The area is picked; the control bar waits for Record.
        case ready
        case countingDown
        case recording
        case paused
        /// Joining the pieces and saving.
        case finishing
    }

    private(set) var phase = Phase.idle
    /// Seconds recorded so far, pauses left out.
    private(set) var elapsed: TimeInterval = 0
    private(set) var note: String?
    var isActive: Bool { phase != .idle }
    var isRecording: Bool { phase == .recording || phase == .paused || phase == .countingDown }

    @ObservationIgnored private var region: ScreenRegion?
    @ObservationIgnored private var frame: CGRect = .zero
    @ObservationIgnored private var pickedWindow: ScreenWindow?
    @ObservationIgnored private var windows: [ScreenWindow] = []
    @ObservationIgnored private var preset: CapturePreset?
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: SCRecordingOutput?
    @ObservationIgnored private var segments: [URL] = []
    @ObservationIgnored private var segmentStarted: Date?
    @ObservationIgnored private var recordedBefore: TimeInterval = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var panel: FloatingPanel?
    @ObservationIgnored private var outline: NSWindow?
    @ObservationIgnored private var finished: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var started: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var failure: String?
    let overlay = RecordingOverlay()
    let camera = CameraBubble()

    private var workFolder: URL { FileManager.default.temporaryDirectory.appending(path: "CaptureLens Recording", directoryHint: .isDirectory) }

    // MARK: - Starting

    /// The preset's shortcut: starts a recording, or stops the one under way.
    func toggle(_ preset: CapturePreset) {
        switch phase {
        case .idle: Task { await begin(preset) }
        case .ready: record()
        case .recording, .paused: stop()
        case .countingDown, .finishing: break
        }
    }

    /// Picks what to record, then shows the control bar.
    func begin(_ preset: CapturePreset) async {
        guard phase == .idle, !CaptureEngine.shared.isBusy else { return }
        if !ScreenAccess.granted {
            ScreenAccess.request()
            guard ScreenAccess.granted else { return ScreenAccess.explainDenied() }
        }
        self.preset = preset
        windows = ScreenWindow.onScreen()
        let frozen: [CGDirectDisplayID: CGImage]
        do { frozen = try await ScreenGrabber.captureAllScreens() } catch {
            return Notice.shared.show(error: error.localizedDescription)
        }
        guard let pick = await CaptureOverlay.shared.pick(mode: .recording, fixedSize: CGSize(width: preset.width, height: preset.height),
                                                          images: frozen) else { return }
        switch pick {
        case .region(let r, _, let f):
            (region, frame, pickedWindow) = (r, f, nil)
        case .screen(let display, _, let f):
            (region, frame, pickedWindow) = (ScreenRegion(displayID: display, rect: CGRect(origin: .zero, size: f.size)), f, nil)
        case .window(let w):
            // The window's part of its screen; the recording follows that area.
            guard let screen = NSScreen.screens.max(by: { $0.frame.intersection(w.frame).area < $1.frame.intersection(w.frame).area }) else { return }
            let visible = w.frame.intersection(screen.frame)
            region = ScreenRegion(displayID: screen.displayID,
                                  rect: CGRect(x: visible.minX - screen.frame.minX, y: screen.frame.maxY - visible.maxY,
                                               width: visible.width, height: visible.height))
            (frame, pickedWindow) = (visible, w)
        }
        guard frame.width >= 32, frame.height >= 32 else { return Notice.shared.show(error: "That area is too small to record") }
        note = nil
        phase = .ready
        showOutline()
        showPanel()
        if Preferences.shared.recordCamera { await showCamera() }
    }

    /// Starts recording after a short countdown.
    func record() {
        guard phase == .ready else { return }
        phase = .countingDown
        Task {
            let prefs = Preferences.shared
            if prefs.recordMicrophone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
                prefs.recordMicrophone = false
                note = "CaptureLens isn't allowed to use the microphone (System Settings › Privacy & Security › Microphone)."
            }
            if prefs.showKeys, !AXIsProcessTrusted() {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                prefs.showKeys = false
                note = "To show keys, allow CaptureLens in Privacy & Security › Accessibility, then turn Keys on again."
            }
            let seconds = (preset?.delay ?? 0) > 0 ? preset!.delay : 3
            let go = await Countdown.shared.run(seconds: seconds)
            guard go, phase == .countingDown else { return cancel() }
            await startStream()
        }
    }

    private func startStream() async {
        guard let region else { return cancel() }
        let prefs = Preferences.shared
        if prefs.showClicks || prefs.showKeys { overlay.show(over: frame, clicks: prefs.showClicks, keys: prefs.showKeys) }
        // The new windows have to be on screen to be found below.
        try? await Task.sleep(for: .milliseconds(150))
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
                throw GrabError(message: "That display is no longer connected.")
            }
            // CaptureLens's own windows stay out, except the camera bubble and the click rings.
            let own = content.applications.filter { $0.processID == getpid() }
            let shown = Set([overlay.windowNumber, camera.windowNumber].compactMap { $0 }.map { CGWindowID($0) })
            let keep = content.windows.filter { shown.contains($0.windowID) }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: keep)

            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            var width = region.rect.width * scale, height = region.rect.height * scale
            // At most 4K across, for movies every app can play.
            let shrink = min(1, 3840 / max(width, height))
            width = (width * shrink / 2).rounded() * 2
            height = (height * shrink / 2).rounded() * 2
            config.sourceRect = region.rect
            config.width = Int(width)
            config.height = Int(height)
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(prefs.recordFrameRate, 1)))
            config.showsCursor = true
            config.queueDepth = 6
            config.capturesAudio = prefs.recordSystemAudio
            config.excludesCurrentProcessAudio = true
            if prefs.recordMicrophone, let mic = AVCaptureDevice.default(for: .audio) {
                config.captureMicrophone = true
                config.microphoneCaptureDeviceID = mic.uniqueID
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            self.stream = stream
            try addSegment()
            try await stream.startCapture()
            guard await awaitStart() else { throw GrabError(message: failure ?? "The recording didn't start.") }
            phase = .recording
            recordedBefore = 0
            startTimer()
            Sounds.shutter()
            Activity.shared.touch()
        } catch {
            NSLog("CaptureLens: recording failed to start: \(error.localizedDescription)")
            Notice.shared.show(error: "Couldn't start recording: \(error.localizedDescription)")
            await tearDown(discard: true)
        }
    }

    /// A new piece of the recording, into its own file.
    private func addSegment() throws {
        guard let stream else { return }
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        let url = workFolder.appending(path: "\(UUID().uuidString).mp4")
        let config = SCRecordingOutputConfiguration()
        config.outputURL = url
        config.outputFileType = .mp4
        config.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: config, delegate: self)
        try stream.addRecordingOutput(output)
        self.output = output
        segments.append(url)
        segmentStarted = Date()
    }

    private func awaitStart() async -> Bool {
        await withCheckedContinuation { continuation in
            started = continuation
            // Give up if nothing is heard (no frames, a stuck stream).
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let waiting = self.started else { return }
                    self.started = nil
                    waiting.resume(returning: false)
                }
            }
        }
    }

    /// Ends the current piece, waiting for its file to be finished.
    private func endSegment() async {
        guard let stream, let output else { return }
        self.output = nil
        if let segmentStarted { recordedBefore += Date().timeIntervalSince(segmentStarted) }
        segmentStarted = nil
        await withCheckedContinuation { continuation in
            finished = continuation
            do {
                try stream.removeRecordingOutput(output)
            } catch {
                finished = nil
                continuation.resume()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let waiting = self.finished else { return }
                    self.finished = nil
                    waiting.resume()
                }
            }
        }
    }

    // MARK: - Pausing and stopping

    func pause() {
        guard phase == .recording else { return }
        phase = .paused
        Task { await endSegment(); updateElapsed() }
    }

    func resume() {
        guard phase == .paused else { return }
        do {
            try addSegment()
            phase = .recording
        } catch {
            note = "Couldn't carry on recording: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard phase == .recording || phase == .paused else { return }
        let wasRecording = phase == .recording
        phase = .finishing
        timer?.invalidate()
        Task {
            if wasRecording { await endSegment() }
            try? await stream?.stopCapture()
            stream = nil
            await save()
        }
    }

    /// Stops without saving anything.
    func cancel() {
        guard phase != .idle, phase != .finishing else { return }
        Task { await tearDown(discard: true) }
    }

    private func save() async {
        let pieces = segments.filter { FileManager.default.fileExists(atPath: $0.path) }
        let source = SourceInfo.describe(frame: frame, windows: windows, window: pickedWindow, display: region?.displayID)
        let frame = self.frame, preset = self.preset
        await tearDown(discard: false)
        guard !pieces.isEmpty else { return Notice.shared.show(error: "Nothing was recorded") }
        do {
            let movie = try await Self.join(pieces, into: workFolder.appending(path: "\(UUID().uuidString)-joined.mp4"))
            let asset = AVURLAsset(url: movie)
            let duration = try await asset.load(.duration).seconds
            let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
            guard duration > 0.2, let poster = await VideoStore.frame(of: asset, at: min(0.5, duration / 2)) else {
                throw GrabError(message: "The recording is empty.")
            }
            let scale = frame.width > 0 ? Double(poster.width) / frame.width : 2
            guard let item = LibraryStore.shared.addVideo(movie: movie, poster: poster, scale: scale,
                                                          info: VideoInfo(duration: duration, hasAudio: hasAudio), source: source) else {
                throw GrabError(message: "Couldn't save it to the library.")
            }
            for piece in pieces where piece != movie { try? FileManager.default.removeItem(at: piece) }
            Sounds.shutter()
            let after = preset?.afterCapture ?? Preferences.shared.afterCapture
            if after.opensLibrary || after == .preview || after == .previewAndLibrary { LibraryWindow.shared.show(select: item.id) }
            Notice.shared.show("Recording saved", symbol: "video", near: frame)
        } catch {
            NSLog("CaptureLens: couldn't save the recording: \(error.localizedDescription)")
            Notice.shared.show(error: "Couldn't save the recording: \(error.localizedDescription)")
        }
    }

    /// One movie from the pieces (just the piece, when there's one).
    nonisolated static func join(_ pieces: [URL], into url: URL) async throws -> URL {
        if pieces.count == 1 { return pieces[0] }
        let composition = AVMutableComposition()
        var at = CMTime.zero
        for piece in pieces {
            let asset = AVURLAsset(url: piece)
            let duration = try await asset.load(.duration)
            guard duration.seconds > 0 else { continue }
            try await composition.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: asset, at: at)
            at = at + duration
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw GrabError(message: "Couldn't join the recording's pieces.")
        }
        try await export.export(to: url, as: .mp4)
        for piece in pieces { try? FileManager.default.removeItem(at: piece) }
        return url
    }

    private func tearDown(discard: Bool) async {
        timer?.invalidate()
        timer = nil
        if output != nil { await endSegment() }
        try? await stream?.stopCapture()
        stream = nil
        overlay.hide()
        camera.hide()
        panel?.orderOut(nil)
        panel = nil
        outline?.orderOut(nil)
        outline = nil
        if discard { for piece in segments { try? FileManager.default.removeItem(at: piece) } }
        segments = []
        elapsed = 0
        recordedBefore = 0
        phase = .idle
    }

    // MARK: - Time

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { ScreenRecorder.shared.updateElapsed() }
        }
    }

    private func updateElapsed() {
        elapsed = recordedBefore + (segmentStarted.map { Date().timeIntervalSince($0) } ?? 0)
    }

    // MARK: - On screen

    func setCamera(_ on: Bool) {
        Preferences.shared.recordCamera = on
        Task { if on { await showCamera() } else { camera.hide() } }
    }

    private func showCamera() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            Preferences.shared.recordCamera = false
            note = "CaptureLens isn't allowed to use the camera (System Settings › Privacy & Security › Camera)."
            return
        }
        camera.show(in: frame)
    }

    /// A red dashed frame around what's being recorded (left out of the recording).
    private func showOutline() {
        let window = NSWindow(contentRect: frame.insetBy(dx: -3, dy: -3), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = DashedFrame()
        window.orderFrontRegardless()
        outline = window
    }

    private func showPanel() {
        let panel = FloatingPanel(title: "Record", size: CGSize(width: 380, height: 120), resizable: false)
        panel.host(RecordingBar())
        panel.place(near: frame)
        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel
    }

    #if DEBUG
    /// The control bar as it looks before recording, for the self-test.
    func debugShowBar(over frame: CGRect) -> NSWindow? {
        self.frame = frame
        phase = .ready
        showOutline()
        showPanel()
        return panel
    }

    func debugReset() async { await tearDown(discard: true) }
    #endif

    private final class DashedFrame: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 3
            path.setLineDash([8, 5], count: 2, phase: 0)
            NSColor.systemRed.setStroke()
            path.stroke()
        }
    }
}

extension ScreenRecorder: SCRecordingOutputDelegate, SCStreamDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard let waiting = self.started else { return }
            self.started = nil
            waiting.resume(returning: true)
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            NSLog("CaptureLens: recording failed: \(error.localizedDescription)")
            self.failure = error.localizedDescription
            if let waiting = self.started { self.started = nil; waiting.resume(returning: false) }
            if let waiting = self.finished { self.finished = nil; waiting.resume() }
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard let waiting = self.finished else { return }
            self.finished = nil
            waiting.resume()
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            NSLog("CaptureLens: the recording stopped: \(error.localizedDescription)")
            // Save what there is (the display went away, or access was turned off).
            if self.phase == .recording || self.phase == .paused { self.stop() }
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

// MARK: - The control bar

/// Before: what to record along with the screen, and Record. During: the time, Pause, Stop.
private struct RecordingBar: View {
    @State private var recorder = ScreenRecorder.shared
    @State private var prefs = Preferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch recorder.phase {
            case .ready, .countingDown:
                HStack(spacing: 6) {
                    toggle("Sound", "speaker.wave.2", $prefs.recordSystemAudio, help: "Record the Mac's sound (apps playing audio)")
                    toggle("Mic", "mic", $prefs.recordMicrophone, help: "Record the microphone")
                    toggle("Camera", "web.camera", Binding(get: { prefs.recordCamera }, set: { recorder.setCamera($0) }),
                           help: "Show the camera in a round bubble; drag it where you like")
                    toggle("Clicks", "cursorarrow.click", $prefs.showClicks, help: "Show a ring wherever you click")
                    toggle("Keys", "command", $prefs.showKeys, help: "Show the shortcuts and special keys you press (not what you type)")
                }
                HStack {
                    Button("Cancel") { recorder.cancel() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button { recorder.record() } label: { Label("Record", systemImage: "record.circle.fill") }
                        .keyboardShortcut(.defaultAction)
                        .disabled(recorder.phase != .ready)
                }
            case .recording, .paused:
                HStack(spacing: 10) {
                    Image(systemName: recorder.phase == .paused ? "pause.circle.fill" : "record.circle.fill")
                        .foregroundStyle(recorder.phase == .paused ? Color.orange : Color.red)
                        .font(.title2)
                        .symbolEffect(.pulse, isActive: recorder.phase == .recording)
                    Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                        .font(.title3.monospacedDigit().weight(.medium))
                    Spacer()
                    if recorder.phase == .paused {
                        Button { recorder.resume() } label: { Label("Resume", systemImage: "record.circle") }
                    } else {
                        Button { recorder.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                    }
                    Button { recorder.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .keyboardShortcut(.defaultAction)
                }
                Text("Stop with the Record Video shortcut too, or from the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
            case .finishing:
                HStack { ProgressView().controlSize(.small); Text("Saving the recording…") }
            case .idle:
                EmptyView()
            }
            if let note = recorder.note {
                Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private func toggle(_ title: String, _ symbol: String, _ value: Binding<Bool>, help: String) -> some View {
        Toggle(isOn: value) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 16))
                Text(title).font(.caption2)
            }
            .frame(width: 58, height: 40)
        }
        .toggleStyle(.button)
        .help(help)
    }
}

// MARK: - Clicks and keys

/// A clear window over the recorded area where clicks show as rings and shortcuts as
/// keycaps. It's in the recording; the mouse goes straight through it.
@MainActor
final class RecordingOverlay {
    private var window: NSWindow?
    private var view: OverlayView?
    private var monitors: [Any] = []

    var windowNumber: Int? { window?.windowNumber }

    func show(over frame: CGRect, clicks: Bool, keys: Bool) {
        hide()
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = OverlayView(frame: CGRect(origin: .zero, size: frame.size))
        window.contentView = view
        window.orderFrontRegardless()
        self.window = window
        self.view = view
        if clicks {
            monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                MainActor.assumeIsolated { self.click(at: NSEvent.mouseLocation, right: event.type == .rightMouseDown) }
            } as Any)
        }
        if keys {
            monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                MainActor.assumeIsolated { if let text = Self.describe(event) { self.view?.showKeys(text) } }
            } as Any)
        }
    }

    func hide() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        window?.orderOut(nil)
        window = nil
        view = nil
    }

    func click(at point: CGPoint, right: Bool) {
        guard let window, let view, window.frame.contains(point) else { return }
        view.ring(at: CGPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY), right: right)
    }

    /// "⌘⇧4", "Return", "⌥←": shortcuts and special keys. Plain typing isn't shown, so
    /// passwords and messages stay out of recordings.
    static func describe(_ event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        var mods = ""
        if flags.contains(.control) { mods += "⌃" }
        if flags.contains(.option) { mods += "⌥" }
        if flags.contains(.shift) { mods += "⇧" }
        if flags.contains(.command) { mods += "⌘" }
        let special: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 117: "⌦", 123: "←", 124: "→",
                                         125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 76: "Enter"]
        if let name = special[event.keyCode] {
            // Space and Tab on their own are typing too.
            if mods.isEmpty && (event.keyCode == 49 || event.keyCode == 48) { return nil }
            return mods + name
        }
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) && flags.contains(.command) else { return nil }
        guard let key = event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty else { return nil }
        return mods + key
    }

    private final class OverlayView: NSView {
        private let keycap = CATextLayer()
        private let keyBackground = CALayer()
        private var hideKeys: DispatchWorkItem?

        override init(frame: CGRect) {
            super.init(frame: frame)
            wantsLayer = true
            keyBackground.backgroundColor = NSColor(white: 0.08, alpha: 0.78).cgColor
            keyBackground.cornerRadius = 14
            keyBackground.opacity = 0
            keycap.alignmentMode = .center
            keycap.foregroundColor = NSColor.white.cgColor
            keycap.font = NSFont.systemFont(ofSize: 30, weight: .semibold)
            keycap.fontSize = 30
            keycap.contentsScale = 2
            keyBackground.addSublayer(keycap)
            layer?.addSublayer(keyBackground)
        }

        required init?(coder: NSCoder) { fatalError() }

        func ring(at point: CGPoint, right: Bool) {
            let ring = CAShapeLayer()
            let size: CGFloat = 44
            ring.path = CGPath(ellipseIn: CGRect(x: -size / 2, y: -size / 2, width: size, height: size), transform: nil)
            ring.position = point
            ring.fillColor = (right ? NSColor.systemBlue : NSColor.systemYellow).withAlphaComponent(0.3).cgColor
            ring.strokeColor = (right ? NSColor.systemBlue : NSColor.systemYellow).cgColor
            ring.lineWidth = 3
            layer?.addSublayer(ring)
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.4
            grow.toValue = 1.2
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = 0.6
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.opacity = 0
            ring.add(group, forKey: "click")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { ring.removeFromSuperlayer() }
        }

        func showKeys(_ text: String) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .semibold)]
            let width = (text as NSString).size(withAttributes: attributes).width + 40
            keyBackground.frame = CGRect(x: (bounds.width - width) / 2, y: 30, width: width, height: 56)
            keycap.frame = CGRect(x: 0, y: 9, width: width, height: 40)
            keycap.string = text
            keyBackground.opacity = 1
            CATransaction.commit()
            hideKeys?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.keyBackground.opacity = 0 }
            hideKeys = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
        }
    }
}

// MARK: - Camera

/// The camera in a round, draggable bubble over the recording.
@MainActor
final class CameraBubble {
    private var window: NSPanel?
    private var session: AVCaptureSession?

    var windowNumber: Int? { window?.windowNumber }
    var isShown: Bool { window != nil }

    func show(in frame: CGRect) {
        guard window == nil else { return }
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else {
            Notice.shared.show(error: "No camera found")
            return
        }
        let session = AVCaptureSession()
        session.sessionPreset = .medium
        guard session.canAddInput(input) else { return }
        session.addInput(input)
        let side: CGFloat = min(200, max(110, min(frame.width, frame.height) * 0.28))
        let panel = NSPanel(contentRect: CGRect(x: frame.maxX - side - 24, y: frame.minY + 24, width: side, height: side),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar + 1
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = BubbleView(frame: CGRect(x: 0, y: 0, width: side, height: side))
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        view.layer?.addSublayer(preview)
        panel.contentView = view
        panel.orderFrontRegardless()
        window = panel
        self.session = session
        nonisolated(unsafe) let running = session
        DispatchQueue.global(qos: .userInitiated).async { running.startRunning() }
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        if let session {
            nonisolated(unsafe) let stopping = session
            DispatchQueue.global(qos: .utility).async { stopping.stopRunning() }
        }
        session = nil
    }

    private final class BubbleView: NSView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = frame.width / 2
            layer?.masksToBounds = true
            layer?.borderWidth = 3
            layer?.borderColor = NSColor.white.cgColor
            layer?.backgroundColor = NSColor.black.cgColor
        }

        required init?(coder: NSCoder) { fatalError() }
        override var mouseDownCanMoveWindow: Bool { true }
    }
}
