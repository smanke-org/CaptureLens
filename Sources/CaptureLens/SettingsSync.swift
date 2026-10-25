import AppKit
import CryptoKit
import Foundation
import Observation
import CaptureLensKit

/// Keeps settings in step across the Macs on one iCloud account, through the Settings
/// record in CloudKit (see `CloudSync`). Whole-document, last-writer-wins: each change
/// replaces the record, and a newer one written by another Mac replaces this Mac's settings.
///
/// End-to-end encrypted: every record CaptureLens puts in iCloud is sealed with AES-256-GCM
/// under a random data key. iCloud holds that key only wrapped by the sync passphrase (the
/// Keyring record, see `SyncCrypto`); each Mac keeps the unwrapped key in its login
/// keychain. Until this Mac has the key, the sync engine doesn't run. Left on each Mac:
/// open at login, the library lock and encryption at rest.
@Observable
@MainActor
final class SettingsSync {
    static let shared = SettingsSync()

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Keys.enabled)
            if isEnabled {
                // Turning sync on adopts what other Macs share; this Mac's settings are
                // uploaded only if nothing is there yet.
                localModified = nil
                start()
            } else {
                stop()
                LibrarySync.shared.start()
                FolderSync.shared.start()
                ActivitySync.shared.start()
            }
        }
    }
    private(set) var lastSynced: Date?
    private(set) var lastSource: String?
    private(set) var lastError: String?

    /// What sync needs before it can run.
    enum KeyState: Equatable {
        /// This Mac holds the key that opens the synced records.
        case ready
        /// Nothing is set up in iCloud yet: choose a passphrase.
        case needsNewPassphrase
        /// Another Mac set up encryption: enter its passphrase.
        case needsPassphrase
        /// Still asking iCloud for the keyring (or it can't be reached).
        case waitingForKeyring
    }
    private(set) var keyState: KeyState = .waitingForKeyring {
        // Folder sync needs the key too; it follows along (a moment later, off this change).
        didSet { if keyState != oldValue { DispatchQueue.main.async { MainActor.assumeIsolated { FolderSync.shared.start() } } } }
    }

    /// The data key, once this Mac has it. Read by `LibrarySync` and `CloudSync`.
    @ObservationIgnored private(set) var key: SymmetricKey?
    /// The keyring as known in iCloud.
    @ObservationIgnored private var keyring: SyncCrypto.Keyring?
    /// The keyring to save in iCloud on the next send (a changed passphrase).
    @ObservationIgnored private(set) var keyringForUpload: SyncCrypto.Keyring?

    /// When settings last changed on this Mac, or were adopted from iCloud.
    private var localModified: Date? {
        get { defaults.object(forKey: Keys.localModified) as? Date }
        set { defaults.set(newValue, forKey: Keys.localModified) }
    }

    private let defaults = AppDefaults.store
    private var applying = false
    private var checking = false
    /// Whether the Settings record came down since the engine last started.
    private var settingsSeenThisRun = false
    private var retryTimer: Timer?

    private enum Keys {
        static let enabled = "sync.enabled"
        static let localModified = "sync.localModified"
    }

    /// Settings that follow the user between Macs.
    static var syncedKeys: [String] {
        Preferences.keys + ["showInDock", "showInMenuBar", MenuHub.foldKey, AppAppearance.key, UpdatePolicy.key,
         UpdateInterval.valueKey, UpdateInterval.unitKey]
    }

    var isReady: Bool { isEnabled && keyState == .ready && key != nil }

    /// Must not touch Preferences: its initializer can report changes here.
    private init() {
        isEnabled = defaults.bool(forKey: Keys.enabled)
        key = SyncKeychain.loadKey()
    }

    // MARK: - Lifecycle

    /// On a brand-new install, sync data already in iCloud means this user has CaptureLens on
    /// another Mac: turn sync on (it then asks for the passphrase) rather than starting from
    /// the defaults.
    func adoptOnNewInstall() {
        guard !isEnabled, CloudSync.isEntitled else { return }
        Task {
            let found = (try? await CloudSync.shared.fetchKeyring()) != nil
            guard found, !isEnabled else { return }
            NSLog("CaptureLens: new install found sync data in iCloud; turning sync on")
            isEnabled = true
        }
    }

    func start() {
        guard isEnabled, !checking else { return }
        checking = true
        lastError = nil
        Task {
            await refreshKeyState()
            checking = false
            if keyState == .ready, let key {
                retryTimer?.invalidate()
                retryTimer = nil
                CloudSync.shared.startEngine(keyID: SyncCrypto.keyID(for: key))
                afterEngineStart()
            } else if retryTimer == nil {
                // Look again now and then: iCloud may come back, or another Mac may finish
                // setting up.
                retryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        let sync = SettingsSync.shared
                        if sync.isEnabled, !CloudSync.shared.isRunning { sync.start() } else { sync.retryTimer?.invalidate(); sync.retryTimer = nil }
                    }
                }
            }
        }
    }

    private func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        CloudSync.shared.stopEngine()
        lastError = nil
    }

    func syncNow() {
        guard isEnabled else { return }
        if CloudSync.shared.isRunning { CloudSync.shared.fetchNow(); CloudSync.shared.sendNow() } else { start() }
    }

    /// Called whenever a synced setting really changes on this Mac.
    func localDidChange() {
        guard !applying else { return }
        localModified = Self.now
        if CloudSync.shared.isRunning { CloudSync.shared.queueSave([CloudSync.Name.settings]) }
    }

    private func afterEngineStart() {
        // If nothing came down from iCloud, this Mac's settings become the shared copy.
        settingsSeenThisRun = false
        CloudSync.shared.afterFirstFetch { [weak self] in
            guard let self, !self.settingsSeenThisRun, !CloudSync.shared.knowsServerRecord(CloudSync.Name.settings) else { return }
            CloudSync.shared.queueSave([CloudSync.Name.settings])
        }
    }

    // MARK: - Passphrase and key

    /// Works out whether this Mac's key opens what's in iCloud.
    private func refreshKeyState() async {
        if let problem = await CloudSync.shared.accountProblem() {
            lastError = problem
            keyState = .waitingForKeyring
            return
        }
        let remote: SyncCrypto.Keyring?
        do {
            remote = try await CloudSync.shared.fetchKeyring()
        } catch {
            lastError = "Couldn't reach iCloud: \(error.localizedDescription)"
            keyState = .waitingForKeyring
            return
        }
        lastError = nil
        if let remote {
            keyring = remote
            if let key, SyncCrypto.keyID(for: key) == remote.keyID {
                keyState = .ready
            } else {
                // No key yet, or another Mac started over with a new passphrase.
                if key != nil { forgetKey() }
                keyState = .needsPassphrase
            }
            return
        }
        keyring = nil
        if key != nil { forgetKey() }
        keyState = .needsNewPassphrase
    }

    /// Sets up encryption with a new passphrase: a fresh key, wrapped into the keyring.
    /// `replacing` starts over, removing everything sealed with the old key.
    func createPassphrase(_ passphrase: String, replacing: Bool = false) async throws {
        let (newKeyring, newKey) = try await Task.detached { try SyncCrypto.createKeyring(passphrase: passphrase) }.value
        do {
            try await CloudSync.shared.saveKeyring(newKeyring, replacing: replacing)
        } catch SyncError.alreadySetUp {
            // Another Mac set up encryption meanwhile: join it instead.
            await refreshKeyState()
            throw SyncError.alreadySetUp
        }
        keyring = newKeyring
        // This Mac's settings become the shared copy.
        localModified = localModified ?? Self.now
        adopt(newKey)
        NSLog("CaptureLens: set up encrypted sync (key \(newKeyring.keyID))")
    }

    /// Unlocks the key another Mac set up. Throws `SyncCrypto.CryptoError.wrongPassphrase`.
    func enterPassphrase(_ passphrase: String) async throws {
        if keyring == nil { await refreshKeyState() }
        guard let keyring else { throw SyncError.noKeyring }
        let unlocked = try await Task.detached { try SyncCrypto.unwrap(keyring, passphrase: passphrase) }.value
        // Adopt what the other Macs share rather than overwriting it.
        localModified = nil
        adopt(unlocked)
    }

    /// Rewraps the same key with a new passphrase, so other Macs keep working.
    func changePassphrase(_ passphrase: String) async throws {
        guard let key else { throw SyncError.noKeyring }
        let rewrapped = try await Task.detached { try SyncCrypto.wrap(key, passphrase: passphrase) }.value
        try await CloudSync.shared.saveKeyring(rewrapped, replacing: false)
        keyring = rewrapped
    }

    private func adopt(_ newKey: SymmetricKey) {
        key = newKey
        SyncKeychain.saveKey(newKey)
        keyState = .ready
        lastError = nil
        CloudSync.shared.stopEngine()
        CloudSync.shared.startEngine(keyID: SyncCrypto.keyID(for: newKey))
        afterEngineStart()
    }

    private func forgetKey() {
        key = nil
        SyncKeychain.deleteKey()
    }

    enum SyncError: LocalizedError {
        case noKeyring, alreadySetUp
        var errorDescription: String? {
            switch self {
            case .noKeyring: "The sync keyring isn't in iCloud yet. Try again in a moment."
            case .alreadySetUp: "Another Mac has just set up encrypted sync. Enter the passphrase you chose there."
            }
        }
    }

    // MARK: - From CloudSync

    /// The keyring record arrived or changed. A different key means another Mac started over.
    func receivedKeyring(_ incoming: SyncCrypto.Keyring) {
        keyring = incoming
        guard let key, SyncCrypto.keyID(for: key) != incoming.keyID else { return }
        NSLog("CaptureLens: the sync key changed on another Mac")
        CloudSync.shared.resetEngine()
        forgetKey()
        keyState = .needsPassphrase
    }

    /// Checks the keyring in iCloud still matches this Mac's key.
    func verifyKeyring() {
        Task {
            do {
                if let remote = try await CloudSync.shared.fetchKeyring() {
                    receivedKeyring(remote)
                } else {
                    keyringChangedElsewhere()
                }
            } catch {
                DebugLog.write("verifyKeyring: \(error)")
            }
        }
    }

    /// The zone or keyring went away: someone started over or deleted the synced data.
    func keyringChangedElsewhere() {
        CloudSync.shared.stopEngine()
        start()
    }

    /// Signed out of iCloud, or into another account.
    func accountChanged() {
        forgetKey()
        keyring = nil
        keyState = .waitingForKeyring
        start()
    }

    /// The Settings record arrived from iCloud (or won a conflict with this Mac's save).
    func receivedSettings(_ sealed: Data, conflict: Bool = false) {
        guard let key, let remote = Self.document(from: sealed, key: key) else {
            lastError = "The settings in iCloud couldn't be opened with this Mac's key."
            return
        }
        settingsSeenThisRun = true
        if let local = localModified, local > remote.updatedAt {
            CloudSync.shared.queueSave([CloudSync.Name.settings])
        } else if localModified == nil || remote.updatedAt > localModified! {
            apply(remote)
        } else {
            // The same settings: nothing to do.
            noteSynced(remote)
        }
    }

    /// The Settings record's contents: the whole set, defaults included (see Preferences.snapshot).
    func sealedSettings(using key: SymmetricKey) -> Data? {
        let updatedAt = localModified ?? Self.now
        var settings = Preferences.shared.snapshot.filter { Self.syncedKeys.contains($0.key) }
        settings["showInDock"] = AppPresence.showInDock
        settings["showInMenuBar"] = AppPresence.showInMenuBar
        settings[MenuHub.foldKey] = MenuHub.shared.foldIntoToolHUD
        settings[AppAppearance.key] = AppAppearance.current.rawValue
        settings[UpdatePolicy.key] = UpdatePolicy.current.rawValue
        settings[UpdateInterval.valueKey] = UpdateInterval.current.value
        settings[UpdateInterval.unitKey] = UpdateInterval.current.unit.rawValue
        let plist: [String: Any] = ["version": 3, "updatedAt": updatedAt, "updatedBy": Self.deviceName, "settings": settings]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0),
              let sealed = try? SyncCrypto.seal(data, using: key) else { return nil }
        if localModified == nil { localModified = updatedAt }
        noteSynced(Document(updatedAt: updatedAt, updatedBy: Self.deviceName, settings: settings))
        return sealed
    }

    #if DEBUG
    /// Seals this Mac's settings with `key`, then applies them again the way another Mac
    /// would, for the self-test. Returns the settings that went into the record.
    func debugRoundTrip(using key: SymmetricKey, change: () -> Void) -> [String: Any]? {
        let saved = localModified
        guard let sealed = sealedSettings(using: key), let document = Self.document(from: sealed, key: key) else { return nil }
        change()
        apply(document)
        localModified = saved
        return document.settings
    }
    #endif

    // MARK: - Applying

    private struct Document {
        var updatedAt: Date
        var updatedBy: String
        var settings: [String: Any]
    }

    private static func document(from sealed: Data, key: SymmetricKey) -> Document? {
        guard let data = try? SyncCrypto.open(sealed, using: key),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let updatedAt = plist["updatedAt"] as? Date,
              let settings = plist["settings"] as? [String: Any] else { return nil }
        return Document(updatedAt: updatedAt, updatedBy: plist["updatedBy"] as? String ?? "another Mac", settings: settings)
    }

    private func apply(_ remote: Document) {
        applying = true
        defer { applying = false }
        // Only what the record holds; a missing setting keeps this Mac's value.
        for key in Self.syncedKeys {
            if let value = remote.settings[key] { defaults.set(value, forKey: key) }
        }
        Preferences.shared.reload()
        AutoUpdater.shared.policy = UpdatePolicy.current
        AutoUpdater.shared.interval = UpdateInterval.current
        HotKeyCenter.shared.apply()
        PresenceSettings.shared.reload()
        localModified = remote.updatedAt
        noteSynced(remote)
        NSLog("CaptureLens: adopted settings from \(remote.updatedBy) (\(remote.updatedAt))")
    }

    private func noteSynced(_ document: Document) {
        lastSynced = Date()
        lastSource = document.updatedBy
        lastError = nil
    }

    /// Whole seconds, so a date read back compares equal to the one written.
    private static var now: Date {
        Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.down))
    }

    static var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}

