import AppKit
import CaptureLensKit
import Carbon.HIToolbox
import SwiftUI

/// Settings in an AppKit window with the standard toolbar tabs (an icon above each
/// label), so the Dock menu and the menu bar item can open it (SwiftUI's Settings
/// scene can't be opened from AppKit).
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    func show(tab: String? = nil) {
        if window == nil {
            let tabs = SettingsTabs()
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
            #if DEBUG
            // Debug builds only: `CAPTURELENS_SETTINGS_TAB=Privacy` opens on that pane, for checking it.
            if tab == nil, let debugTab = ProcessInfo.processInfo.environment["CAPTURELENS_SETTINGS_TAB"] { tabs.select(debugTab) }
            #endif
        }
        if let tab, let tabs = window?.contentViewController as? SettingsTabs { tabs.select(tab) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    var debugWindow: NSWindow? { window }
    #endif

    func windowWillClose(_ notification: Notification) {}

    /// Moved to another screen (a laptop's, an iPad's): the pane fits that one.
    func windowDidChangeScreen(_ notification: Notification) {
        (window?.contentViewController as? SettingsTabs)?.refit()
    }
}

/// One toolbar item per pane; the window resizes to fit each pane and takes its name
/// as the title, the way macOS's own Settings windows behave.
@MainActor
final class SettingsTabs: NSTabViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        // A display added, removed or resized (an iPad as a second screen, say).
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refit() } }
        tabStyle = .toolbar
        transitionOptions = [.crossfade, .allowUserInteraction]
        add("General", "gearshape", GeneralSettings())
        add("Capture", "camera.viewfinder", CaptureSettings())
        add("Presets", "keyboard", PresetSettings())
        add("Library", "photo.on.rectangle", LibrarySettings())
        add("Privacy", "hand.raised", PrivacySettings())
        add("Activity", "chart.bar.xaxis", ActivitySettings())
    }

    required init?(coder: NSCoder) { fatalError() }

    private func add(_ title: String, _ symbol: String, _ view: some View) {
        let pane = VStack(spacing: 0) {
            view
            // The version in the middle, the round Help button in the corner, as macOS does.
            ZStack {
                Text("\(AppInfo.name) \(AppInfo.displayVersion)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    HelpButton(topic: Help.topic(forSettingsTab: title)).fixedSize()
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .frame(width: 520)
        // Each pane gets its natural height, capped to the screen, with the Form scrolling
        // inside. Letting SwiftUI size the window to the Form's full height crashed once
        // a pane grew taller than the screen: AppKit clamped the window, SwiftUI asked to
        // grow again, and AppKit aborted the update-constraints loop.
        let hosting = NSHostingController(rootView: pane.frame(maxHeight: .infinity))
        hosting.sizingOptions = []
        hosting.title = title
        let item = NSTabViewItem(viewController: hosting)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        addTabViewItem(item)
        naturalHeight[item] = { NSHostingView(rootView: pane).fittingSize.height }
        fit(item)
    }

    /// Measures a pane on a throwaway hosting view, so the window never follows SwiftUI.
    private var naturalHeight: [NSTabViewItem: () -> CGFloat] = [:]

    /// The tallest a pane gets on any screen: it fits a 13-inch MacBook Air's with room to
    /// spare, and the rest scrolls, so Settings looks the same on every Mac.
    static let tallest: CGFloat = 660

    /// Sizes a pane before it's shown (re-measured each time, as panes change), no taller
    /// than the screen or `tallest`.
    @discardableResult
    private func fit(_ item: NSTabViewItem) -> CGFloat? {
        guard let height = naturalHeight[item]?() else { return nil }
        let screen = (isViewLoaded ? view.window?.screen : nil) ?? NSScreen.main
        var available = (screen?.visibleFrame.height ?? 800) - 120
        #if DEBUG
        // `CAPTURELENS_DEBUG_SCREEN_HEIGHT=<points>` sizes panes as if for a smaller screen.
        if let height = ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_SCREEN_HEIGHT"].flatMap(Double.init) { available = height - 120 }
        #endif
        var tallest = Self.tallest
        #if DEBUG
        // The website's pictures show each pane whole.
        if ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_SHOTS"] != nil { tallest = .greatestFiniteMagnitude }
        #endif
        let fitted = min(height, available, tallest)
        item.viewController?.preferredContentSize = NSSize(width: 520, height: fitted)
        return fitted
    }

    /// The shown pane fitted again (another screen, or the screen changed), keeping the
    /// window's top where it is and all of it on screen.
    func refit() {
        guard isViewLoaded, let window = view.window, selectedTabViewItemIndex >= 0,
              let height = fit(tabViewItems[selectedTabViewItemIndex]) else { return }
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 520, height: height))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let visible = window.screen?.visibleFrame {
            frame.origin.y = max(min(frame.origin.y, visible.maxY - frame.height), visible.minY)
            frame.origin.x = max(min(frame.origin.x, visible.maxX - frame.width), visible.minX)
        }
        window.setFrame(frame, display: true, animate: false)
    }

    override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        if let tabViewItem { fit(tabViewItem) }
        super.tabView(tabView, willSelect: tabViewItem)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        selectionChanged()
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        selectionChanged()
    }

    func select(_ label: String) {
        if let index = tabViewItems.firstIndex(where: { $0.label == label }) { selectedTabViewItemIndex = index }
    }

    private func selectionChanged() {
        let item = tabViewItems[selectedTabViewItemIndex]
        view.window?.title = item.label
    }
}

