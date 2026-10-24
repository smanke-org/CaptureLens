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
}

/// One toolbar item per pane; the window resizes to fit each pane and takes its name
/// as the title, the way macOS's own Settings windows behave.
@MainActor
final class SettingsTabs: NSTabViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = [.crossfade, .allowUserInteraction]
        add("Capture", "camera.viewfinder", CaptureSettings())
        add("Presets", "keyboard", PresetSettings())
        add("Library", "photo.on.rectangle", LibrarySettings())
        add("Privacy", "hand.raised", PrivacySettings())
        add("General", "gearshape", GeneralSettings())
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

    /// Sizes a pane before it's shown (re-measured each time, as panes change), no taller
    /// than the screen.
    private func fit(_ item: NSTabViewItem) {
        guard let height = naturalHeight[item]?() else { return }
        let screen = (isViewLoaded ? view.window?.screen : nil) ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 800) - 120
        item.viewController?.preferredContentSize = NSSize(width: 520, height: min(height, available))
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

    var body: some View {
        Form {
            if !screenGranted {
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
                Text("A preset can override the clipboard choice in Presets.").font(.caption).foregroundStyle(.secondary)
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

    var body: some View {
        Form {
            Section {
                LabeledContent("\(store.items.count) capture\(store.items.count == 1 ? "" : "s")") {
                    Button("Show Library") { LibraryWindow.shared.show() }
                }
                LabeledContent("Space used", value: ByteCountFormatter.string(fromByteCount: store.diskSize, countStyle: .file))
                if store.unreadable > 0 {
                    Label("\(store.unreadable) capture\(store.unreadable == 1 ? " is" : "s are") encrypted with a key this Mac no longer has.",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
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
                Toggle("Sync the library with your other Macs", isOn: $prefs.librarySync)
                if prefs.librarySync {
                    if !settingsSync.isEnabled {
                        Text("Turn on “Sync settings with your other Macs” in General to start.")
                            .foregroundStyle(.secondary)
                    } else if !settingsSync.isReady {
                        Text("Waiting for your sync passphrase in General.").foregroundStyle(.secondary)
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
            } header: {
                Text("iCloud")
            } footer: {
                Text("Captures, with their names, tags, notes and pictures, go to every Mac where you use CaptureLens with sync on, end-to-end encrypted with your sync passphrase. Deleting a capture removes it everywhere. Captures count against your iCloud storage.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Stop encrypting the library on this Mac?", isPresented: $confirmDecrypt) {
            Button("Stop Encrypting", role: .destructive) { store.setEncrypted(false) }
        } message: {
            Text("Your captures are rewritten unencrypted. Anyone who can read your files could then see them.")
        }
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
            }
            Section {
                Toggle("Sync settings with your other Macs", isOn: $sync.isEnabled)
                if sync.isEnabled {
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
                Text("Presets, shortcuts and other settings follow you to every Mac signed in to the same iCloud account with sync turned on. Your library comes along too unless you turn that off in Library. Everything is encrypted on this Mac with your sync passphrase before it reaches iCloud. Open at login, the library lock and encryption on this Mac stay on each Mac.")
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
                self.error = error.localizedDescription
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
