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
