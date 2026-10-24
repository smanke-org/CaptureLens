import AppKit
import CaptureLensKit
import CryptoKit
import Foundation
import Observation

/// Syncs the library between Macs through CloudKit, end-to-end encrypted with the same key
/// as the settings (see `SettingsSync`, `CloudSync`).
///
/// Each capture is one record, `Capture_<item id>`: its details (name, tags, notes…) sealed
/// in a small field, and its picture sealed in an asset that is sent once. Renaming or
/// tagging a capture only sends the details. Deleting a capture deletes its record, and
/// CloudKit tells every Mac. Newest change wins, per capture.
///
/// Runs while settings sync is unlocked and "Sync the library" is on. Changes made while it
/// isn't running wait in an outbox.
@Observable
@MainActor
final class LibrarySync {
    static let shared = LibrarySync()

    private(set) var lastSynced: Date?
    var lastError: String? { CloudSync.shared.lastError }
    /// Captures waiting to go up, for Settings.
    var pendingUploads: Int { CloudSync.shared.pendingCaptures + (started ? 0 : loadOutbox().count) }

    @ObservationIgnored private var started = false

    private static let tombstoneLifetime: TimeInterval = 90 * 86_400

    private enum Keys {
        static let outbox = "librarySync.outbox"
        /// The key ID this Mac last uploaded its whole library to CloudKit under.
        static let uploadedFor = "ck.libraryUploadedForKey"
        /// Set once a capture's picture is in iCloud under the current key.
        static let imageSentPrefix = "ck.img."
        /// Set once a recording's movie is in iCloud ("1"), or couldn't go ("0").
        static let videoSentPrefix = "ck.vid."
        /// Movies another Mac put in iCloud that this Mac didn't take (video sync was off).
        static let videoWaitingPrefix = "ck.vidAvail."
    }

    /// Movies sealed for sending, waiting for the engine to ask for their records.
    @ObservationIgnored private var preparedVideos: [UUID: URL] = [:]
    @ObservationIgnored private var preparing: Set<UUID> = []

    var isActive: Bool {
        SettingsSync.shared.isReady && Preferences.shared.librarySync && Preferences.shared.libraryBackend == .iCloud
    }

    private var db: LibraryDatabase? { LibraryStore.shared.db }

    // MARK: - Lifecycle

    /// When the sync engine starts, and whenever sync, the key or the library setting change.
    func start() {
        guard isActive, CloudSync.shared.isRunning, let key = SettingsSync.shared.key, let db else {
            if started, Preferences.shared.libraryBackend != .iCloud {
                // Moved to another service: if it comes back to iCloud, everything goes up again.
                try? db?.set(nil as String?, forKey: Keys.uploadedFor)
            }
            started = false
            return
        }
        started = true
        let outbox = loadOutbox()
        if !outbox.isEmpty {
            send(outbox)
            saveOutbox([])
        }
        // Everything this Mac has goes up once per key (first sync, after starting over),
        // once what's already in iCloud has come down.
        let keyID = SyncCrypto.keyID(for: key)
        if db.string(forKey: Keys.uploadedFor) != keyID {
            try? db.removeValues(withPrefix: Keys.imageSentPrefix)
            try? db.removeValues(withPrefix: Keys.videoSentPrefix)
            CloudSync.shared.afterFirstFetch { [weak self] in
                guard let self, self.started, let db = self.db else { return }
                CloudSync.shared.queueSave(LibraryStore.shared.items.map { CloudSync.Name.capture($0.id) })
                try? db.set(keyID, forKey: Keys.uploadedFor)
                NSLog("CaptureLens: uploading \(LibraryStore.shared.items.count) captures")
            }
        }
        let cutoff = Date().addingTimeInterval(-Self.tombstoneLifetime)
        for (id, at) in db.tombstones() where at < cutoff { try? db.removeTombstone(id) }
        CloudSync.shared.afterFirstFetch { [weak self] in self?.videoSyncChanged() }
    }

    /// Items added, changed or deleted on this Mac.
    func localDidChange(_ ids: Set<UUID>) {
        if started {
            send(ids)
        } else if SettingsSync.shared.isEnabled && Preferences.shared.librarySync && Preferences.shared.libraryBackend == .iCloud {
            var outbox = loadOutbox()
            outbox.formUnion(ids)
            saveOutbox(outbox)
        }
    }

    private func send(_ ids: Set<UUID>) {
        let existing = Set(LibraryStore.shared.items.map(\.id))
        CloudSync.shared.queueSave(ids.filter { existing.contains($0) }.map(CloudSync.Name.capture))
        let gone = ids.filter { !existing.contains($0) }
        for id in gone {
            try? db?.set(nil as Data?, forKey: Keys.imageSentPrefix + id.uuidString)
            try? db?.set(nil as Data?, forKey: Keys.videoSentPrefix + id.uuidString)
            try? db?.set(nil as Data?, forKey: Keys.videoWaitingPrefix + id.uuidString)
        }
        CloudSync.shared.queueDelete(gone.map(CloudSync.Name.capture) + gone.map(CloudSync.Name.video))
        sendVideos(ids.filter { existing.contains($0) })
    }