/// The sync data key, kept in this Mac's login keychain.
enum SyncKeychain {
    static let service = "com.smanke.CaptureLens.sync"
    /// A test copy with its own defaults keeps its key apart from the real one.
    static let account: String = AppDefaults.suiteName.map { "data-key-test-\($0)" } ?? "data-key"

    static func saveKey(_ key: SymmetricKey) {
        deleteKey()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "CaptureLens sync key",
            kSecValueData as String: key.withUnsafeBytes { Data($0) },
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess { NSLog("CaptureLens: couldn't save the sync key (\(status))") }
    }

    static func loadKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    static func deleteKey() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

#if DEBUG
/// Debug builds only, for testing sync between scratch copies without typing:
/// `CAPTURELENS_DEBUG_SYNC=create:<pass>|enter:<pass>|change:<pass>|startover:<pass>` runs once
/// after launch, and the sync state is written to `debug.sync*` defaults every two seconds.
enum SyncDebugHook {
    @MainActor static func run() {
        let sync = SettingsSync.shared
        if let command = ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_SYNC"], let colon = command.firstIndex(of: ":") {
            let verb = String(command[..<colon]), pass = String(command[command.index(after: colon)...])
            Task {
                try? await Task.sleep(for: .seconds(1))
                do {
                    switch verb {
                    case "create": try await sync.createPassphrase(pass)
                    case "enter": try await sync.enterPassphrase(pass)
                    case "change": try await sync.changePassphrase(pass)
                    case "startover": try await sync.createPassphrase(pass, replacing: true)
                    default: break
                    }
                    AppDefaults.store.set("ok", forKey: "debug.syncCommand")
                } catch {
                    AppDefaults.store.set("error: \(error.localizedDescription)", forKey: "debug.syncCommand")
                }
            }
        }
        // `CAPTURELENS_DEBUG_LIBRARY=add:<name>|tag-first:<tag>|delete-first`, a few seconds after launch.
        if let command = ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_LIBRARY"], !command.isEmpty {
            Task {
                try? await Task.sleep(for: .seconds(3))
                let store = LibraryStore.shared
                if command.hasPrefix("add:"), let image = DebugImage.make(text: String(command.dropFirst(4))) {
                    store.add(image: image, kind: .region, scale: 2, source: .init(appName: "DebugHook"), cursor: nil)
                } else if command.hasPrefix("tag-first:"), let first = store.items.first {
                    store.setTags([first.id], add: [String(command.dropFirst(10))])
                } else if command == "delete-first", let first = store.items.first {
                    store.delete([first.id])
                }
            }
        }
        // `CAPTURELENS_DEBUG_COMMANDS=<file>`: runs each new line of the file (see `DebugCommands`)
        // and writes the state to `<file>.status`, so a running test copy can be driven.
        if let path = ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_COMMANDS"] {
            DebugCommands.start(path: path)
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let d = AppDefaults.store
                let store = LibraryStore.shared
                d.set(store.items.count, forKey: "debug.libraryCount")
                d.set(store.items.first?.name ?? "", forKey: "debug.libraryFirst")
                d.set(store.items.first?.tags.joined(separator: ",") ?? "", forKey: "debug.libraryFirstTags")
                d.set(store.items.first?.recognizedText.prefix(80).description ?? "", forKey: "debug.libraryFirstText")
                d.set(store.isEncrypted, forKey: "debug.libraryEncrypted")
                d.set(LibrarySync.shared.pendingUploads, forKey: "debug.libraryPending")
                d.set(LibrarySync.shared.lastError ?? "", forKey: "debug.libraryError")
                d.set("\(sync.keyState)", forKey: "debug.syncKeyState")
                d.set(sync.lastError ?? "", forKey: "debug.syncError")
                d.set(sync.lastSource ?? "", forKey: "debug.syncSource")
            }
        }
    }
}
#endif