/// A slider with its label and current value. While it is being dragged, `onEditing`
/// can turn on a live preview.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let format: (Double) -> String
    var onEditing: (Bool) -> Void = { _ in }

    var body: some View {
        LabeledContent(title) {
            HStack {
                // Rounded here rather than with Slider's `step`, which draws a tick
                // mark for every step.
                Slider(value: Binding(get: { value }, set: { new in
                    value = step.map { (new / $0).rounded() * $0 } ?? new
                }), in: range, onEditingChanged: onEditing)
                Text(format(value)).monospacedDigit().frame(width: 58, alignment: .trailing).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Capture

struct CaptureSettings: View {
    @State private var prefs = Preferences.shared
    @State private var screenGranted = ScreenAccess.granted
    /// The website's pictures, from a test build that may not have Screen Recording access.
    #if DEBUG
    private static let shooting = ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_SHOTS"] != nil
    #else
    private static let shooting = false
    #endif

    var body: some View {
        Form {
            if !screenGranted && !Self.shooting {
                Section {
                    Label("CaptureLens needs Screen Recording access to capture the screen. Turn on CaptureLens in Screen & System Audio Recording.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Open Privacy Settings") {
                        if !ScreenAccess.request() { ScreenAccess.openSettings() }
                    }
                }
            }
            Section {
                Toggle("Copy each capture to the clipboard", isOn: $prefs.copyToClipboard)
                Picker("After capturing", selection: $prefs.afterCapture) {
                    ForEach(AfterCapture.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Every capture goes to the library")
            } footer: {
                Text("Presets can override both choices. Hold ⌥ as you click or finish dragging to open that one capture in the library.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Keep the pointer as a separate layer", isOn: $prefs.captureCursor)
                Toggle("Show the pointer in new captures", isOn: $prefs.showCursorByDefault)
                    .disabled(!prefs.captureCursor)
                Toggle("Include the shadow around windows", isOn: $prefs.windowShadow)
            } header: {
                Text("Picture")
            } footer: {
                Text("The pointer is never drawn into the picture itself. Show, hide, move or resize it later in the library; it's added when you copy, drag or save a capture.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Name captures from what's in them", isOn: $prefs.autoName)
                if prefs.autoName, let reason = AutoNamer.unavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Read the text in captures, for searching", isOn: $prefs.recognizeText)
                Toggle("Note the web page address in browsers", isOn: $prefs.recordWebAddress)
            } header: {
                Text("Naming and search")
            } footer: {
                Text("Naming uses Apple Intelligence on this Mac, and text is read with macOS's own Live Text. Nothing is sent anywhere. The first time you capture a browser window, macOS asks whether CaptureLens may ask that browser for its page address.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Record the Mac's sound", isOn: $prefs.recordSystemAudio)
                Toggle("Record the microphone", isOn: $prefs.recordMicrophone)
                if prefs.recordMicrophone {
                    DevicePicker(title: "Microphone", devices: RecordingDevices.microphones(), selection: $prefs.microphoneID)
                }
                Toggle("Show the camera in a bubble", isOn: $prefs.recordCamera)
                if prefs.recordCamera {
                    DevicePicker(title: "Camera", devices: RecordingDevices.cameras(), selection: $prefs.cameraID)
                }
                Toggle("Show a ring where you click", isOn: $prefs.showClicks)
                Toggle("Show shortcuts you press", isOn: $prefs.showKeys)
                Picker("Frame rate", selection: $prefs.recordFrameRate) {
                    ForEach(Preferences.frameRates, id: \.rate) { Text($0.title).tag($0.rate) }
                }
                Picker("Countdown before recording", selection: $prefs.recordCountdown) {
                    ForEach(Preferences.countdowns, id: \.self) { Text($0 == 0 ? "None" : "\($0) seconds").tag($0) }
                }
            } header: {
                Text("Video recording")
            } footer: {
                Text("The same choices are in the panel that appears before you record (the Record Video preset, {hotkey:record}); a change in either is a change in both. The microphone and camera are chosen on each Mac. A lower frame rate makes smaller videos: 10 or 15 is plenty for apps, documents and web pages, while video and animation look smoother at 30 or 60. Only shortcuts and keys like Return or the arrows are shown, never what you type. The camera, microphone and shown keys need your permission the first time; macOS asks.".replacingOccurrences(of: "{hotkey:record}", with: Preferences.shared.presets.first { $0.mode == .recording }?.hotKey?.display ?? "no shortcut set"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Feedback") {
                Toggle("Play the camera sound", isOn: $prefs.playSound)
                Toggle("Show notes on screen", isOn: $prefs.showNotice)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenGranted = ScreenAccess.granted
        }
    }
}

// MARK: - Presets

struct PresetSettings: View {
    @State private var prefs = Preferences.shared
    @State private var editing: CapturePreset?

    var body: some View {
        Form {
            Section {
                ForEach(prefs.presets) { preset in
                    HStack {
                        Image(systemName: preset.mode.symbol).frame(width: 20).foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(preset.name)
                            Text(preset.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ShortcutRecorder(hotKey: Binding(get: { prefs.preset(preset.id)?.hotKey }, set: { key in
                            guard var p = prefs.preset(preset.id) else { return }
                            p.hotKey = key
                            prefs.update(p)
                        }))
                        Button { editing = preset } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                            .help("Edit this preset")
                    }
                    .contextMenu {
                        Button("Edit…") { editing = preset }
                        Button("Capture Now") { CaptureEngine.shared.run(preset) }
                        Button("Duplicate") {
                            var copy = preset
                            copy.id = UUID()
                            copy.name += " Copy"
                            copy.hotKey = nil
                            prefs.presets.append(copy)
                        }
                        Button("Delete", role: .destructive) { prefs.presets.removeAll { $0.id == preset.id } }
                            .disabled(prefs.presets.count == 1)
                    }
                }
                .onMove { prefs.presets.move(fromOffsets: $0, toOffset: $1) }
                HStack {
                    Button("Add Preset…") { editing = CapturePreset(name: "New Preset", mode: .allInOne) }
                    Spacer()
                    Button("Restore Default Presets") { prefs.presets = CapturePreset.defaults }
                }
            } header: {
                Text("Capture presets")
            } footer: {
                Text("The first preset is the Capture button's. Drag to reorder; right-click for more. Click a shortcut, then press the new keys. Delete clears it, Esc cancels.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Other shortcuts") {
                LabeledContent("Open the library") { ShortcutRecorder(hotKey: $prefs.libraryHotKey) }
                LabeledContent("Capture the same area again") { ShortcutRecorder(hotKey: $prefs.captureAgainHotKey) }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { preset in
            PresetEditor(preset: preset) { edited in
                if prefs.preset(edited.id) != nil { prefs.update(edited) } else { prefs.presets.append(edited) }
                editing = nil
            } cancel: { editing = nil }
        }
    }
}

#if DEBUG
extension PresetEditor {
    /// The sheet's natural height for each preset, for checking it fits small screens.
    @MainActor static func debugHeights() -> String {
        Preferences.shared.presets.map { preset in
            let host = NSHostingController(rootView: PresetEditor(preset: preset, save: { _ in }, cancel: {}))
            return "\(preset.name) \(Int(host.view.fittingSize.height))"
        }.joined(separator: ", ")
    }
}
#endif

struct PresetEditor: View {
    @State var preset: CapturePreset
    let save: (CapturePreset) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $preset.name)
                Picker("Capture", selection: $preset.mode) {
                    ForEach(CaptureMode.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                if preset.mode == .fixedSize {
                    LabeledContent("Size (points)") {
                        HStack {
                            TextField("Width", value: $preset.width, format: .number).frame(width: 70)
                            Text("×")
                            TextField("Height", value: $preset.height, format: .number).frame(width: 70)
                        }
                    }
                    Menu("Common Sizes") {
                        ForEach([(640, 480), (800, 600), (1024, 768), (1280, 720), (1280, 800), (1440, 900), (1920, 1080)], id: \.0) { size in
                            Button("\(size.0) × \(size.1)") { preset.width = size.0; preset.height = size.1 }
                        }
                    }
                }
                Picker("Delay", selection: $preset.delay) {
                    Text("None").tag(0)
                    ForEach([1, 2, 3, 5, 10, 15, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Picker("Clipboard", selection: $preset.clipboard) {
                    ForEach(ClipboardChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("After capturing", selection: $preset.afterCapture) {
                    Text("As in Capture settings").tag(nil as AfterCapture?)
                    Divider()
                    ForEach(AfterCapture.allCases, id: \.self) { Text($0.title).tag($0 as AfterCapture?) }
                }
                LabeledContent("Shortcut") { ShortcutRecorder(hotKey: $preset.hotKey) }
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save") {
                    preset.width = min(max(preset.width, 16), 8000)
                    preset.height = min(max(preset.height, 16), 8000)
                    save(preset)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preset.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 440)
    }

    private var help: String {
        switch preset.mode {
        case .allInOne: "Point at a window and click to capture it, or drag over any area. Return captures the whole screen."
        case .region: "Drag over the area to capture."
        case .window: "Click the window to capture. It's captured on its own, even where other windows cover it."
        case .screen: "Captures the whole screen the pointer is on, straight away."
        case .fixedSize: "A frame of this size follows the pointer; click to capture what's inside."
        case .scrolling: "Click a window or drag over an area, then scroll it (or let CaptureLens scroll it). The frames are stitched into one tall picture."
        case .recording: "Click a window, drag over an area or press Return for the whole screen, then choose sound, camera and highlights and press Record. The shortcut again stops it. With no delay, it counts down 3 seconds."
        }
    }
}

// MARK: - Library

struct LibrarySettings: View {
    @State private var prefs = Preferences.shared
    @State private var store = LibraryStore.shared
    @State private var lock = LibraryLock.shared
    @State private var settingsSync = SettingsSync.shared
    @State private var librarySync = LibrarySync.shared
    @State private var confirmDecrypt = false
    @State private var confirmRemoveICloud = false

    /// Off, iCloud or a folder, as one choice.
    private var libraryService: Binding<LibraryBackend?> {
        Binding(get: { prefs.librarySync ? prefs.libraryBackend : nil }, set: { choice in
            if let choice {
                prefs.libraryBackend = choice
                prefs.librarySync = true
            } else {
                prefs.librarySync = false
            }
        })
    }

    private var syncFooter: String {
        switch (prefs.librarySync, prefs.libraryBackend) {
        case (false, _):
            "Captures stay on this Mac. Settings still sync when that's on in General. Each Mac makes this choice for itself."
        case (true, .iCloud):
            "Captures, with their names, tags, notes and pictures, go to every Mac where you use CaptureLens with sync on, end-to-end encrypted with your sync passphrase. Deleting a capture removes it everywhere. Captures count against your iCloud storage."
        case (true, .folder):
            "Captures go into a folder that Dropbox, OneDrive, Google Drive or any other sync app keeps on all your Macs, each file encrypted with your sync passphrase, so the service can't see them. Each Mac picks where that folder is; settings still sync through iCloud. Each Mac makes this choice for itself, so choose the same on every Mac that shares the library."
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Markup tools", selection: $prefs.toolStyle) {
                    ForEach(ToolStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if prefs.toolStyle == .dial {
                    Picker("Open the dial", selection: $prefs.dialTrigger) {
                        ForEach(DialTrigger.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            } header: {
                Text("Markup")
            } footer: {
                Text(prefs.toolStyle == .toolbar
                     ? "The tools float over the picture. Drag the toolbar's grip to put it on the left, right or bottom."
                     : "The tools open in a dial around the pointer, the ones you use most closest to the middle, with colors and line widths. Click a tool, or with ⌘⌥ held, let go over it. Drag the dial to move it; its pin keeps it open after you pick a tool. Esc closes it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("\(store.items.count) capture\(store.items.count == 1 ? "" : "s")") {
                    Button("Show Library") { LibraryWindow.shared.show() }
                }
                LabeledContent("Space used", value: ByteCountFormatter.string(fromByteCount: store.diskSize + VideoStore.shared.diskSize, countStyle: .file))
                if store.unreadable > 0 {
                    Label("\(store.unreadable) capture\(store.unreadable == 1 ? " is" : "s are") encrypted with a key this Mac no longer has.",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Picker("Double-click a capture to open it", selection: $prefs.doubleClickOpens) {
                    ForEach(OpenPlace.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } footer: {
                Text(prefs.doubleClickOpens == .sidePane
                     ? "A capture double-clicked in the library opens in the pane beside the captures."
                     : "A capture double-clicked in the library opens in a window of its own, as big as you like; so does double-clicking the picture beside the captures.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Encrypt the library on this Mac", isOn: Binding(get: { store.isEncrypted }, set: { on in
                    if on { store.setEncrypted(true) } else { confirmDecrypt = true }
                }))
                .disabled(store.isResealing)
                if store.isResealing {
                    HStack { ProgressView().controlSize(.small); Text("Rewriting the library…").foregroundStyle(.secondary) }
                }
                Toggle("Require \(lock.biometryName) to open the library", isOn: Binding(get: { lock.isEnabled }, set: { on in
                    Task { await lock.setEnabled(on) }
                }))
                .disabled(!lock.canAuthenticate)
                if lock.isEnabled {
                    Picker("Lock again", selection: Binding(get: { lock.lockAfter }, set: { lock.lockAfter = $0 })) {
                        Text("When the library window closes").tag(0)
                        Text("After 5 minutes away").tag(5)
                        Text("After 15 minutes away").tag(15)
                        Text("After 1 hour away").tag(60)
                    }
                    Button("Lock Now") { lock.lockNow() }
                }
                if let error = lock.lastError { Text(error).font(.callout).foregroundStyle(.red) }
            } header: {
                Text("Security")
            } footer: {
                Text("Encryption seals every capture, its picture, name, tags and notes with AES-256 using a key kept in this Mac's keychain, so the library file on its own reveals nothing. The lock also locks when your Mac sleeps or its screen locks. Both are settings of this Mac only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Sync the library through", selection: libraryService) {
                    Text("Don't sync").tag(nil as LibraryBackend?)
                    Divider()
                    ForEach(LibraryBackend.allCases, id: \.self) { Text($0.title).tag($0 as LibraryBackend?) }
                }
                if prefs.librarySync {
                    if !settingsSync.isEnabled {
                        Text("Turn on “Sync with your other Macs” in General to start. The sync passphrase you choose there also encrypts the library, wherever it syncs.")
                            .foregroundStyle(.secondary)
                    } else if !settingsSync.isReady {
                        Text("Waiting for your sync passphrase in General.").foregroundStyle(.secondary)
                    } else if prefs.libraryBackend == .folder {
                        FolderSyncRows()
                    } else if let error = librarySync.lastError {
                        Text(error).foregroundStyle(.red)
                    } else {
                        LabeledContent {
                            Button("Sync Now") { librarySync.syncNow() }
                        } label: {
                            if librarySync.pendingUploads > 0 {
                                Text("Uploading \(librarySync.pendingUploads) capture\(librarySync.pendingUploads == 1 ? "" : "s")…")
                            } else if let date = librarySync.lastSynced {
                                Text("Synced \(date.formatted(date: .omitted, time: .shortened))")
                            } else {
                                Text("Waiting for iCloud…")
                            }
                        }
                    }
                }
                if prefs.librarySync {
                    Toggle(isOn: $prefs.syncVideos) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sync video files")
                            Text(prefs.syncVideos
                                 ? "Recordings play on every Mac. Long ones take a lot of room\(prefs.libraryBackend == .iCloud ? " in iCloud" : " in the sync folder")."
                                 : "Recordings' names, tags, notes and first frames sync; the videos stay on the Mac that recorded them.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let problem = librarySync.videoProblem, prefs.syncVideos, prefs.libraryBackend == .iCloud {
                        Text(problem).font(.caption).foregroundStyle(.orange)
                    }
                }
                if prefs.librarySync && prefs.libraryBackend == .folder && settingsSync.isReady && librarySync.iCloudCaptureCount > 0 {
                    LabeledContent {
                        Button("Remove from iCloud…") { confirmRemoveICloud = true }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(librarySync.iCloudCaptureCount) capture\(librarySync.iCloudCaptureCount == 1 ? "" : "s") still in iCloud")
                            Text("From before the library moved to a folder. They take up iCloud storage.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Sync")
            } footer: {
                Text(syncFooter).font(.caption).foregroundStyle(.secondary)
            }
            #if !APPSTORE
            CollectSection()
            #endif
            Section {
                LabeledContent("Moving from Snagit?") {
                    Button("Import from Snagit…") { SnagitImportWindow.shared.show() }
                }
            } footer: {
                Text("Brings in your Snagit captures with their dates, apps, web addresses and tags, and their markup editable where CaptureLens has the same tool. Videos can come too; they stay on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove the library's copies from iCloud?", isPresented: $confirmRemoveICloud) {
            Button("Remove from iCloud", role: .destructive) { librarySync.removeFromICloud() }
        } message: {
            Text("Your captures stay on your Macs and in the sync folder; only the copies in iCloud go. First update CaptureLens to this version on every Mac that syncs: an older version still syncing the library through iCloud would delete those captures too.")
        }
        .confirmationDialog("Stop encrypting the library on this Mac?", isPresented: $confirmDecrypt) {
            Button("Stop Encrypting", role: .destructive) { store.setEncrypted(false) }
        } message: {
            Text("Your captures are rewritten unencrypted. Anyone who can read your files could then see them.")
        }
    }
}

/// Captures from other tools, brought into the library as they're made.
private struct CollectSection: View {
    @State private var collector = CaptureCollector.shared
    /// The tool just switched on, while asking how far back to look.
    @State private var asking: CaptureCollector.Tool?

    var body: some View {
        Section {
            ForEach(CaptureCollector.Tool.allCases) { tool in
                Toggle(isOn: Binding(get: { collector.isOn(tool) || asking == tool },
                                     set: { $0 ? (asking = tool) : collector.turnOff(tool) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.title)
                        Text(status(tool)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Captures from other tools")
        } footer: {
            Text("They come into the library as you take them, so it has everything whatever you capture with. The original files stay where they are. Each comes in once, even if you delete it here later, and one another Mac already brought in isn't added twice. Pictures only; the Photos library is never looked at.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog(asking.map { "Bring in \($0.title) you already have?" } ?? "",
                            isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            ForEach(CaptureCollector.Lookback.allCases) { lookback in
                Button(lookback.title) {
                    if let tool = asking { collector.turnOn(tool, lookingBack: lookback) }
                    asking = nil
                }
            }
            Button("Cancel", role: .cancel) { asking = nil }
        } message: {
            Text("New ones come in from now on. Ones already there can come too.")
        }
    }

    private func status(_ tool: CaptureCollector.Tool) -> String {
        guard collector.isOn(tool) else { return tool.detail }
        let count = collector.counts[tool] ?? 0
        let waiting = collector.waiting > 0 ? " · \(collector.waiting) on the way" : ""
        return count == 0 ? "On. None yet\(waiting)" : "On. \(count.formatted()) brought in\(waiting)"
    }
}

// MARK: - General

struct GeneralSettings: View {
    @State private var prefs = Preferences.shared
    @State private var presence = PresenceSettings.shared
    @State private var hub = MenuHub.shared
    @State private var login = LaunchAtLogin.shared
    @State private var confirmReset = false
    @State private var sync = SettingsSync.shared
    @State private var updater = AutoUpdater.shared

    private var updateFooter: String {
        switch updater.policy {
        case .automatic:
            "CaptureLens checks \(updater.interval.phrase). A new version installs itself when no capture is under way, CaptureLens hasn't been used for 30 minutes, no app is presenting or keeping the screen awake, and your Mac hasn't been used for 2 minutes. You'll get a notification when it's done."
        case .ask:
            "CaptureLens checks \(updater.interval.phrase) and sends a notification when a new version is out. Nothing installs until you choose to."
        case .off:
            "CaptureLens won't look for updates on its own. Use Check Now whenever you like."
        }
    }

    var body: some View {
        Form {
            AppearanceSection(appName: "CaptureLens") { SettingsSync.shared.localDidChange() }
            Section("Where CaptureLens appears") {
                Toggle("Show in Dock", isOn: $presence.showInDock)
                Toggle("Show in menu bar", isOn: $presence.showInMenuBar)
                #if !APPSTORE
                Toggle("Put in ToolHUD’s menu while ToolHUD is running", isOn: $hub.foldIntoToolHUD)
                    .help("ToolHUD shows this menu as a submenu of its own, and CaptureLens’s icon leaves the menu bar until ToolHUD quits.")
                #endif
                if !presence.showInDock && !presence.showInMenuBar {
                    Text(AppPresence.hiddenEverywhereNote(appName: "CaptureLens", settingsName: "Settings"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Open CaptureLens at login", isOn: Binding(get: { login.isEnabled }, set: { login.set($0) }))
                if login.needsApproval {
                    Button("Allow in Login Items…") { login.openLoginItemsSettings() }
                }
                if let error = login.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                Toggle("Ask before quitting", isOn: $prefs.confirmQuit)
                    .help("Quitting CaptureLens asks first, so a stray ⌘Q doesn't stop the capture shortcuts.")
            }
            Section {
                Toggle("Sync with your other Macs", isOn: $sync.isEnabled)
                if sync.isEnabled {
                    // What goes: each Mac chooses for itself.
                    Toggle(isOn: $sync.syncsSettings) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Settings")
                            Text("Presets, shortcuts, markup styles, appearance and the library window's layout")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $prefs.librarySync) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Library")
                            Text("Your captures, through \(prefs.libraryBackend.title); choose where in Settings › Library")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if sync.keyState == .ready {
                        LabeledContent {
                            Button("Sync Now") { sync.syncNow() }
                        } label: {
                            if let error = sync.lastError {
                                Text(error).foregroundStyle(.red)
                            } else if let date = sync.lastSynced {
                                Text("Synced \(date.formatted(date: .omitted, time: .shortened))\(sync.lastSource.map { $0 == SettingsSync.deviceName ? "" : " from \($0)" } ?? "")")
                            } else {
                                Text("Waiting for iCloud…")
                            }
                        }
                        SyncPassphraseForm(mode: .change)
                    } else if let error = sync.lastError {
                        Text(error).foregroundStyle(.red)
                    } else if sync.keyState == .waitingForKeyring {
                        Text("Checking iCloud…").foregroundStyle(.secondary)
                    } else {
                        SyncPassphraseForm(mode: sync.keyState == .needsPassphrase ? .enter : .create)
                            .id(sync.keyState == .needsPassphrase)
                    }
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("Your settings and your library each follow you to every Mac signed in to the same iCloud account with sync turned on; switch either off on this Mac to keep it here. Everything is encrypted on this Mac with your sync passphrase before it leaves. Open at login, the library lock and encryption on this Mac stay on each Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #if !APPSTORE
            Section {
                Picker("When an update is available", selection: $updater.policy) {
                    ForEach(UpdatePolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if updater.policy != .off {
                    UpdateIntervalPicker(interval: $updater.interval)
                }
                if let staged = updater.staged {
                    LabeledContent("Version \(staged.version) is ready") {
                        Button("Install Now") { updater.installNow() }
                    }
                }
                LabeledContent("Version \(AppInfo.displayVersion)") {
                    Button("Check Now") { UpdateController.checkForUpdates() }
                }
                if let error = updater.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                if updater.policy != .off && !updater.notificationsAllowed {
                    LabeledContent {
                        Button("Open Notification Settings") { AutoUpdater.openNotificationSettings() }
                    } label: {
                        Label("Notifications are off for CaptureLens, so update news only shows in the menu.",
                              systemImage: "bell.slash").foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(updateFooter).font(.caption).foregroundStyle(.secondary)
            }
            #endif
            Section {
                LabeledContent("All CaptureLens settings") {
                    Button("Reset to Defaults…") { confirmReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh(); updater.refreshNotificationStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            updater.refreshNotificationStatus()
        }
        .confirmationDialog("Reset CaptureLens settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                prefs.resetToDefaults()
                HotKeyCenter.shared.apply()
            }
        } message: {
            Text("Presets, shortcuts and options go back to how CaptureLens started. Your library, where CaptureLens appears and login stay as they are.")
        }
    }
}

/// Sets up, enters or changes the sync passphrase.
struct SyncPassphraseForm: View {
    enum Mode { case create, enter, change, startOver }

    @State var mode: Mode
    @State private var sync = SettingsSync.shared
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var error: String?
    @State private var changing = false
    @State private var confirmStartOver = false

    private var needsConfirm: Bool { mode != .enter }
    private var valid: Bool {
        mode == .enter ? !passphrase.isEmpty : passphrase.count >= 8 && confirm == passphrase
    }

    var body: some View {
        if mode == .change && !changing {
            LabeledContent("Encrypted with your sync passphrase") {
                Button("Change Passphrase…") { changing = true }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(prompt).fixedSize(horizontal: false, vertical: true)
                SecureField("", text: $passphrase, prompt: Text(mode == .enter ? "Passphrase" : "New passphrase"))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .textContentType(mode == .enter ? .password : .newPassword)
                    .onSubmit { if valid && !needsConfirm { submit() } }
                if needsConfirm {
                    SecureField("", text: $confirm, prompt: Text("Confirm passphrase"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .textContentType(.newPassword)
                        .onSubmit { if valid { submit() } }
                    if !passphrase.isEmpty && passphrase.count < 8 {
                        Text("At least 8 characters.").font(.caption).foregroundStyle(.secondary)
                    } else if !confirm.isEmpty && confirm != passphrase {
                        Text("The passphrases don't match.").font(.caption).foregroundStyle(.red)
                    }
                }
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
                HStack {
                    if mode == .enter {
                        Button("Forgot It? Start Over…") { confirmStartOver = true }
                    }
                    if mode == .change || mode == .startOver {
                        Button("Cancel") { reset(to: mode == .startOver ? .enter : .change) }
                    }
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Button(buttonTitle) { submit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!valid || working)
                }
            }
            .padding(.vertical, 4)
            .confirmationDialog("Start over with a new passphrase?", isPresented: $confirmStartOver) {
                Button("Start Over", role: .destructive) { reset(to: .startOver) }
            } message: {
                Text("The encrypted settings and library in iCloud are replaced with this Mac's, and your other Macs will ask for the new passphrase.")
            }
        }
    }

    private var prompt: String {
        switch mode {
        case .create: "Choose a sync passphrase. Your settings and library are encrypted with it before they go to iCloud, and you'll enter the same passphrase on your other Macs. It never leaves your Macs and can't be recovered, so keep it somewhere safe."
        case .enter: "Your synced settings are encrypted. Enter the sync passphrase you chose on your other Mac."
        case .change: "Choose a new sync passphrase. Your other Macs keep syncing; you'll only need the new one when you set up another Mac."
        case .startOver: "Choose a new sync passphrase. Enter it on your other Macs when they ask."
        }
    }

    private var buttonTitle: String {
        switch mode {
        case .create: "Turn On Encrypted Sync"
        case .enter: "Unlock"
        case .change: "Change Passphrase"
        case .startOver: "Start Over"
        }
    }

    private func reset(to newMode: Mode) {
        mode = newMode
        passphrase = ""
        confirm = ""
        error = nil
        changing = false
    }

    private func submit() {
        guard valid, !working else { return }
        working = true
        error = nil
        let entered = passphrase
        Task {
            defer { working = false }
            do {
                switch mode {
                case .create: try await sync.createPassphrase(entered)
                case .enter: try await sync.enterPassphrase(entered)
                case .change: try await sync.changePassphrase(entered)
                case .startOver: try await sync.createPassphrase(entered, replacing: true)
                }
                reset(to: .change)
            } catch {
                self.error = CloudSync.message(for: error)
                if case SettingsSync.SyncError.alreadySetUp = error { reset(to: .enter); self.error = error.localizedDescription }
            }
        }
    }
}

/// `AppPresence` values as observable state for Settings.
@Observable
@MainActor
final class PresenceSettings {
    static let shared = PresenceSettings()

    var showInDock = AppPresence.showInDock {
        didSet {
            AppPresence.showInDock = showInDock
            AppPresence.applyDock(keepInFront: NSApp.keyWindow)
        }
    }

    var showInMenuBar = AppPresence.showInMenuBar {
        didSet { AppPresence.showInMenuBar = showInMenuBar }
    }

    /// Follows choices that arrived from another Mac.
    func reload() {
        if showInDock != AppPresence.showInDock { showInDock = AppPresence.showInDock }
        if showInMenuBar != AppPresence.showInMenuBar { showInMenuBar = AppPresence.showInMenuBar }
        MenuHub.shared.reload()
        // The status item follows the notification, which the setter only posts on a change.
        NotificationCenter.default.post(name: AppPresence.menuBarDidChange, object: nil)
    }
}

/// Where this Mac keeps the sync folder, and how syncing through it is going.
struct FolderSyncRows: View {
    @State private var folder = FolderSync.shared
    @State private var confirmReplace = false

    var body: some View {
        LabeledContent {
            Menu(folder.folderURL == nil ? "Choose…" : "Change…") {
                let services = FolderSync.detectedServices()
                ForEach(services, id: \.url) { service in
                    Button(service.name) { folder.choose(service.url) }
                }
                if !services.isEmpty { Divider() }
                Button("Other Folder…") { chooseOther() }
            }
            .fixedSize()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Folder on this Mac")
                if let url = folder.folderURL {
                    Text(Self.display(url)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                } else {
                    Text("Choose the Dropbox, OneDrive or Google Drive folder to sync through.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        if folder.folderURL != nil {
            if folder.keyMismatch {
                VStack(alignment: .leading, spacing: 6) {
                    Text(folder.lastError ?? "").foregroundStyle(.red)
                    HStack {
                        Button("Choose Another Folder…") { chooseOther() }
                        Button("Replace Its Contents…") { confirmReplace = true }
                    }
                }
            } else if let error = folder.lastError {
                Text(error).foregroundStyle(.red)
            } else {
                LabeledContent {
                    Button("Sync Now") { folder.syncNow() }
                } label: {
                    if folder.isWorking {
                        Text("Syncing…")
                    } else if let date = folder.lastSynced {
                        Text("Synced \(date.formatted(date: .omitted, time: .shortened))")
                    } else {
                        Text("Starting…")
                    }
                }
            }
        }
        EmptyView()
            .confirmationDialog("Replace the library in this folder?", isPresented: $confirmReplace) {
                Button("Replace", role: .destructive) { folder.replaceFolderContents() }
            } message: {
                Text("The captures in it were encrypted with another sync passphrase and can't be opened. They're deleted and replaced with this Mac's library.")
            }
    }

    private func chooseOther() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose a folder that your sync app keeps on all your Macs. CaptureLens puts a “CaptureLens Library” folder inside it."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Picking the library folder itself means its parent.
        folder.choose(url.lastPathComponent == FolderLayout.rootName ? url.deletingLastPathComponent() : url)
    }

    /// "Dropbox › Work" rather than the long CloudStorage path.
    static func display(_ url: URL) -> String {
        let storage = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/CloudStorage").path + "/"
        var path = url.path
        if path.hasPrefix(storage) {
            path = String(path.dropFirst(storage.count))
            if path.hasPrefix("GoogleDrive-") { path = "Google Drive" + (path.firstIndex(of: "/").map { String(path[$0...]) } ?? "") }
            else if path.hasPrefix("OneDrive-") { path = "OneDrive" + (path.firstIndex(of: "/").map { String(path[$0...]) } ?? "") }
            return path.replacingOccurrences(of: "/", with: " › ")
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}