    // MARK: - Movies

    /// Video sync was turned on or off (or sync started): send this Mac's movies, and fetch
    /// the ones other Macs sent while it was off.
    func videoSyncChanged() {
        guard started, Preferences.shared.syncVideos, let db else { return }
        sendVideos(Set(LibraryStore.shared.items.filter { $0.kind == .video }.map(\.id)))
        let waiting = db.keys(withPrefix: Keys.videoWaitingPrefix).compactMap { UUID(uuidString: String($0.dropFirst(Keys.videoWaitingPrefix.count))) }
        guard !waiting.isEmpty else { return }
        Task {
            let found = await CloudSync.shared.fetchRecords(waiting.map(CloudSync.Name.video))
            for (name, asset) in found {
                guard let id = CloudSync.Name.videoID(name) else { continue }
                await receive(id, assetFile: asset)
            }
        }
    }

    /// Seals each movie not yet in iCloud and queues it.
    private func sendVideos(_ ids: Set<UUID>) {
        guard Preferences.shared.syncVideos, let key = SettingsSync.shared.key, let db else { return }
        let libraryKey = db.sealKey
        for id in ids where !preparing.contains(id) && preparedVideos[id] == nil {
            guard LibraryStore.shared.entry(id)?.kind == .video, db.data(forKey: Keys.videoSentPrefix + id.uuidString) == nil,
                  let stored = VideoStore.shared.storedFile(id) else { continue }
            preparing.insert(id)
            Task {
                let file = try? await Task.detached(priority: .utility) {
                    try VideoStore.sealedForSync(stored, libraryKey: libraryKey, syncKey: key)
                }.value
                preparing.remove(id)
                guard let file else { return }
                preparedVideos[id] = file
                CloudSync.shared.queueSave([CloudSync.Name.video(id)])
            }
        }
    }

    func preparedVideo(_ id: UUID) -> URL? { preparedVideos[id] }

    func videoSent(_ id: UUID) {
        try? db?.set(Data([1]), forKey: Keys.videoSentPrefix + id.uuidString)
        if let file = preparedVideos.removeValue(forKey: id) { try? FileManager.default.removeItem(at: file) }
    }

    func videoFailed(_ id: UUID, _ message: String) {
        NSLog("CaptureLens: a video couldn't go to iCloud: \(message)")
        videoProblem = "A video couldn't go to iCloud: \(message)"
        try? db?.set(Data([0]), forKey: Keys.videoSentPrefix + id.uuidString)
        if let file = preparedVideos.removeValue(forKey: id) { try? FileManager.default.removeItem(at: file) }
    }

    /// The last movie that couldn't be sent, for Settings.
    private(set) var videoProblem: String?

    /// A movie from iCloud. The asset file only lasts while the change is handled, so it's
    /// copied right away; video sync off just notes that it's there.
    func receivedVideo(_ id: UUID, assetFile: URL) {
        guard let db else { return }
        try? db.set(Data([1]), forKey: Keys.videoSentPrefix + id.uuidString)
        guard Preferences.shared.syncVideos, !VideoStore.shared.has(id) else {
            if !VideoStore.shared.has(id) { try? db.set(Data([1]), forKey: Keys.videoWaitingPrefix + id.uuidString) }
            return
        }
        let copy = FileManager.default.temporaryDirectory.appending(path: "CaptureLens-\(UUID().uuidString).clvideo")
        guard (try? FileManager.default.copyItem(at: assetFile, to: copy)) != nil else { return }
        Task { await receive(id, assetFile: copy) }
    }

    private func receive(_ id: UUID, assetFile: URL) async {
        guard let key = SettingsSync.shared.key else { return }
        await VideoStore.shared.receive(id, sealedWith: key, from: assetFile)
        try? FileManager.default.removeItem(at: assetFile)
        if VideoStore.shared.has(id) { try? db?.set(nil as Data?, forKey: Keys.videoWaitingPrefix + id.uuidString) }
    }

    func syncNow() {
        guard started else { return SettingsSync.shared.syncNow() }
        CloudSync.shared.fetchNow()
        CloudSync.shared.sendNow()
    }

    /// Looks for other Macs' changes (opening the library, for instance).
    func scan() {
        guard started else { return }
        CloudSync.shared.fetchNow()
    }

    func didSync() {
        if started { lastSynced = Date() }
    }

    private func loadOutbox() -> Set<UUID> {
        guard let data = db?.data(forKey: Keys.outbox), let ids = try? JSONDecoder().decode([UUID].self, from: data) else { return [] }
        return Set(ids)
    }