#if DEBUG
/// Commands for a running test copy, one per line: `create:<pass>`, `enter:<pass>`,
/// `change:<pass>`, `startover:<pass>`, `add:<text>`, `rename-first:<name>`, `tag-first:<tag>`,
/// `notes-first:<text>`, `favorite-first`, `delete-first`, `clipboard:<true|false>`,
/// `preset-name:<name>`, `appearance:<system|light|dark>`, `sync-now`, `sync-off`, `delete-zone`, `quit`.
@MainActor
enum DebugCommands {
    private static var done = 0

    static func start(path: String) {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { tick(path) }
        }
    }

    private static func tick(_ path: String) {
        let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        while done < lines.count {
            let line = lines[done]
            done += 1
            Task { await run(line) }
        }
        writeStatus(path + ".status")
    }

    private static func run(_ line: String) async {
        let sync = SettingsSync.shared
        let store = LibraryStore.shared
        let prefs = Preferences.shared
        let (verb, arg): (String, String) = {
            guard let colon = line.firstIndex(of: ":") else { return (line, "") }
            return (String(line[..<colon]), String(line[line.index(after: colon)...]))
        }()
        var result = "ok"
        do {
            switch verb {
            case "create": sync.isEnabled = true; try await Task.sleep(for: .seconds(2)); try await sync.createPassphrase(arg)
            case "enter": sync.isEnabled = true; try await Task.sleep(for: .seconds(2)); try await sync.enterPassphrase(arg)
            case "change": try await sync.changePassphrase(arg)
            case "startover": try await sync.createPassphrase(arg, replacing: true)
            case "add":
                if let image = DebugImage.make(text: arg) {
                    store.add(image: image, kind: .region, scale: 2, source: .init(appName: "DebugHook"), cursor: nil)
                }
            case "rename-first": if let first = store.items.first { store.rename(first.id, to: arg) }
            case "tag-first": if let first = store.items.first { store.setTags([first.id], add: [arg]) }
            case "notes-first":
                if var first = store.items.first { first.notes = arg; store.update(first) }
            case "favorite-first": if let first = store.items.first { store.toggleFavorite([first.id]) }
            case "delete-first": if let first = store.items.first { store.delete([first.id]) }
            case "clipboard": prefs.copyToClipboard = arg == "true"
            case "preset-name":
                var first = prefs.presets[0]
                first.name = arg
                prefs.update(first)
            case "appearance": AppAppearance.store.set(arg, forKey: AppAppearance.key); sync.localDidChange()
            case "sync-now": sync.syncNow(); FolderSync.shared.syncNow()
            case "backend":
                if arg == "off" { prefs.librarySync = false } else {
                    prefs.libraryBackend = arg == "folder" ? .folder : .iCloud
                    prefs.librarySync = true
                }
            case "folder": FolderSync.shared.choose(URL(fileURLWithPath: arg, isDirectory: true))
            case "remove-icloud": LibrarySync.shared.removeFromICloud()
            case "settings": SettingsWindow.shared.show()
            case "close-windows": for window in NSApp.windows where window.isVisible { window.close() }
            case "library":
                // `library:<width>x<height>`: the library window at that size, first capture selected.
                LibraryWindow.shared.show(select: store.items.first?.id)
                let size = arg.split(separator: "x").compactMap { Double($0) }
                if size.count == 2, let window = LibraryWindow.shared.window {
                    window.setFrame(CGRect(origin: window.frame.origin, size: CGSize(width: size[0], height: size[1])), display: true)
                }
            case "inspector": LibraryWindow.shared.state.showInspector = arg == "on"
            case "select-test":
                // `select-test[:typing]`: draws a box with the box tool, holds ⌘, drags the box
                // 40 pt right, lets go of ⌘; reports the tool and the box at each step.
                result = await PanTest.holdCommand(typing: arg == "typing")
            case "samples": _ = await DebugShots.addSamples() // the made-up library from the screenshots
            case "drag-sidebar":
                // `drag-sidebar:<x>`: drags the sidebar's edge to x points from the window's left;
                // reports the sidebar's width after.
                result = await PanTest.dragSidebar(to: Double(arg) ?? 200)
            case "select":
                // `select:<part of a name>`: shows that capture in the library.
                if let item = store.items.first(where: { $0.name.localizedCaseInsensitiveContains(arg) }) {
                    LibraryWindow.shared.show(select: item.id)
                } else { result = "no capture named \(arg)" }
            case "fill", "fill-key", "fill-move", "frame":
                // `fill:<library|editor>` presses Fill Screen, `fill-key:` types ⌥⌘F in that window,
                // `fill-move:` nudges it 30 pt; each reports its frame, the screen's and whether it fills.
                let window = arg == "editor" ? EditorWindow.shared.window : LibraryWindow.shared.window
                if let window {
                    switch verb {
                    case "fill": ScreenFill.shared.toggle(window)
                    case "fill-key":
                        window.makeKeyAndOrderFront(nil)
                        try await Task.sleep(for: .seconds(0.3))
                        if let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
                                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                      characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3) {
                            NSApp.postEvent(key, atStart: false)
                        }
                        try await Task.sleep(for: .seconds(1))
                    case "fill-move": window.setFrameOrigin(NSPoint(x: window.frame.minX + 30, y: window.frame.minY))
                    default: break
                    }
                    result = "\(NSStringFromRect(window.frame)) screen \(NSStringFromRect(window.screen?.visibleFrame ?? .zero)) filled \(ScreenFill.shared.isFilled(window))"
                } else { result = "no \(arg) window" }
            case "pop-out": EditorWindow.shared.open()
            case "bring-back": EditorWindow.shared.close()
            case "popped-dial":
                // Opens the dial in the pop-out window's picture.
                if let window = EditorWindow.shared.debugWindow, let scroll = PanTest.find(window.contentView) {
                    window.makeKeyAndOrderFront(nil)
                    scroll.openDial(at: CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), held: false)
                    result = scroll.debugDialInfo
                } else { result = "no pop-out canvas" }
            case "popped-close-dial":
                if let window = EditorWindow.shared.debugWindow, let scroll = PanTest.find(window.contentView) { scroll.closeDial() }
            case "set-default":
                // `set-default:<key>=<text>`: a plain setting, as the app stores it.
                let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { AppDefaults.store.set(parts[1], forKey: parts[0]) }
            case "tool-style": prefs.toolStyle = ToolStyle(rawValue: arg) ?? .toolbar
            case "dial-trigger": prefs.dialTrigger = DialTrigger(rawValue: arg) ?? .rightClick
            case "palette": AppDefaults.store.set(arg, forKey: "editor.palettePlacement")
            case "open-dial":
                if let window = LibraryWindow.shared.window, let scroll = PanTest.find(window.contentView) {
                    scroll.openDial(at: CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), held: false)
                    result = scroll.debugDialInfo
                }
            case "sheet-sizes":
                // How tall the preset editor sheet wants to be, for each preset.
                result = PresetEditor.debugHeights()
            case "pin-dial":
                if let window = LibraryWindow.shared.window, let scroll = PanTest.find(window.contentView) { scroll.debugDialState.pinned = arg != "off" }
            case "close-dial":
                if let window = LibraryWindow.shared.window, let scroll = PanTest.find(window.contentView) { scroll.closeDial() }
            case "pin-test":
                // Pins the dial, clicks a tool on it, draws on the picture, drags the dial,
                // then unpins and clicks a tool again; reports each step.
                result = await PanTest.pinAndDrag()
            case "dial-test":
                // Right-click, Esc, then ⌘⌥ held over the picture with a tool under the pointer.
                result = await PanTest.dial()
            case "scroll-zoom-test":
                // Scrolls over the library's picture with and without ⌃; reports the zoom each time.
                if let window = LibraryWindow.shared.window, let scroll = PanTest.find(window.contentView) {
                    result = PanTest.scrollZoom(scroll)
                } else { result = "no canvas" }
            case "pan-test":
                // `pan-test:<zoom>[:typing]`: zooms in, then holds Space and drags 120 pt right and
                // 60 pt down over the picture with made-up events; reports how far it moved.
                result = await PanTest.run(arg)
            case "tooltip-delay":
                // How long AppKit waits before showing a tooltip, from its tooltip manager.
                let sel = NSSelectorFromString("_getDisplayDelay:inQuickMode:forView:")
                if let cls = NSClassFromString("NSToolTipManager"),
                   let manager = (cls as AnyObject).perform(NSSelectorFromString("sharedToolTipManager"))?.takeUnretainedValue(),
                   let imp = class_getMethodImplementation(cls, sel) {
                    typealias Get = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Double>, UnsafeMutablePointer<ObjCBool>, NSView?) -> Void
                    var delay = 0.0, quick = ObjCBool(false)
                    unsafeBitCast(imp, to: Get.self)(manager, sel, &delay, &quick, NSView())
                    result = "\(delay)"
                }
            case "shoot-library":
                if let window = LibraryWindow.shared.window {
                    let out = URL(fileURLWithPath: arg)
                    await DebugShots.shoot(window, out.deletingPathExtension().lastPathComponent, out: out.deletingLastPathComponent()) { _ in }
                }
            case "sync-off": sync.isEnabled = false
            case "delete-zone":
                // Removes the test zone from iCloud once a test is over.
                sync.isEnabled = false
                _ = try await CloudSync.shared.database.deleteRecordZone(withID: CloudSync.shared.zoneID)
            case "quit": NSApp.terminate(nil)
            default: result = "unknown command"
            }
        } catch {
            result = "error: \(error.localizedDescription)"
        }
        AppDefaults.store.set("\(line) -> \(result)", forKey: "debug.lastCommand")
    }

    private static func writeStatus(_ path: String) {
        let sync = SettingsSync.shared
        let store = LibraryStore.shared
        let prefs = Preferences.shared
        let status: [String: Any] = [
            "keyState": "\(sync.keyState)", "syncError": sync.lastError ?? "", "cloudError": CloudSync.shared.lastError ?? "",
            "engineRunning": CloudSync.shared.isRunning, "lastCommand": AppDefaults.store.string(forKey: "debug.lastCommand") ?? "",
            "settingsFrom": sync.lastSource ?? "", "pending": LibrarySync.shared.pendingUploads,
            "items": store.items.map { item -> [String: Any] in
                ["name": item.name, "tags": item.tags, "notes": item.notes, "favorite": item.favorite,
                 "hasImage": store.pngData(item.id) != nil, "origin": item.origin ?? ""]
            },
            "copyToClipboard": prefs.copyToClipboard, "preset0": prefs.presets.first?.name ?? "",
            "appearance": AppAppearance.current.rawValue,
            "backend": prefs.librarySync ? prefs.libraryBackend.rawValue : "off",
            "folderActive": FolderSync.shared.isActive, "folderError": FolderSync.shared.lastError ?? "",
            "folderNeeded": FolderSync.shared.needsFolder, "iCloudCaptures": LibrarySync.shared.iCloudCaptureCount,
            "windows": NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain }.map(\.title),
            "active": NSApp.isActive,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// A picture with some text on it, for debug hooks and self-tests.
enum DebugImage {
    @MainActor static func make(text: String, size: CGSize = CGSize(width: 640, height: 240)) -> CGImage? {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 36, weight: .semibold),
                                                          .foregroundColor: NSColor.black])
                .draw(in: rect.insetBy(dx: 30, dy: 60))
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
#endif

