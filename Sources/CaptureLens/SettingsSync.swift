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
    /// Whether this Mac's settings (and the library window's layout) go to and come from the
    /// other Macs. The library has its own switch; both share the passphrase. Each Mac decides.
    var syncsSettings: Bool {
        didSet {
            guard syncsSettings != oldValue else { return }
            defaults.set(syncsSettings, forKey: Keys.settings)
            if syncsSettings { settingsBackOn() }
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
        static let settings = "sync.settings"
        /// The newest settings another Mac shared while this Mac's settings sync was off.
        static let heldSettings = "sync.heldSettings"
    }

    /// Settings that follow the user between Macs.
    static var syncedKeys: [String] {
        Preferences.keys.filter { !Preferences.perMacKeys.contains($0) } + ["showInDock", "showInMenuBar", MenuHub.foldKey, AppAppearance.key, UpdatePolicy.key,
         UpdateInterval.valueKey, UpdateInterval.unitKey, LibraryLayout.key]
    }

    var isReady: Bool { isEnabled && keyState == .ready && key != nil }

    /// Must not touch Preferences: its initializer can report changes here.
    private init() {
        isEnabled = defaults.bool(forKey: Keys.enabled)
        syncsSettings = defaults.object(forKey: Keys.settings) as? Bool ?? true
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
        guard !applying, syncsSettings else { return }
        localModified = Self.now
        if CloudSync.shared.isRunning { CloudSync.shared.queueSave([CloudSync.Name.settings]) }
    }

    private func afterEngineStart() {
        // If nothing came down from iCloud, this Mac's settings become the shared copy.
        settingsSeenThisRun = false
        CloudSync.shared.afterFirstFetch { [weak self] in
            guard let self, self.syncsSettings, !self.settingsSeenThisRun,
                  !CloudSync.shared.knowsServerRecord(CloudSync.Name.settings) else { return }
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
        guard syncsSettings else {
            // Kept for if settings sync comes back on here.
            defaults.set(sealed, forKey: Keys.heldSettings)
            return
        }
        if let local = localModified, local > remote.updatedAt {
            CloudSync.shared.queueSave([CloudSync.Name.settings])
        } else if localModified == nil || remote.updatedAt > localModified! {
            apply(remote)
        } else {
            // The same settings: nothing to do.
            noteSynced(remote)
        }
    }

    /// Settings sync turned back on: settings another Mac shared meanwhile win; otherwise this
    /// Mac's go up.
    private func settingsBackOn() {
        if let held = defaults.data(forKey: Keys.heldSettings) {
            defaults.removeObject(forKey: Keys.heldSettings)
            receivedSettings(held)
        } else {
            localModified = Self.now
            if CloudSync.shared.isRunning { CloudSync.shared.queueSave([CloudSync.Name.settings]) }
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
        if let layout = AppDefaults.store.dictionary(forKey: LibraryLayout.key) { settings[LibraryLayout.key] = layout }
        let plist: [String: Any] = ["version": 3, "updatedAt": updatedAt, "updatedBy": Self.deviceName, "settings": settings]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0),
              let sealed = try? SyncCrypto.seal(data, using: key) else { return nil }
        if localModified == nil { localModified = updatedAt }
        noteSynced(Document(updatedAt: updatedAt, updatedBy: Self.deviceName, settings: settings))
        return sealed
    }

    #if DEBUG
    /// Settings another Mac shares while this Mac's settings sync is off are held, then taken
    /// up when it's switched back on. Plays that through with a made-up key and record.
    func debugHeldTest() -> String {
        let savedKey = key, savedOn = syncsSettings, savedModified = localModified
        let prefs = Preferences.shared
        let original = prefs.playSound
        key = SymmetricKey(size: .bits256)
        defer { key = savedKey }
        syncsSettings = false
        // The other Mac's settings: this Mac's with the sound flipped, made just now.
        localModified = Self.now.addingTimeInterval(-60)
        prefs.playSound = !original
        localModified = Self.now.addingTimeInterval(1)
        guard let key, let remote = sealedSettings(using: key) else { return "couldn't seal" }
        localModified = Self.now.addingTimeInterval(-60)
        prefs.playSound = original
        receivedSettings(remote)
        var steps = ["off: held \(defaults.data(forKey: Keys.heldSettings) != nil), sound unchanged \(prefs.playSound == original)"]
        syncsSettings = true
        steps.append("on: held cleared \(defaults.data(forKey: Keys.heldSettings) == nil), took the other Mac's sound \(prefs.playSound == !original)")
        prefs.playSound = original
        syncsSettings = savedOn
        localModified = savedModified
        return steps.joined(separator: "; ")
    }

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
            case "settings": if arg.isEmpty { SettingsWindow.shared.show() } else { SettingsWindow.shared.show(tab: arg) }
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
            case "fold":
                // `fold:<captures|editor|none>`: folds that side of the library to a slim bar.
                LibraryWindow.shared.state.fold(LibraryState.Side(rawValue: arg))
            case "windows":
                // Every window the app has: class, number, frame, title, what it shows.
                result = NSApp.windows.map { w in
                    "\(type(of: w))#\(w.windowNumber) \(NSStringFromRect(w.frame)) visible \(w.isVisible) level \(w.level.rawValue) '\(w.title)' content \(w.contentView.map { String(describing: type(of: $0)) } ?? "-") sub \(w.contentView?.subviews.map { String(describing: type(of: $0)) } ?? []) parent \(w.parent?.windowNumber ?? 0)"
                }.joined(separator: " || ")
                    + " || first responder: \(LibraryWindow.shared.window?.firstResponder.map { String(describing: $0) } ?? "-")"
                    + " || input client: \((NSTextInputContext.current?.client as? NSView).map { v in "\(type(of: v)) \(NSStringFromRect(v.convert(v.bounds, to: nil)))" } ?? "-")"
            case "views-at":
                // `views-at:<x>,<y>`: the AppKit views covering that point of the library window
                // (points from its top left), innermost last, with their frames in the window.
                let p = arg.split(separator: ",").compactMap { Double($0) }
                if p.count == 2, let window = LibraryWindow.shared.window, let root = window.contentView?.superview {
                    let at = CGPoint(x: p[0], y: window.frame.height - p[1])
                    var hits: [String] = []
                    func walk(_ view: NSView, depth: Int) {
                        let frame = view.convert(view.bounds, to: nil)
                        guard !view.isHidden, frame.contains(at) else { return }
                        if frame.width < 200 || frame.height < 200 {
                            hits.append("\(depth):\(type(of: view)) \(Int(frame.minX)),\(Int(window.frame.height - frame.maxY)) \(Int(frame.width))x\(Int(frame.height))")
                        }
                        for sub in view.subviews { walk(sub, depth: depth + 1) }
                    }
                    walk(root, depth: 0)
                    result = hits.joined(separator: " | ")
                }
            case "double-click-opens": if let place = OpenPlace(rawValue: arg) { prefs.doubleClickOpens = place }
            case "double-click-at":
                // `double-click-at:<x>,<y>`: double-clicks the library window there (points from its
                // top left); reports which windows are open after.
                let p = arg.split(separator: ",").compactMap { Double($0) }
                if p.count == 2, let window = LibraryWindow.shared.window {
                    window.makeKeyAndOrderFront(nil)
                    let at = CGPoint(x: p[0], y: window.frame.height - p[1])
                    for clicks in [1, 2] {
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            if let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [],
                                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                                              windowNumber: window.windowNumber, context: nil,
                                                              eventNumber: 0, clickCount: clicks, pressure: 1) {
                                NSApp.postEvent(event, atStart: false)
                            }
                            try await Task.sleep(for: .milliseconds(40))
                        }
                    }
                    try await Task.sleep(for: .seconds(1))
                }
                let state = LibraryWindow.shared.state
                result = "editor window \(EditorWindow.shared.isOpen), inspector \(state.showInspector), selected \(state.selectedItems.map(\.name))"
            case "sync-settings": SettingsSync.shared.syncsSettings = arg == "on"
            case "sync-state":
                let defaults = AppDefaults.store
                result = "settings \(SettingsSync.shared.syncsSettings), localModified \((defaults.object(forKey: "sync.localModified") as? Date).map { "\($0.timeIntervalSince1970)" } ?? "nil"), synced keys include librarySync \(SettingsSync.syncedKeys.contains("librarySync")) libraryBackend \(SettingsSync.syncedKeys.contains("libraryBackend")) doubleClickOpens \(SettingsSync.syncedKeys.contains("doubleClickOpens"))"
            case "record-bar":
                // `record-bar` shows the panel before recording (no recording starts); `record-bar:close` hides it.
                if arg == "close" { await ScreenRecorder.shared.debugReset() } else {
                    _ = ScreenRecorder.shared.debugShowBar(over: CGRect(x: 300, y: 600, width: 640, height: 360))
                }
            case "pref":
                // `pref:<name>=<on|off|number>` for the recording choices, as Settings would set them.
                let kv = arg.split(separator: "=").map(String.init)
                if kv.count == 2 {
                    let on = kv[1] == "on"
                    switch kv[0] {
                    case "sound": prefs.recordSystemAudio = on
                    case "mic": prefs.recordMicrophone = on
                    case "clicks": prefs.showClicks = on
                    case "keys": prefs.showKeys = on
                    case "countdown": prefs.recordCountdown = Int(kv[1]) ?? 3
                    case "fps": prefs.recordFrameRate = Int(kv[1]) ?? 30
                    default: break
                    }
                }
                result = "sound \(prefs.recordSystemAudio) mic \(prefs.recordMicrophone) camera \(prefs.recordCamera) clicks \(prefs.showClicks) keys \(prefs.showKeys) fps \(prefs.recordFrameRate) countdown \(prefs.recordCountdown) mics \(RecordingDevices.microphones().count) cameras \(RecordingDevices.cameras().count)"
            case "context-menu":
                // `context-menu:<x>,<y>[,<item title to pick>]`: right-clicks the library window there,
                // lists the menu (✓ for ticked), and picks that item.
                let parts = arg.split(separator: ",", maxSplits: 2).map(String.init)
                let p = parts.prefix(2).compactMap { Double($0) }
                guard p.count == 2, let window = LibraryWindow.shared.window else { result = "need x,y"; break }
                window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(300))
                let pick = parts.count > 2 ? parts[2] : nil
                var listing = "no menu"
                let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                    guard let menu = note.object as? NSMenu else { return }
                    listing = menu.items.prefix(6).map { ($0.state == .on ? "✓" : "") + ($0.isSeparatorItem ? "—" : $0.title) }.joined(separator: " | ")
                    let index = pick.flatMap { title in menu.items.firstIndex { $0.title == title } }
                    let timer = Timer(timeInterval: 0.3, repeats: false) { _ in
                        menu.cancelTracking()
                        if let index { menu.performActionForItem(at: index) }
                    }
                    RunLoop.main.add(timer, forMode: .common)
                }
                let at = CGPoint(x: p[0], y: window.frame.height - p[1])
                for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                try await Task.sleep(for: .seconds(1.5))
                NotificationCenter.default.removeObserver(observer)
                let state = LibraryWindow.shared.state
                result = "\(listing) || picked \(pick ?? "-"): editor window \(EditorWindow.shared.isOpen), inspector \(state.showInspector), double-click \(prefs.doubleClickOpens.rawValue), remember \(AppDefaults.store.bool(forKey: "library.rememberOpen"))"
            case "click-window":
                // `click-window:<window number>,<x>,<y>`: a click in any of the app's windows (points
                // from its top left).
                let p = arg.split(separator: ",").compactMap { Double($0) }
                if p.count == 3, let window = NSApp.windows.first(where: { $0.windowNumber == Int(p[0]) }) {
                    let at = CGPoint(x: p[1], y: window.frame.height - p[2])
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            NSApp.postEvent(event, atStart: false)
                        }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    try await Task.sleep(for: .milliseconds(400))
                }
                result = "clicks \(prefs.showClicks) keys \(prefs.showKeys) countdown \(prefs.recordCountdown)"
            case "open-as":
                // `open-as:<sidePane|ownWindow>,<remember on|off>`: what the right-click menu's Open items do.
                let parts = arg.split(separator: ",").map(String.init)
                let state = LibraryWindow.shared.state
                if let place = OpenPlace(rawValue: parts.first ?? ""), let id = state.selectedItems.first?.id {
                    state.open(id, in: place, remember: parts.count > 1 && parts[1] == "on")
                }
                try await Task.sleep(for: .milliseconds(500))
                result = "editor window \(EditorWindow.shared.isOpen), inspector \(state.showInspector), double-click \(prefs.doubleClickOpens.rawValue)"
            case "held-test": result = SettingsSync.shared.debugHeldTest()
            case "touch-setting": prefs.playSound.toggle(); SettingsSync.shared.localDidChange()
            case "layout":
                // The synced layout record, whether it's been taken up, and the window as it is.
                let stored = AppDefaults.store.dictionary(forKey: LibraryLayout.key) ?? [:]
                let state = LibraryWindow.shared.state
                let record = stored.keys.sorted().map { key in
                    let value = stored[key]
                    if let d = value as? Double, !(value is Bool) { return "\(key)=\(String(format: "%.3f", d))" }
                    return "\(key)=\(value ?? "-")"
                }.joined(separator: " ")
                result = "record: \(record) | applied \(AppDefaults.store.string(forKey: "libraryLayout.applied") == stored["stamp"] as? String) | now: sidebar \(LibraryLayout.sidebarWidth) thumbs \(Int(state.thumbnailSize)) folded \(state.foldedSide?.rawValue ?? "none") inspector \(state.showInspector) sort \(state.sort.rawValue) window \(Int(LibraryWindow.shared.window?.frame.width ?? 0)) | notes \(LibraryLayout.debugNotes)"
            case "layout-remote":
                // `layout-remote:<key>=<value>;…`: as if another Mac's layout arrived (the current record
                // with those changes and a new stamp). Numbers become shares, true/false flags.
                var layout = AppDefaults.store.dictionary(forKey: LibraryLayout.key) ?? [:]
                for pair in arg.split(separator: ";") {
                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    guard kv.count == 2 else { continue }
                    if let number = Double(kv[1]) { layout[kv[0]] = number }
                    else if kv[1] == "true" || kv[1] == "false" { layout[kv[0]] = kv[1] == "true" }
                    else { layout[kv[0]] = kv[1] }
                }
                layout["stamp"] = UUID().uuidString
                AppDefaults.store.set(layout, forKey: LibraryLayout.key)
            case "layout-roundtrip":
                // Seals the settings, loses the layout here, and takes it back from the sealed copy.
                let before = AppDefaults.store.dictionary(forKey: LibraryLayout.key) ?? [:]
                _ = SettingsSync.shared.debugRoundTrip(using: SymmetricKey(size: .bits256)) {
                    AppDefaults.store.removeObject(forKey: LibraryLayout.key)
                }
                let after = AppDefaults.store.dictionary(forKey: LibraryLayout.key) ?? [:]
                result = "keys before \(before.count), after \(after.count), same stamp \((before["stamp"] as? String) == (after["stamp"] as? String))"
            case "close-library": LibraryWindow.shared.window?.close()
            case "drag-at":
                // `drag-at:<x>,<y>,<toX>`: drags across the library window (points from its top
                // left) in steps; reports the selected capture's column width after.
                let p = arg.split(separator: ",").compactMap { Double($0) }
                if p.count >= 3, let window = LibraryWindow.shared.window {
                    window.makeKeyAndOrderFront(nil)
                    // A fourth number drags down or up to that y as well.
                    let toY = p.count > 3 ? p[3] : p[1]
                    func mouse(_ type: NSEvent.EventType, _ x: Double) -> NSEvent? {
                        let along = p[2] == p[0] ? 1 : (x - p[0]) / (p[2] - p[0])
                        let y = type == .leftMouseDown ? p[1] : p[1] + (toY - p[1]) * along
                        return NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: window.frame.height - y), modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                    }
                    var events: [NSEvent?] = []
                    if p[2] == p[0] {
                        // Straight up or down: step the y instead.
                        func vertical(_ type: NSEvent.EventType, _ y: Double) -> NSEvent? {
                            NSEvent.mouseEvent(with: type, location: CGPoint(x: p[0], y: window.frame.height - y), modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                        }
                        events.append(vertical(.leftMouseDown, p[1]))
                        for step in 1...12 { events.append(vertical(.leftMouseDragged, p[1] + (toY - p[1]) * Double(step) / 12)) }
                        events.append(vertical(.leftMouseUp, toY))
                    } else {
                        events.append(mouse(.leftMouseDown, p[0]))
                        for step in 1...12 { events.append(mouse(.leftMouseDragged, p[0] + (p[2] - p[0]) * Double(step) / 12)) }
                        events.append(mouse(.leftMouseUp, p[2]))
                    }
                    for event in events.compactMap({ $0 }) {
                        NSApp.postEvent(event, atStart: false)
                        try await Task.sleep(for: .milliseconds(30))
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
                result = "detail share \(AppDefaults.store.double(forKey: LibraryLayout.detailKey)), picture share \(AppDefaults.store.double(forKey: LibraryLayout.pictureKey))"
            case "click-at":
                // `click-at:<x>,<y>`: clicks the library window there (points from its top left);
                // reports which side is folded after.
                let p = arg.split(separator: ",").compactMap { Double($0) }
                if p.count == 2, let window = LibraryWindow.shared.window {
                    window.makeKeyAndOrderFront(nil)
                    let at = CGPoint(x: p[0], y: window.frame.height - p[1])
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: window.windowNumber, context: nil,
                                                          eventNumber: 0, clickCount: 1, pressure: 1) {
                            NSApp.postEvent(event, atStart: false)
                        }
                        try await Task.sleep(for: .milliseconds(150))
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
                result = "folded \(LibraryWindow.shared.state.foldedSide?.rawValue ?? "none")"
            case "collect":
                // `collect:<screenshot|snagit>,<none|week|month|quarter|all>`: turns collecting on.
                let parts = arg.split(separator: ",").map(String.init)
                if let tool = CaptureCollector.Tool(rawValue: parts.first ?? ""),
                   let lookback = CaptureCollector.Lookback(rawValue: parts.count > 1 ? parts[1] : "none") {
                    CaptureCollector.shared.turnOn(tool, lookingBack: lookback)
                } else { result = "bad collect:\(arg)" }
            case "make-snagx":
                // `make-snagx:<path>,<text>`: writes a Snagit capture file of that text, taken now.
                let parts = arg.split(separator: ",", maxSplits: 1).map(String.init)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                if parts.count == 2, let png = DebugImage.make(text: parts[1])?.pngData {
                    try DebugSelfTest.snagx(png: png, drawn: nil, objects: [], tags: ["collected"], date: formatter.string(from: Date()))
                        .write(to: URL(fileURLWithPath: parts[0]))
                }
            case "collect-off": if let tool = CaptureCollector.Tool(rawValue: arg) { CaptureCollector.shared.turnOff(tool) }
            case "collected":
                // Reports what's been brought in, and the newest captures' kind, tool and app.
                let c = CaptureCollector.shared
                let newest = store.items.prefix(Int(arg) ?? 3).map {
                    "\($0.kind.rawValue)/\($0.source.tool ?? "-")/app \($0.source.appName == nil ? "no" : "yes")/window \($0.source.windowTitle == nil ? "no" : "yes")/tags \($0.tags.joined(separator: "+"))/\($0.pixelWidth)x\($0.pixelHeight)@\($0.scale)"
                }
                result = "counts \(c.counts.map { "\($0.key.rawValue)=\($0.value)" }.sorted()), waiting \(c.waiting), items \(store.items.count), newest \(newest)"
            case "bulk":
                // `bulk:<n>`: adds n small made-up captures with a spread of tags, apps and sites.
                result = MenuTest.addBulk(Int(arg) ?? 100)
            case "update-test":
                // `update-test:<n>`: changes the newest capture's notes n times, timing how long
                // the window takes to catch up after each.
                result = await MenuTest.updates(Int(arg) ?? 5)
            case "bulk-unique": result = MenuTest.addUnique(Int(arg) ?? 100)
            case "menu-test":
                // `menu-test:<filter name>`: opens that filter's menu, reports how long it took.
                result = await MenuTest.open(arg)
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
            case "tab-sizes":
                // Every Settings tab in turn: the window's size, and whether it's all on its screen.
                var sizes: [String] = []
                for tab in ["Capture", "Presets", "Library", "Privacy", "Activity", "General"] {
                    SettingsWindow.shared.show(tab: tab)
                    try await Task.sleep(for: .milliseconds(700))
                    if let window = SettingsWindow.shared.debugWindow {
                        let onScreen = window.screen.map { $0.visibleFrame.contains(window.frame) } ?? false
                        let tabs = window.contentViewController as? NSTabViewController
                        let wanted = tabs.map { $0.tabViewItems[$0.selectedTabViewItemIndex].viewController?.preferredContentSize.height ?? -1 } ?? -1
                        sizes.append("\(tab) \(Int(window.frame.width))x\(Int(window.frame.height)) (content \(Int(window.contentLayoutRect.height)), wanted \(Int(wanted)))\(onScreen ? "" : " OFF SCREEN")")
                    }
                }
                result = sizes.joined(separator: ", ")
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
            case "quit": QuitConfirmation.quitNow()
            case "quit-test":
                // `quit-test:<return|cancel|quit|suppress|off>`: quits as ⌘Q does, then answers
                // the question a second later: presses Return, clicks Cancel or Quit (ticking
                // "Don't ask again" first for `suppress`), or with `off` turns the setting off
                // first. What the question looked like goes to `debug.quitTest` before any answer.
                if arg == "off" { prefs.confirmQuit = false }
                AppDefaults.store.set("no question", forKey: "debug.quitTest")
                let answer = Timer(timeInterval: 1, repeats: false) { _ in
                    MainActor.assumeIsolated { QuitTest.answer(arg) }
                }
                RunLoop.main.add(answer, forMode: .common)
                NSApp.terminate(nil)
                try await Task.sleep(for: .milliseconds(500))
                result = "still running; \(AppDefaults.store.string(forKey: "debug.quitTest") ?? "-"); confirmQuit \(prefs.confirmQuit); policy \(NSApp.activationPolicy().rawValue)"
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
            // Each picture is read from the database, too slow for a big test library every second.
            "items": store.items.count > 200 ? [] : store.items.map { item -> [String: Any] in
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
enum MenuTest {

    /// `bulk-unique:<n>`: n captures, each with a website and tag of its own.
    static func addUnique(_ count: Int) -> String {
        let store = LibraryStore.shared
        guard let image = DebugImage.make(text: "Bulk", size: CGSize(width: 64, height: 40)) else { return "no image" }
        for i in 0..<count {
            let site = "https://unique\(i).example.org/page"
            guard var item = store.add(image: image, kind: .region, scale: 2,
                                       source: .init(appName: "Browser \(i % 150)", bundleID: "com.example.browser\(i % 150)",
                                                     windowTitle: "W", url: site, pageTitle: "P"),
                                       cursor: nil, created: Date().addingTimeInterval(-Double(i) * 600), analyze: false) else { continue }
            item.tags = ["unique\(i)"]
            store.update(item)
        }
        return "\(store.items.count) in all"
    }

    static func addBulk(_ count: Int) -> String {
        let store = LibraryStore.shared
        guard let image = DebugImage.make(text: "Bulk", size: CGSize(width: 64, height: 40)) else { return "no image" }
        let apps = (0..<40).map { ("App \($0)", "com.example.app\($0)") }
        let start = Date()
        for i in 0..<count {
            let app = apps[(i * 7) % apps.count]
            let site = i % 3 == 0 ? "https://site\(i % 80).example.com/page" : nil
            guard var item = store.add(image: image, kind: .region, scale: 2,
                                       source: .init(appName: app.0, bundleID: app.1, windowTitle: "Window \(i)", url: site,
                                                     pageTitle: site == nil ? nil : "Page \(i)"),
                                       cursor: nil, created: Date().addingTimeInterval(-Double(i) * 3_600), analyze: false) else { continue }
            item.tags = ["tag\(i % 60)", "group\(i % 7)"]
            item.name = "Bulk capture \(i)"
            item.nameIsAutomatic = false
            store.update(item)
        }
        return "added \(count) in \(Int(Date().timeIntervalSince(start)))s, \(store.items.count) in all"
    }

    static func updates(_ count: Int) async -> String {
        let store = LibraryStore.shared
        var times: [Int] = []
        for i in 0..<count {
            guard var item = store.items.first else { return "empty" }
            let start = Date()
            item.notes = "Change \(i)"
            store.update(item)
            // Two turns of the run loop: SwiftUI redraws in the first.
            for _ in 0..<2 { await withCheckedContinuation { c in RunLoop.main.perform { c.resume() } } }
            times.append(Int(Date().timeIntervalSince(start) * 1000))
            try? await Task.sleep(for: .milliseconds(count > 10 ? 20 : 200))
        }
        return "ms per change: \(times.map(String.init).joined(separator: " "))"
    }

    /// Clicks a filter's menu button (`x,y` in points from the window's top left) and times
    /// how long until the menu is up, with how many items.
    static func open(_ arg: String) async -> String {
        guard let window = LibraryWindow.shared.window else { return "no library window" }
        let p = arg.split(separator: ",").compactMap { Double($0) }
        guard p.count >= 2 else { return "need x,y" }
        let hold = p.count > 2 ? p[2] : 0.3
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(0.5))
        let at = CGPoint(x: p[0], y: window.frame.height - p[1])
        func mouse(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        var report = "not opened"
        let start = Date()
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu else { return }
            report = "opened in \(Int(Date().timeIntervalSince(start) * 1000)) ms with \(menu.items.count) items"
            // A fourth number picks that entry, as a click on it would.
            if p.count > 3, Int(p[3]) < menu.items.count {
                let index = Int(p[3])
                DispatchQueue.main.async {
                    menu.cancelTracking()
                    menu.performActionForItem(at: index)
                }
            }
            // Close it again once it has drawn.
            let timer = Timer(timeInterval: hold, repeats: false) { _ in menu.cancelTracking() }
            RunLoop.main.add(timer, forMode: .common)
        }
        if let down = mouse(.leftMouseDown), let up = mouse(.leftMouseUp) {
            NSApp.postEvent(down, atStart: false)
            NSApp.postEvent(up, atStart: false)
        }
        try? await Task.sleep(for: .seconds(1.2 + hold))
        NotificationCenter.default.removeObserver(observer)
        let filter = LibraryWindow.shared.state.filter
        return report + "; filter tags \(filter.tags.sorted()) apps \(filter.apps.sorted()) kinds \(filter.kinds.map(\.title)), shown \(LibraryWindow.shared.state.results.count)"
    }
}

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

/// Answers the quit question for `quit-test`, recording what it showed first.
@MainActor
enum QuitTest {
    static func answer(_ how: String) {
        guard let window = NSApp.modalWindow else { return }
        var texts: [String] = []
        var buttons: [NSButton] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton { buttons.append(button) }
            else if let field = view as? NSTextField, !field.stringValue.isEmpty { texts.append(field.stringValue) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        let titles = buttons.map { "\($0.title)[\($0.keyEquivalent == "\r" ? "Return" : $0.keyEquivalent == "\u{1b}" ? "Esc" : $0.keyEquivalent)]" }
        AppDefaults.store.set("asked \(texts) buttons \(titles) key \(window.isKeyWindow) active \(NSApp.isActive) policy \(NSApp.activationPolicy().rawValue)",
                              forKey: "debug.quitTest")
        AppDefaults.store.synchronize()
        switch how {
        case "return":
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "\r",
                                            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                NSApp.postEvent(event, atStart: false)
            }
        case "cancel": buttons.first { $0.title == "Cancel" }?.performClick(nil)
        case "quit", "suppress":
            if how == "suppress" { buttons.first { $0.title == "Don't ask again" }?.performClick(nil) }
            buttons.first { $0.title == "Quit" }?.performClick(nil)
        default: break
        }
    }
}
#endif