    private func saveOutbox(_ ids: Set<UUID>) {
        try? db?.set(ids.isEmpty ? nil : try? JSONEncoder().encode(Array(ids)), forKey: Keys.outbox)
    }

    /// Captures this Mac has seen in iCloud, for removing them once the library has moved to
    /// a folder.
    var iCloudCaptureCount: Int { db?.keys(withPrefix: "ck.sys." + CloudSync.Name.capturePrefix).count ?? 0 }

    /// Deletes the library's copies in iCloud (not the settings). Only once every Mac syncs
    /// the library through the folder: a Mac still syncing it through iCloud would delete
    /// those captures too.
    func removeFromICloud() {
        guard !started, Preferences.shared.libraryBackend == .folder, let db else { return }
        let names = (db.keys(withPrefix: "ck.sys." + CloudSync.Name.capturePrefix) + db.keys(withPrefix: "ck.sys." + CloudSync.Name.videoPrefix))
            .map { String($0.dropFirst("ck.sys.".count)) }
        CloudSync.shared.queueDelete(names)
        try? db.removeValues(withPrefix: Keys.imageSentPrefix)
        try? db.removeValues(withPrefix: Keys.videoSentPrefix)
        try? db.set(nil as String?, forKey: Keys.uploadedFor)
        CloudSync.shared.sendNow()
        NSLog("CaptureLens: removing \(names.count) captures from iCloud")
    }

    // MARK: - From CloudSync

    /// A capture's details, sealed, for its record; nil if it's gone.
    func sealedDetails(_ id: UUID, using key: SymmetricKey) -> Data? {
        guard let item = LibraryStore.shared.entry(id) else { return nil }
        return try? SyncCrypto.seal(SyncedItem(item: item).encoded(), using: key)
    }

    /// The capture's picture, sealed, if iCloud doesn't have it yet under this key.
    func sealedImageIfNeeded(_ id: UUID, using key: SymmetricKey, serverKnowsRecord: Bool) -> Data? {
        if serverKnowsRecord, db?.data(forKey: Keys.imageSentPrefix + id.uuidString) != nil { return nil }
        guard let png = db?.image(id) else { return nil }
        return try? SyncCrypto.seal(png, using: key)
    }

    /// The record with the picture was saved.
    func imageSent(_ id: UUID) {
        try? db?.set(Data([1]), forKey: Keys.imageSentPrefix + id.uuidString)
    }

    /// Records that arrived from iCloud: (record name, sealed details, sealed picture if the
    /// record carried one). `conflict` means this Mac's save lost a race; the newer of the
    /// two wins and the loser is sent again if it was this Mac's.
    func received(_ records: [(String, Data, Data?)], conflict: Bool = false) {
        guard started || conflict, let key = SettingsSync.shared.key, let db else { return }
        var updates: [(CaptureItem, image: Data?)] = []
        var resend: [String] = []
        for (name, sealed, sealedImage) in records {
            guard let plain = try? SyncCrypto.open(sealed, using: key),
                  let synced = try? SyncedItem.decode(plain) else { continue }
            let incoming = synced.item
            let local = LibraryStore.shared.entry(incoming.id)
            let localTomb = db.tombstone(incoming.id)
            let localDate = local?.modified ?? localTomb
            // A capture new to this Mac needs its picture; one it has keeps its own.
            let image = local == nil || db.image(incoming.id) == nil
                ? sealedImage.flatMap { try? SyncCrypto.open($0, using: key) } : nil
            if local == nil && image == nil && localTomb == nil {
                // Details without a picture (it's still uploading): wait for the next copy.
                continue
            }
            if SyncedItem.wins(incoming.modified, incomingIsDeletion: false, over: localDate,
                               localIsDeletion: local == nil && localTomb != nil) {
                updates.append((incoming, image: image))
                if sealedImage != nil { imageSent(incoming.id) }
            } else if let localDate, localDate > incoming.modified {
                // This Mac's copy is newer (or was deleted later): it goes up again.
                if local != nil { resend.append(name) } else { CloudSync.shared.queueDelete([name]) }
            }
        }
        LibraryStore.shared.applyRemote(updates)
        CloudSync.shared.queueSave(resend)
        if !updates.isEmpty { NSLog("CaptureLens: library sync brought \(updates.count) change(s)") }
    }

    /// Captures deleted on another Mac.
    func receivedDeletions(_ names: [String]) {
        guard started else { return }
        let ids = names.compactMap { UUID(uuidString: String($0.dropFirst(CloudSync.Name.capturePrefix.count))) }
        let present = Set(LibraryStore.shared.items.map(\.id))
        let now = Date()
        for id in ids { try? db?.set(nil as Data?, forKey: Keys.imageSentPrefix + id.uuidString) }
        LibraryStore.shared.applyRemoteDeletions(ids.filter(present.contains).map { ($0, now) })
    }
}
