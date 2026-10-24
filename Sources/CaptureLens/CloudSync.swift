import AppKit
import CloudKit
import Foundation
import Observation
import CaptureLensKit

/// CaptureLens's link to CloudKit: one `CKSyncEngine` on the private database, in the zone
/// "CaptureLens" of container iCloud.com.smanke.CaptureLens.
///
/// Records (everything but the keyring is sealed with the sync key before it leaves the Mac):
///     Keyring          the data key wrapped by the sync passphrase   field data (bytes)
///     Settings         the shared settings                           field data (bytes)
///     Capture_<uuid>   one capture's details, and its picture        fields meta (bytes), image (asset)
///
/// `SettingsSync` owns the keyring and decides when the engine runs (only while this Mac
/// holds the key); `LibrarySync` supplies and receives the captures here.
@Observable
@MainActor
final class CloudSync: CKSyncEngineDelegate {
    static let shared = CloudSync()

    static let containerID = "iCloud.com.smanke.CaptureLens"

    /// Whether this build may use CloudKit at all. A copy signed without the iCloud
    /// entitlement (a local test build) would crash on its first CloudKit call.
    static let isEntitled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains("CloudKit") == true
    }()

    enum RecordType {
        static let keyring = "Keyring"
        static let settings = "Settings"
        static let capture = "Capture"
    }

    enum Name {
        static let keyring = "Keyring"
        static let settings = "Settings"
        static let capturePrefix = "Capture_"
        static func capture(_ id: UUID) -> String { capturePrefix + id.uuidString }
    }

    /// When the engine last finished fetching or sending.
    private(set) var lastSynced: Date?
    /// Captures waiting to go up.
    private(set) var pendingCaptures = 0
    /// The most recent problem talking to iCloud, for Settings.
    private(set) var lastError: String?

    @ObservationIgnored private(set) var engine: CKSyncEngine?
    @ObservationIgnored private var fetchTimer: Timer?
    @ObservationIgnored private var observingWake = false
    /// Waiting for the first fetch after the engine started, before uploading what might
    /// already be in iCloud (so a newer copy there is seen first).
    @ObservationIgnored private var afterFirstFetch: [() -> Void] = []
    @ObservationIgnored private var firstFetchDone = false
    @ObservationIgnored private var tempAssets: [URL] = []

    @ObservationIgnored lazy var container = CKContainer(identifier: Self.containerID)
    var database: CKDatabase { container.privateCloudDatabase }

    static var zoneName: String {
        #if DEBUG
        if let zone = ProcessInfo.processInfo.environment["CAPTURELENS_CLOUD_ZONE"] { return zone }
        #endif
        return "CaptureLens"
    }
    let zoneID = CKRecordZone.ID(zoneName: CloudSync.zoneName, ownerName: CKCurrentUserDefaultName)

    private var db: LibraryDatabase? { LibraryStore.shared.db }

    private enum Keys {
        static let state = "ck.state"
        static let engineKey = "ck.engineKey"
        static let pollToken = "ck.pollToken"
        static let systemFieldsPrefix = "ck.sys."
    }

    func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }

    // MARK: - Engine lifecycle

    var isRunning: Bool { engine != nil }

    /// Starts syncing with the key whose fingerprint is `keyID`. A different key than last
    /// time starts from scratch: everything is fetched again and this Mac's data re-sent.
    func startEngine(keyID: String) {
        guard engine == nil, Self.isEntitled, let db else { return }
        var state: CKSyncEngine.State.Serialization?
        let fresh = db.string(forKey: Keys.engineKey) != keyID
        if fresh {
            try? db.removeValues(withPrefix: Keys.systemFieldsPrefix)
            try? db.set(nil as Data?, forKey: Keys.pollToken)
            try? db.set(nil as Data?, forKey: Keys.state)
            try? db.set(keyID, forKey: Keys.engineKey)
        } else if let data = db.data(forKey: Keys.state) {
            state = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        }
        let configuration = CKSyncEngine.Configuration(database: database, stateSerialization: state, delegate: self)
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        firstFetchDone = false
        if fresh || state == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        NSLog("CaptureLens: CloudKit sync started (zone \(zoneID.zoneName)\(fresh ? ", fresh" : ""))")
        updatePending()
        fetchNow()
        // Test copies on one Mac share its push address, and pushes can be late: look now
        // and then as well.
        fetchTimer?.invalidate()
        fetchTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { CloudSync.shared.fetchNow() }
        }
        if !observingWake {
            observingWake = true
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { CloudSync.shared.fetchNow() }
            }
        }
        LibrarySync.shared.start()
        FolderSync.shared.start()
    }

    func stopEngine() {
        guard engine != nil else { return }
        engine = nil
        fetchTimer?.invalidate()
        fetchTimer = nil
        afterFirstFetch.removeAll()
        updatePending()
        NSLog("CaptureLens: CloudKit sync stopped")
    }

    /// Forgets everything known about the server (after starting over or an account change).
    func resetEngine() {
        stopEngine()
        try? db?.removeValues(withPrefix: Keys.systemFieldsPrefix)
        try? db?.set(nil as Data?, forKey: Keys.state)
        try? db?.set(nil as String?, forKey: Keys.engineKey)
        try? db?.set(nil as Data?, forKey: Keys.pollToken)
    }

    /// Looks for other Macs' changes now. The engine fetches when a push says something
    /// changed, but pushes can be late or missed (and test copies on one Mac share its push
    /// address), and it won't ask the server on demand. So this asks CloudKit directly for
    /// what changed in the zone since the last look.
    func fetchNow() {
        guard engine != nil else { return }
        DebugLog.write("fetchNow")
        Task { await poll() }
    }

    @ObservationIgnored private var polling = false

    private func poll() async {
        guard engine != nil, !polling, let db else { return }
        polling = true
        defer { polling = false }
        var token: CKServerChangeToken? = db.data(forKey: Keys.pollToken).flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }
        // The first look only notes where the zone is (record names, no contents): the
        // engine's own first fetch brings everything already there.
        let baseline = token == nil
        do {
            var more = true
            while more, engine != nil {
                let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: token,
                                                                 desiredKeys: baseline ? [] : nil)
                if !baseline {
                    let records = page.modificationResultsByID.values.compactMap { try? $0.get().record }
                    if !records.isEmpty || !page.deletions.isEmpty {
                        DebugLog.write("polled \(records.map(\.recordID.recordName)) deleted \(page.deletions.map(\.recordID.recordName))")
                        applyFetched(records, deletions: page.deletions.map(\.recordID))
                    }
                }
                token = page.changeToken
                more = page.moreComing
                if let data = try? NSKeyedArchiver.archivedData(withRootObject: page.changeToken, requiringSecureCoding: true) {
                    try? db.set(data, forKey: Keys.pollToken)
                }
            }
            lastSynced = Date()
            LibrarySync.shared.didSync()
        } catch let error as CKError where error.code == .changeTokenExpired {
            // The zone was replaced (someone started over) or the position is too old: look
            // from here on, and make sure the key still fits.
            DebugLog.write("poll: change token expired")
            try? db.set(nil as Data?, forKey: Keys.pollToken)
            SettingsSync.shared.verifyKeyring()
        } catch let error as CKError where error.code == .zoneNotFound {
            // The zone is gone: someone started over or deleted the synced data.
            guard engine != nil else { return }
            DebugLog.write("poll: zone not found")
            resetEngine()
            SettingsSync.shared.keyringChangedElsewhere()
        } catch {
            DebugLog.write("poll error \(error)")
            note(error)
        }
    }

    func sendNow() {
        guard let engine else { return }
        Task {
            do { try await engine.sendChanges() } catch { self.note(error) }
        }
    }

    /// Runs `work` once the engine has fetched what's already in iCloud.
    func afterFirstFetch(_ work: @escaping () -> Void) {
        guard engine != nil else { return }
        if firstFetchDone { work() } else { afterFirstFetch.append(work) }
    }

    func queueSave(_ names: [String]) {
        guard let engine, !names.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: names.map { .saveRecord(recordID($0)) })
        updatePending()
    }

    func queueDelete(_ names: [String]) {
        guard let engine, !names.isEmpty else { return }
        let ids = names.map(recordID)
        // A save still waiting for something now deleted would only fail.
        engine.state.remove(pendingRecordZoneChanges: ids.map { .saveRecord($0) })
        engine.state.add(pendingRecordZoneChanges: ids.map { .deleteRecord($0) })
        updatePending()
    }

    private func updatePending() {
        let count = engine?.state.pendingRecordZoneChanges.filter {
            if case .saveRecord(let id) = $0 { return id.recordName.hasPrefix(Name.capturePrefix) }
            return false
        }.count ?? 0
        if count != pendingCaptures { pendingCaptures = count }
    }

    // MARK: - Direct calls (no engine): the keyring, starting over

    /// The keyring in iCloud, or nil if there's none yet.
    func fetchKeyring() async throws -> SyncCrypto.Keyring? {
        guard Self.isEntitled else { return nil }
        do {
            let record = try await database.record(for: recordID(Name.keyring))
            saveSystemFields(record)
            return Self.keyring(from: record)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    /// Saves the keyring. `replacing` starts over: the whole zone (every synced record) is
    /// deleted first. Without it, a keyring another Mac saved meanwhile wins
    /// (`SettingsSync.SyncError.alreadySetUp`).
    func saveKeyring(_ keyring: SyncCrypto.Keyring, replacing: Bool) async throws {
        guard Self.isEntitled else { throw CKError(.notAuthenticated) }
        if replacing {
            resetEngine()
            do { _ = try await database.deleteRecordZone(withID: zoneID) } catch let error as CKError where error.code == .zoneNotFound {}
        }
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        let record = existingRecord(Name.keyring, type: RecordType.keyring)
        record["data"] = try Self.keyringEncoder.encode(keyring) as CKRecordValue
        let (results, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
        switch results[record.recordID] {
        case .success(let saved): saveSystemFields(saved)
        case .failure(let error as CKError) where error.code == .serverRecordChanged:
            if let server = error.serverRecord { saveSystemFields(server) }
            if let server = error.serverRecord.flatMap(Self.keyring(from:)), server.keyID == keyring.keyID {
                // Same key, rewrapped elsewhere: try once more on top of it.
                return try await saveKeyring(keyring, replacing: false)
            }
            throw SettingsSync.SyncError.alreadySetUp
        case .failure(let error): throw error
        case nil: throw CKError(.internalError)
        }
    }

    /// Removes one record right away, for when sync is being turned off.
    func deleteNow(_ name: String) async {
        guard Self.isEntitled else { return }
        _ = try? await database.modifyRecords(saving: [], deleting: [recordID(name)])
        removeSystemFields(name)
    }

    /// Whether iCloud can be used, with a message for Settings if not.
    func accountProblem() async -> String? {
        guard Self.isEntitled else { return "This copy of CaptureLens isn't signed for iCloud, so it can't sync." }
        do {
            switch try await container.accountStatus() {
            case .available: return nil
            case .noAccount: return "Sign in to iCloud in System Settings to sync."
            case .restricted: return "iCloud is restricted on this Mac."
            case .temporarilyUnavailable: return "iCloud is temporarily unavailable. CaptureLens will try again."
            default: return "iCloud isn't available right now."
            }
        } catch {
            return "Couldn't reach iCloud: \(error.localizedDescription)"
        }
    }

    // MARK: - CKSyncEngineDelegate

    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await handle(event, from: syncEngine)
    }

    nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                               syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
            await CloudSync.shared.record(for: id, engine: syncEngine)
        }
    }

    private func handle(_ event: CKSyncEngine.Event, from source: CKSyncEngine) {
        DebugLog.write("event \(source === engine ? "" : "(stale) ")\(Self.describe(event))")
        guard source === engine else { return }
        switch event {
        case .stateUpdate(let update):
            if let data = try? JSONEncoder().encode(update.stateSerialization) { try? db?.set(data, forKey: Keys.state) }
            updatePending()

        case .accountChange(let change):
            switch change.changeType {
            case .signIn:
                break
            case .signOut, .switchAccounts:
                // Another account's data must not mix with this one's.
                resetEngine()
                SettingsSync.shared.accountChanged()
            @unknown default:
                break
            }

        case .fetchedDatabaseChanges(let changes):
            if changes.deletions.contains(where: { $0.zoneID == zoneID }) {
                // Another Mac started over (or the data was deleted): the key changed.
                resetEngine()
                SettingsSync.shared.keyringChangedElsewhere()
            }

        case .fetchedRecordZoneChanges(let changes):
            // The engine reports every zone in the database; only CaptureLens's own counts.
            applyFetched(changes.modifications.map(\.record).filter { $0.recordID.zoneID == zoneID },
                         deletions: changes.deletions.map(\.recordID).filter { $0.zoneID == zoneID })

        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords where record.recordID.zoneID == zoneID {
                saveSystemFields(record)
                if record.recordType == RecordType.capture, record["image"] != nil,
                   let id = UUID(uuidString: String(record.recordID.recordName.dropFirst(Name.capturePrefix.count))) {
                    LibrarySync.shared.imageSent(id)
                }
            }
            for id in sent.deletedRecordIDs { removeSystemFields(id.recordName) }
            for failure in sent.failedRecordSaves { handleFailedSave(failure.record, failure.error) }
            for (id, error) in sent.failedRecordDeletes where error.code != .unknownItem {
                NSLog("CaptureLens: couldn't delete \(id.recordName): \(error.localizedDescription)")
            }
            for url in tempAssets { try? FileManager.default.removeItem(at: url) }
            tempAssets.removeAll()
            if sent.failedRecordSaves.isEmpty { lastError = nil }
            updatePending()

        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves {
                NSLog("CaptureLens: couldn't create the sync zone: \(failure.error.localizedDescription)")
                note(failure.error)
            }

        case .didFetchChanges:
            lastSynced = Date()
            if !firstFetchDone {
                firstFetchDone = true
                let work = afterFirstFetch
                afterFirstFetch.removeAll()
                work.forEach { $0() }
            }
            LibrarySync.shared.didSync()

        case .didSendChanges:
            lastSynced = Date()
            LibrarySync.shared.didSync()

        case .didFetchRecordZoneChanges(let done):
            if let error = done.error { note(error) }

        default:
            break
        }
    }

    /// Records that changed on the server, from the engine or a poll.
    private func applyFetched(_ records: [CKRecord], deletions: [CKRecord.ID]) {
        var captures: [(String, Data, Data?)] = []
        for record in records {
            saveSystemFields(record)
            let name = record.recordID.recordName
            switch record.recordType {
            case RecordType.keyring:
                if let keyring = Self.keyring(from: record) { SettingsSync.shared.receivedKeyring(keyring) }
            case RecordType.settings:
                if let data = record["data"] as? Data { SettingsSync.shared.receivedSettings(data) }
            case RecordType.capture:
                // Asset files only last while the change is handled: read them now.
                if let meta = record["meta"] as? Data {
                    let image = (record["image"] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
                    captures.append((name, meta, image))
                }
            default:
                NSLog("CaptureLens: ignoring unknown record \(name)")
            }
        }
        LibrarySync.shared.received(captures)
        var deletedCaptures: [String] = []
        for id in deletions {
            let name = id.recordName
            removeSystemFields(name)
            if name.hasPrefix(Name.capturePrefix) {
                deletedCaptures.append(name)
            } else if name == Name.keyring {
                SettingsSync.shared.keyringChangedElsewhere()
            }
        }
        LibrarySync.shared.receivedDeletions(deletedCaptures)
    }

    private func handleFailedSave(_ record: CKRecord, _ error: CKError) {
        let name = record.recordID.recordName
        DebugLog.write("failed save \(name): \(error.code.rawValue) \(error.localizedDescription)")
        switch error.code {
        case .serverRecordChanged:
            // Someone else changed it first: take their version's change tag, then let the
            // owner decide whose content wins.
            guard let server = error.serverRecord else { return queueSave([name]) }
            saveSystemFields(server)
            switch server.recordType {
            case RecordType.settings:
                if let data = server["data"] as? Data { SettingsSync.shared.receivedSettings(data, conflict: true) }
            case RecordType.capture:
                if let meta = server["meta"] as? Data {
                    let image = (server["image"] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
                    LibrarySync.shared.received([(name, meta, image)], conflict: true)
                } else {
                    queueSave([name])
                }
            case RecordType.keyring:
                if let keyring = Self.keyring(from: server) { SettingsSync.shared.receivedKeyring(keyring) }
            default:
                queueSave([name])
            }
        case .zoneNotFound:
            engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            removeSystemFields(name)
            queueSave([name])
        case .unknownItem:
            // Deleted on the server since this Mac last saw it; save it as new.
            removeSystemFields(name)
            queueSave([name])
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            queueSave([name])
            note(error)
        default:
            NSLog("CaptureLens: couldn't save \(name): \(error.localizedDescription)")
            note(error)
        }
    }

    private func note(_ error: Error) {
        guard error is CKError else { return }
        lastError = Self.message(for: error)
    }

    /// An iCloud error in words for Settings.
    static func message(for error: Error) -> String {
        guard let error = error as? CKError else { return error.localizedDescription }
        // Seen only before a new record type is published to the Production environment.
        if error.localizedDescription.contains("production schema") {
            return "iCloud isn't set up for CaptureLens yet: its record types haven't been published to Production in the CloudKit Console. Once they are, try again."
        }
        switch error.code {
        case .quotaExceeded: return "Your iCloud storage is full, so CaptureLens can't sync."
        case .notAuthenticated: return "Sign in to iCloud in System Settings to sync."
        case .networkFailure, .networkUnavailable: return "Can't reach iCloud right now. CaptureLens will try again."
        default: return error.localizedDescription
        }
    }

    // MARK: - Building records to send

    private static func describe(_ event: CKSyncEngine.Event) -> String {
        switch event {
        case .fetchedRecordZoneChanges(let e):
            return "fetched \(e.modifications.map(\.record.recordID.recordName)) deleted \(e.deletions.map(\.recordID.recordName))"
        case .sentRecordZoneChanges(let e):
            return "sent \(e.savedRecords.map(\.recordID.recordName)) deleted \(e.deletedRecordIDs.map(\.recordName)) failed \(e.failedRecordSaves.map(\.record.recordID.recordName))"
        case .stateUpdate: return "stateUpdate"
        default: return String(describing: event).prefix(120).description
        }
    }

    private func record(for id: CKRecord.ID, engine source: CKSyncEngine) -> CKRecord? {
        guard source === engine else { return nil }
        let name = id.recordName
        func drop() -> CKRecord? {
            source.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
            return nil
        }
        if name == Name.keyring {
            guard let keyring = SettingsSync.shared.keyringForUpload, let data = try? Self.keyringEncoder.encode(keyring) else { return drop() }
            let record = existingRecord(name, type: RecordType.keyring)
            record["data"] = data as CKRecordValue
            return record
        }
        guard let key = SettingsSync.shared.key else { return nil }
        if name == Name.settings {
            guard let sealed = SettingsSync.shared.sealedSettings(using: key) else { return drop() }
            let record = existingRecord(name, type: RecordType.settings)
            record["data"] = sealed as CKRecordValue
            return record
        }
        if name.hasPrefix(Name.capturePrefix) {
            guard let uuid = UUID(uuidString: String(name.dropFirst(Name.capturePrefix.count))),
                  let details = LibrarySync.shared.sealedDetails(uuid, using: key) else { return drop() }
            let known = knowsServerRecord(name)
            let record = existingRecord(name, type: RecordType.capture)
            record["meta"] = details as CKRecordValue
            // The picture goes up once; later changes send only the details, and CloudKit
            // keeps the fields a save doesn't touch.
            if let image = LibrarySync.shared.sealedImageIfNeeded(uuid, using: key, serverKnowsRecord: known) {
                let file = FileManager.default.temporaryDirectory.appending(path: "CaptureLens-\(UUID().uuidString).clsync")
                guard (try? image.write(to: file)) != nil else { return nil }
                tempAssets.append(file)
                record["image"] = CKAsset(fileURL: file)
            }
            return record
        }
        return drop()
    }

    /// The record as last seen on the server (so saving it doesn't conflict with itself),
    /// or a new one.
    private func existingRecord(_ name: String, type: String) -> CKRecord {
        if let data = db?.data(forKey: Keys.systemFieldsPrefix + name),
           let coder = try? NSKeyedUnarchiver(forReadingFrom: data) {
            coder.requiresSecureCoding = true
            defer { coder.finishDecoding() }
            if let record = CKRecord(coder: coder), record.recordType == type, record.recordID.zoneID == zoneID { return record }
        }
        return CKRecord(recordType: type, recordID: recordID(name))
    }

    /// Whether this Mac has seen the record on the server.
    func knowsServerRecord(_ name: String) -> Bool {
        guard let data = db?.data(forKey: Keys.systemFieldsPrefix + name),
              let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return false }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)?.recordID.zoneID == zoneID
    }

    private func saveSystemFields(_ record: CKRecord) {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        try? db?.set(coder.encodedData, forKey: Keys.systemFieldsPrefix + record.recordID.recordName)
    }

    private func removeSystemFields(_ name: String) {
        try? db?.set(nil as Data?, forKey: Keys.systemFieldsPrefix + name)
    }

    private static func keyring(from record: CKRecord) -> SyncCrypto.Keyring? {
        guard let data = record["data"] as? Data else { return nil }
        return try? keyringDecoder.decode(SyncCrypto.Keyring.self, from: data)
    }

    nonisolated static let keyringEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    nonisolated static let keyringDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Debug builds only: `CAPTURELENS_DEBUG_LOG=<path>` appends sync events to that file.
enum DebugLog {
    static func write(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_LOG"] else { return }
        let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(message())\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
        #endif
    }
}