#if DEBUG
/// Drives Space-drag panning on the library's picture with made-up events, as the
/// `pan-test` debug command.
@MainActor
enum PanTest {
    static func run(_ arg: String) async -> String {
        let parts = arg.split(separator: ":").map(String.init)
        let zoom = parts.first.flatMap(Double.init) ?? 4
        guard let window = LibraryWindow.shared.window, let scroll = find(window.contentView) else { return "no canvas" }
        if parts.contains("typing") {
            // A text field has the keys, so Space should type rather than pan.
            let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
            window.contentView?.addSubview(field)
            window.makeFirstResponder(field)
            defer { field.removeFromSuperview() }
            return await drag(window, scroll, zoom: zoom)
        }
        window.makeFirstResponder(DebugShots.find(window.contentView))
        return await drag(window, scroll, zoom: zoom)
    }

    private static func drag(_ window: NSWindow, _ scroll: ZoomingScrollView, zoom: Double) async -> String {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        CanvasZoom.shared.set(zoom)
        try? await Task.sleep(for: .seconds(0.5))
        let before = scroll.contentView.bounds.origin
        let start = scroll.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        func post(_ event: NSEvent?) async {
            if let event { NSApp.postEvent(event, atStart: false) }
            try? await Task.sleep(for: .milliseconds(30))
        }
        func key(_ type: NSEvent.EventType, repeating: Bool = false) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: start, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                             isARepeat: repeating, keyCode: 49)
        }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        await post(key(.keyDown))
        await post(key(.keyDown, repeating: true))
        let held = scroll.debugPanning.panning
        await post(mouse(.leftMouseDown, start))
        for step in 1...6 {
            await post(mouse(.leftMouseDragged, CGPoint(x: start.x + Double(step) * 20, y: start.y - Double(step) * 10)))
        }
        await post(mouse(.leftMouseUp, CGPoint(x: start.x + 120, y: start.y - 60)))
        await post(key(.keyUp))
        try? await Task.sleep(for: .milliseconds(200))
        let after = scroll.contentView.bounds.origin
        let state = scroll.debugPanning
        let marks = AnnotationEditor.shared.annotations.count
        return String(format: "zoom %.2f held %@ moved x %.1f y %.1f (expect %.1f, %.1f) after: panning %@ grabbing %@ cursorRects %@ marks %d",
                      scroll.magnification, "\(held)", after.x - before.x, after.y - before.y, -120 / scroll.magnification, -60 / scroll.magnification,
                      "\(state.panning)", "\(state.grabbing)", "\(window.areCursorRectsEnabled)", marks)
    }

    static func holdCommand(typing: Bool) async -> String {
        guard let window = LibraryWindow.shared.window, let scroll = find(window.contentView) else { return "no canvas" }
        let editor = AnnotationEditor.shared
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        editor.showResult = false
        CanvasZoom.shared.set(1)
        editor.pick(.draw(.rectangle))
        try? await Task.sleep(for: .seconds(0.5))
        let c = scroll.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        func post(_ event: NSEvent?) async {
            if let event { NSApp.postEvent(event, atStart: false) }
            try? await Task.sleep(for: .milliseconds(60))
        }
        func mouse(_ type: NSEvent.EventType, _ dx: Double, _ dy: Double, flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: c.x + dx, y: c.y + dy), modifierFlags: flags,
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        func command(_ down: Bool) -> NSEvent? {
            NSEvent.keyEvent(with: .flagsChanged, location: c, modifierFlags: down ? [.command] : [],
                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                             characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)
        }
        let before = editor.annotations.count
        await post(mouse(.leftMouseDown, -60, 40))
        await post(mouse(.leftMouseDragged, 0, 0))
        await post(mouse(.leftMouseDragged, 60, -40))
        await post(mouse(.leftMouseUp, 60, -40))
        guard let box = editor.annotations.last, editor.annotations.count == before + 1 else { return "no box drawn" }
        var steps = ["drew box x \(Int(box.rect.minX))"]
        var field: NSTextField?
        if typing {
            field = NSTextField(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
            window.contentView?.addSubview(field!)
            window.makeFirstResponder(field)
        }
        await post(command(true))
        steps.append("⌘ down: tool \(editor.tool)")
        let edge = (box.rect.minX - box.rect.midX) * scroll.magnification
        let flags: NSEvent.ModifierFlags = [.command]
        await post(mouse(.leftMouseDown, edge, 0, flags: flags))
        await post(mouse(.leftMouseDragged, edge + 20, 0, flags: flags))
        await post(mouse(.leftMouseDragged, edge + 40, 0, flags: flags))
        await post(mouse(.leftMouseUp, edge + 40, 0, flags: flags))
        let moved = editor.annotations.first { $0.id == box.id }
        steps.append("after drag: marks +\(editor.annotations.count - before), box x \(Int(moved?.rect.minX ?? -1)), selected \(editor.selection == box.id)")
        await post(command(false))
        steps.append("⌘ up: tool \(editor.tool), selected \(editor.selection == box.id)")
        field?.removeFromSuperview()
        editor.pick(.select)
        return steps.joined(separator: "; ")
    }

    static func dragSidebar(to x: Double) async -> String {
        guard let window = LibraryWindow.shared.window, let split = splitView(window.contentView),
              let sidebar = split.arrangedSubviews.first else { return "no split view" }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let before = sidebar.frame.width
        let edge = split.convert(CGPoint(x: sidebar.frame.maxX + split.dividerThickness / 2, y: split.bounds.midY), to: nil)
        func mouse(_ type: NSEvent.EventType, _ px: Double) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: px, y: edge.y), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        // All at once: the split view follows the drag in a loop of its own.
        var events = [mouse(.leftMouseDown, edge.x)]
        for step in 1...10 { events.append(mouse(.leftMouseDragged, edge.x + (x - edge.x) * Double(step) / 10)) }
        events.append(mouse(.leftMouseUp, x))
        for event in events.compactMap({ $0 }) { NSApp.postEvent(event, atStart: false) }
        try? await Task.sleep(for: .seconds(1.5))
        let shown = split.arrangedSubviews.first.map { split.isSubviewCollapsed($0) ? "collapsed" : "shown" } ?? "-"
        var info = "delegate \(split.delegate.map { String(describing: type(of: $0)) } ?? "none")"
        if let controller = split.delegate as? NSSplitViewController, let item = controller.splitViewItems.first {
            info += ", canCollapse \(item.canCollapse), behavior \(item.behavior.rawValue), minThickness \(item.minimumThickness)"
        }
        return "sidebar \(Int(before)) -> \(Int(split.arrangedSubviews.first?.frame.width ?? -1)) pt, \(shown); \(info)"
    }

    private static func splitView(_ view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView, split.isVertical { return split }
        for sub in view.subviews { if let hit = splitView(sub) { return hit } }
        return nil
    }

    static func dial() async -> String {
        guard let window = LibraryWindow.shared.window, let scroll = find(window.contentView) else { return "no canvas" }
        let editor = AnnotationEditor.shared
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        editor.showResult = false
        editor.pick(.draw(.rectangle))
        try? await Task.sleep(for: .seconds(0.4))
        let c = scroll.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        func post(_ event: NSEvent?) async {
            if let event { NSApp.postEvent(event, atStart: false) }
            try? await Task.sleep(for: .milliseconds(150))
        }
        func flags(_ f: NSEvent.ModifierFlags, _ code: UInt16) -> NSEvent? {
            NSEvent.keyEvent(with: .flagsChanged, location: c, modifierFlags: f, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                             isARepeat: false, keyCode: code)
        }
        var steps: [String] = ["style \(Preferences.shared.toolStyle.rawValue), trigger \(Preferences.shared.dialTrigger.rawValue)"]
        await post(NSEvent.mouseEvent(with: .rightMouseDown, location: c, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        steps.append("right-click: open \(scroll.isDialOpen)")
        await post(NSEvent.keyEvent(with: .keyDown, location: c, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                    isARepeat: false, keyCode: 53))
        steps.append("Esc: open \(scroll.isDialOpen)")
        await post(flags([.command], 55))
        steps.append("⌘: tool \(editor.tool.id), dial \(scroll.isDialOpen)")
        await post(flags([.command, .option], 58))
        steps.append("⌘⌥: dial \(scroll.isDialOpen), held \(scroll.debugDialState.held), tool back to \(editor.tool.id)")
        scroll.debugDialState.hovered = .draw(.ellipse)
        await post(flags([.command], 58))
        steps.append("let go of ⌥ over Ellipse: tool \(editor.tool.id), dial \(scroll.isDialOpen)")
        await post(flags([], 55))
        steps.append("⌘ up: tool \(editor.tool.id)")
        return steps.joined(separator: "; ")
    }

    static func pinAndDrag() async -> String {
        guard let window = LibraryWindow.shared.window, let scroll = find(window.contentView) else { return "no canvas" }
        let editor = AnnotationEditor.shared
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        editor.showResult = false
        CanvasZoom.shared.set(1)
        editor.pick(.draw(.rectangle))
        try? await Task.sleep(for: .seconds(0.4))
        func post(_ event: NSEvent?) async {
            if let event { NSApp.postEvent(event, atStart: false) }
            try? await Task.sleep(for: .milliseconds(120))
        }
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        func click(_ p: CGPoint) async { await post(mouse(.leftMouseDown, p)); await post(mouse(.leftMouseUp, p)) }
        var steps: [String] = []
        let state = scroll.debugDialState
        state.pinned = true
        // Open near the picture's left so there's room to draw on its right.
        scroll.openDial(at: CGPoint(x: scroll.bounds.minX + 210, y: scroll.bounds.midY), held: false)
        try? await Task.sleep(for: .seconds(0.6))
        guard let center = scroll.debugDialCenter else { return "dial didn't open" }
        // The first tool of the inner ring sits straight above the middle.
        let first = ToolUse.ranked()[0]
        await click(CGPoint(x: center.x, y: center.y + 112))
        steps.append("pinned, clicked \(first.id): tool \(editor.tool.id), open \(scroll.isDialOpen)")
        // Draw a box on the picture, away from the dial.
        editor.pick(.draw(.rectangle))
        let before = editor.annotations.count
        let a = scroll.convert(CGPoint(x: scroll.bounds.maxX - 160, y: scroll.bounds.midY + 40), to: nil)
        await post(mouse(.leftMouseDown, a))
        await post(mouse(.leftMouseDragged, CGPoint(x: a.x + 60, y: a.y - 40)))
        await post(mouse(.leftMouseDragged, CGPoint(x: a.x + 100, y: a.y - 70)))
        await post(mouse(.leftMouseUp, CGPoint(x: a.x + 100, y: a.y - 70)))
        steps.append("drew on the picture: marks +\(editor.annotations.count - before), open \(scroll.isDialOpen)")
        // Drag the empty ring between the two circles of tools.
        let grab = CGPoint(x: center.x + 142, y: center.y)
        await post(mouse(.leftMouseDown, grab))
        for i in 1...5 { await post(mouse(.leftMouseDragged, CGPoint(x: grab.x + Double(i) * 12, y: grab.y + Double(i) * 8))) }
        await post(mouse(.leftMouseUp, CGPoint(x: grab.x + 60, y: grab.y + 40)))
        steps.append("dragged 60 right, 40 up: offset \(Int(state.offset.width)), \(Int(state.offset.height)), open \(scroll.isDialOpen)")
        // Unpinned, picking a tool closes it.
        state.pinned = false
        if let moved = scroll.debugDialCenter { await click(CGPoint(x: moved.x, y: moved.y + 112)) }
        steps.append("unpinned, clicked a tool: tool \(editor.tool.id), open \(scroll.isDialOpen)")
        return steps.joined(separator: "; ")
    }

    /// Plain scrolling must leave the zoom alone; ⌃-scrolling zooms, up in and down out.
    static func scrollZoom(_ zoomer: ZoomingScrollView) -> String {
        func wheel(_ lines: Int32, precise: Bool = false, control: Bool = false) {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return }
            if control { cg.flags = .maskControl }
            if let event = NSEvent(cgEvent: cg) { zoomer.scrollWheel(with: event) }
        }
        let start = zoomer.magnification
        wheel(3); wheel(-3); let plain = zoomer.magnification
        wheel(3, control: true); let up = zoomer.magnification
        wheel(-3, control: true); wheel(-3, control: true); let down = zoomer.magnification
        wheel(40, precise: true, control: true); let pad = zoomer.magnification
        return String(format: "scroll zoom: start %.2f, plain scroll %.2f (unchanged), ⌃ wheel up %.2f, ⌃ wheel down twice %.2f, ⌃ trackpad %.2f, slider follows %.2f",
                      start, plain, up, down, pad, CanvasZoom.shared.magnification)
    }

    static func find(_ view: NSView?) -> ZoomingScrollView? {
        guard let view else { return nil }
        if let scroll = view as? ZoomingScrollView { return scroll }
        for sub in view.subviews { if let hit = find(sub) { return hit } }
        return nil
    }
}
#endif
