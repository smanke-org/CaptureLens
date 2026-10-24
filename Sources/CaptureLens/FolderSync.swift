import AppKit
import CaptureLensKit
import CoreServices
import CryptoKit
import Observation

/// Syncs the library through a folder that Dropbox, OneDrive, Google Drive or any other
/// sync service keeps in step between Macs (see `FolderLayout` for the files). Every file but
/// the folder's key fingerprint is sealed with the sync key, which still comes from iCloud
/// with the settings (see `SettingsSync`), so the service only ever holds ciphertext.
///
/// Each Mac chooses where the folder is on its own disk; which service the library uses is a
/// shared setting (`Preferences.libraryBackend`). Changes are written as they happen; other
/// Macs' changes are picked up from file-system events, every minute and on wake. Newest
/// change wins, per capture, as with iCloud.
@Observable
@MainActor
final class FolderSync {
    static let shared = FolderSync()

    /// The folder chosen on this Mac; the library lives in "CaptureLens Library" inside it.
    private(set) var folderURL: URL?
    private(set) var lastSynced: Date?
    private(set) var lastError: String?
    /// The folder holds a library sealed with another key (someone started over).
    private(set) var keyMismatch = false
    private(set) var isWorking = false

    @ObservationIgnored private var started = false
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observingWake = false
    @ObservationIgnored private var scanPending = false
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var seen: [String: Double] = [:]
    @ObservationIgnored private let io = FolderIO()
    @ObservationIgnored private var accessing: URL?

    private enum Keys {
        // Per Mac, in UserDefaults.
        static let path = "folderSync.path"
        static let bookmark = "folderSync.bookmark"
        // In the library database.
        static let outbox = "fs.outbox"
        static let seen = "fs.seen"
        static let uploadedFor = "fs.uploadedFor"
    }

    private var db: LibraryDatabase? { LibraryStore.shared.db }
    private var root: URL? { folderURL?.appending(path: FolderLayout.rootName, directoryHint: .isDirectory) }

    /// The library is set to sync through a folder.
    var wanted: Bool { Preferences.shared.librarySync && Preferences.shared.libraryBackend == .folder }
    var isActive: Bool { started }
    /// Folder sync is chosen, but this Mac hasn't picked its folder yet.
    var needsFolder: Bool { wanted && folderURL == nil }

    private init() {
        folderURL = Self.loadFolder()
    }

    // MARK: - Choosing the folder

    /// The sync services' folders on this Mac, for quick picks.
    static func detectedServices() -> [(name: String, url: URL)] {
        let storage = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/CloudStorage")
        let entries = (try? FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { url in
            let name = url.lastPathComponent
            if name.hasPrefix("Dropbox") { return ("Dropbox", url) }
            if name.hasPrefix("OneDrive") { return (name.contains("-") ? "OneDrive (\(name.split(separator: "-", maxSplits: 1)[1]))" : "OneDrive", url) }
            if name.hasPrefix("GoogleDrive") {
                let myDrive = url.appending(path: "My Drive")
                return ("Google Drive", FileManager.default.fileExists(atPath: myDrive.path) ? myDrive : url)
            }
            if name.hasPrefix("Box") { return ("Box", url) }
            return nil
        }
        .sorted { $0.name < $1.name }
    }

    /// Uses `url` (the folder the library goes in) on this Mac from now on.
    func choose(_ url: URL) {
        stop()
        folderURL = url
        let defaults = AppDefaults.store
        defaults.set(url.path, forKey: Keys.path)
        #if APPSTORE
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        defaults.set(try? url.bookmarkData(options: options), forKey: Keys.bookmark)
        // Everything is looked at afresh in the new place.
        seen = [:]
        try? db?.set(nil as Data?, forKey: Keys.seen)
        keyMismatch = false
        lastError = nil
        start()
    }

    func forgetFolder() {
        stop()
        folderURL = nil
        AppDefaults.store.removeObject(forKey: Keys.path)
        AppDefaults.store.removeObject(forKey: Keys.bookmark)
    }

    private static func loadFolder() -> URL? {
        let defaults = AppDefaults.store
        if let data = defaults.data(forKey: Keys.bookmark) {
            var stale = false
            #if APPSTORE
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            if let url = try? URL(resolvingBookmarkData: data, options: options, bookmarkDataIsStale: &stale) { return url }
        }
        return defaults.string(forKey: Keys.path).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    // MARK: - Lifecycle

    /// Whenever sync, the key, the library setting or the folder change.
    func start() {
        guard wanted, SettingsSync.shared.isReady, let key = SettingsSync.shared.key, let root, db != nil else {
            stop()
            return
        }
        guard !started else { return scanSoon() }
        started = true
        if let folderURL, folderURL.startAccessingSecurityScopedResource() { accessing = folderURL }
        let keyID = SyncCrypto.keyID(for: key)
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                try await io.prepare(root: root, keyID: keyID)
                keyMismatch = false
            } catch FolderIO.Problem.otherKey {
                keyMismatch = true
                lastError = "This folder holds a CaptureLens library encrypted with a different sync passphrase."
                stop(keepError: true)
                return
            } catch {
                lastError = Self.describe(error)
                stop(keepError: true)
                // Not there yet (still syncing, or a drive not connected): try again shortly.
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { MainActor.assumeIsolated { FolderSync.shared.start() } }
                return
            }
            lastError = nil
            seen = loadSeen()
            watch(root)
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                MainActor.assumeIsolated { FolderSync.shared.scanSoon() }
            }
            if !observingWake {
                observingWake = true
                NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { FolderSync.shared.scanSoon() }
                }
            }
            NSLog("CaptureLens: folder sync started at \(root.path)")
            // What's already in the folder comes in first, so newer copies there win.
            await scan()
            // Everything this Mac has goes into the folder once per key and folder.
            let tag = "\(keyID)|\(root.path)"
            if db?.string(forKey: Keys.uploadedFor) != tag {
                let ids = LibraryStore.shared.items.map(\.id)
                let missing = await io.missingItems(root: root, ids: ids)
                await write(Set(missing))
                try? db?.set(tag, forKey: Keys.uploadedFor)
                NSLog("CaptureLens: put \(missing.count) captures in the sync folder")
            }
            let outbox = loadOutbox()
            if !outbox.isEmpty {
                await write(outbox)
                saveOutbox([])
            }
        }
    }

    func stop(keepError: Bool = false) {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        timer?.invalidate()
        timer = nil
        accessing?.stopAccessingSecurityScopedResource()
        accessing = nil
        started = false
        if !keepError { lastError = nil }
    }

    /// The folder holds another key's library: clear it and fill it with this Mac's.
    func replaceFolderContents() {
        guard let root, let key = SettingsSync.shared.key else { return }
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                try await io.reset(root: root, keyID: SyncCrypto.keyID(for: key))
                try? db?.set(nil as Data?, forKey: Keys.uploadedFor)
                seen = [:]
                saveSeen()
                keyMismatch = false
                lastError = nil
                start()
            } catch {
                lastError = Self.describe(error)
            }
        }
    }

    func syncNow() {
        if started { scanSoon(delay: 0) } else { start() }
    }

    // MARK: - Changes made on this Mac

    func localDidChange(_ ids: Set<UUID>) {
        if started {
            Task { await write(ids) }
        } else if wanted && SettingsSync.shared.isEnabled {
            var outbox = loadOutbox()
            outbox.formUnion(ids)
            saveOutbox(outbox)
        }
    }

    /// Writes the current state of each capture: its details and (once) its picture, or its
    /// deletion.
    private func write(_ ids: Set<UUID>) async {
        guard let root, let key = SettingsSync.shared.key, let db, !ids.isEmpty else { return }
        for id in ids {
            if let item = LibraryStore.shared.entry(id) {
                guard let details = try? SyncCrypto.seal(SyncedItem(item: item).encoded(), using: key) else { continue }
                let picture = await io.exists(root: root, id, .image) ? nil : db.image(id)
                do {
                    let written = try await io.writeItem(root: root, id: id, sealedDetails: details, picture: picture, key: key)
                    for (name, mtime) in written { seen[name] = mtime }
                } catch {
                    lastError = Self.describe(error)
                }
            } else {
                let deletion = SyncedDeletion(id: id, at: db.tombstone(id) ?? Date())
                guard let sealed = try? SyncCrypto.seal(deletion.encoded(), using: key) else { continue }
                do {
                    let written = try await io.writeDeletion(root: root, id: id, sealed: sealed)
                    for (name, mtime) in written { seen[name] = mtime }
                } catch {
                    lastError = Self.describe(error)
                }
            }
        }
        saveSeen()
        lastSynced = Date()
    }

    // MARK: - Changes from other Macs

    private func scanSoon(delay: TimeInterval = 1.5) {
        guard started, !scanPending else { return }
        scanPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                let sync = FolderSync.shared
                sync.scanPending = false
                Task { await sync.scan() }
            }
        }
    }

    /// Reads whatever changed in the folder since the last look and applies it.
    private func scan() async {
        guard started, !scanning, let root, let key = SettingsSync.shared.key, let db else { return }
        scanning = true
        defer { scanning = false }
        let listing: [FolderIO.Listed]
        do {
            listing = try await io.list(root: root)
        } catch {
            lastError = Self.describe(error)
            return
        }
        let store = LibraryStore.shared
        var updates: [(CaptureItem, image: Data?)] = []
        var deletions: [(UUID, Date)] = []
        var resend: Set<UUID> = []
        var nowSeen: [String: Double] = [:]

        // Every version of each capture whose files changed (the file and any conflicted copies).
        let groups = Dictionary(grouping: listing, by: { $0.entry.id })
        for (id, files) in groups {
            // Unchanged since the last look, unless conflicted copies are still waiting to be tidied.
            let changed = files.filter { seen[$0.key] != $0.mtime }
            guard !changed.isEmpty || files.contains(where: \.entry.isConflict) else { continue }
            let versionFiles = files.filter { $0.entry.kind != .image }
            // Read every version: a conflicted copy may hold the newest one.
            var versions: [(modified: Date, isDeletion: Bool, item: CaptureItem?, file: FolderIO.Listed)] = []
            for file in versionFiles {
                guard let sealed = await io.read(file.url), let plain = try? SyncCrypto.open(sealed, using: key) else { continue }
                if file.entry.kind == .item, let synced = try? SyncedItem.decode(plain) {
                    versions.append((synced.item.modified, false, synced.item, file))
                } else if file.entry.kind == .deletion, let deletion = try? SyncedDeletion.decode(plain) {
                    versions.append((deletion.at, true, nil, file))
                }
            }
            let imageFiles = files.filter { $0.entry.kind == .image }
            guard let best = FolderLayout.newest(versions.map { ($0.modified, $0.isDeletion) }) else {
                // Nothing readable yet (still downloading, or another key): look again next time.
                continue
            }
            let winner = versions[best]
            let local = store.entry(id)
            let tomb = db.tombstone(id)
            let localDate = local?.modified ?? tomb
            var handled = true
            if winner.isDeletion {
                if winner.modified < (tomb ?? .distantPast) || winner.modified.timeIntervalSinceNow < -FolderLayout.deletionLifetime {
                    // An old deletion: let it go from the folder.
                    if winner.modified.timeIntervalSinceNow < -FolderLayout.deletionLifetime { await io.remove([winner.file.url]) }
                } else if let local, local.modified > winner.modified {
                    resend.insert(id) // edited here after it was deleted elsewhere: it comes back
                } else if local != nil {
                    deletions.append((id, winner.modified))
                }
            } else if let item = winner.item {
                if SyncedItem.wins(item.modified, incomingIsDeletion: false, over: localDate,
                                   localIsDeletion: local == nil && tomb != nil) {
                    var picture: Data?
                    if local == nil || db.image(id) == nil {
                        if let image = imageFiles.first(where: { !$0.entry.isConflict }) ?? imageFiles.first,
                           let sealed = await io.read(image.url) {
                            picture = try? SyncCrypto.open(sealed, using: key)
                        }
                        // The picture hasn't arrived yet: try again on the next look.
                        if picture == nil { handled = false }
                    }
                    if handled { updates.append((item, image: picture)) }
                } else if let localDate, localDate > item.modified {
                    resend.insert(id)
                }
            }
            guard handled else { continue }
            // Keep one version: conflicted copies go, and the main file is written again from
            // this Mac's copy, which now holds the winner (or something newer).
            let copies = versionFiles.filter(\.entry.isConflict)
            if !copies.isEmpty {
                await io.remove(copies.map(\.url))
                resend.insert(id)
            }
            // Two Macs may both have sent the picture; it's the same picture, so keep one.
            if imageFiles.contains(where: { !$0.entry.isConflict }) {
                let imageCopies = imageFiles.filter(\.entry.isConflict)
                if !imageCopies.isEmpty { await io.remove(imageCopies.map(\.url)) }
            }
            for file in files { nowSeen[file.key] = file.mtime }
        }

        if !updates.isEmpty { store.applyRemote(updates) }
        if !deletions.isEmpty { store.applyRemoteDeletions(deletions) }
        // Forget files that are gone, and note what was read.
        let present = Set(listing.map(\.key))
        seen = seen.filter { present.contains($0.key) }.merging(nowSeen) { _, new in new }
        saveSeen()
        if !resend.isEmpty { await write(resend) }
        if !updates.isEmpty || !deletions.isEmpty {
            NSLog("CaptureLens: folder sync brought \(updates.count) change(s), \(deletions.count) deletion(s)")
        }
        lastSynced = Date()
        if !keyMismatch { lastError = nil }
    }

    // MARK: - Watching

    private func watch(_ url: URL) {
        if stream != nil { return }
        var context = FSEventStreamContext()
        let callback: FSEventStreamCallback = { _, _, _, _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { FolderSync.shared.scanSoon() } }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    // MARK: - Bookkeeping

    private func loadSeen() -> [String: Double] {
        guard let data = db?.data(forKey: Keys.seen),
              let dict = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return dict
    }

    private func saveSeen() {
        try? db?.set(try? JSONEncoder().encode(seen), forKey: Keys.seen)
    }

    private func loadOutbox() -> Set<UUID> {
        guard let data = db?.data(forKey: Keys.outbox), let ids = try? JSONDecoder().decode([UUID].self, from: data) else { return [] }
        return Set(ids)
    }

    private func saveOutbox(_ ids: Set<UUID>) {
        try? db?.set(ids.isEmpty ? nil : try? JSONEncoder().encode(Array(ids)), forKey: Keys.outbox)
    }

    static func describe(_ error: Error) -> String {
        if let problem = error as? FolderIO.Problem { return problem.message }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code) {
            return "CaptureLens isn't allowed to use that folder. Choose it again, and allow access if macOS asks."
        }
        return error.localizedDescription
    }
}

/// The file work, on its own queue: reading may wait while a sync service downloads a file
/// that was only online, which the file coordinator asks it to do.
final class FolderIO: @unchecked Sendable {
    enum Problem: Error {
        case otherKey, notReady, missing

        var message: String {
            switch self {
            case .otherKey: "This folder holds a CaptureLens library encrypted with a different sync passphrase."
            case .notReady: "The sync folder is still arriving on this Mac. CaptureLens will look again shortly."
            case .missing: "The sync folder isn't there. Is its drive connected, and is the sync app running?"
            }
        }
    }

    struct Listed: Sendable {
        let url: URL
        let entry: FolderLayout.Entry
        let mtime: Double
        /// "Items/<name>", for remembering what was read.
        var key: String { "\(entry.kind.folder)/\(url.lastPathComponent)" }
    }

    private let queue = DispatchQueue(label: "CaptureLens.FolderIO", qos: .utility)

    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// Makes the folders, and checks (or records) which key the folder belongs to.
    func prepare(root: URL, keyID: String) async throws {
        try await run {
            let fm = FileManager.default
            guard fm.fileExists(atPath: root.deletingLastPathComponent().path) else { throw Problem.missing }
            for folder in [FolderLayout.itemsFolder, FolderLayout.imagesFolder, FolderLayout.deletedFolder] {
                try fm.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
            }
            let infoURL = root.appending(path: FolderLayout.infoName)
            if let data = Self.coordinatedRead(infoURL) {
                let info = try JSONDecoder.iso.decode(FolderLayout.Info.self, from: data)
                if info.keyID != keyID { throw Problem.otherKey }
            } else {
                // Files without the info file: it hasn't arrived yet. Don't claim the folder.
                let items = (try? fm.contentsOfDirectory(atPath: root.appending(path: FolderLayout.itemsFolder).path)) ?? []
                if items.contains(where: { FolderLayout.parse($0) != nil }) { throw Problem.notReady }
                try Self.coordinatedWrite(JSONEncoder.iso.encode(FolderLayout.Info(keyID: keyID)), to: infoURL)
            }
        }
    }

    /// Empties the folder's library and stamps it with `keyID`.
    func reset(root: URL, keyID: String) async throws {
        try await run {
            let fm = FileManager.default
            for folder in [FolderLayout.itemsFolder, FolderLayout.imagesFolder, FolderLayout.deletedFolder] {
                let url = root.appending(path: folder)
                for name in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] {
                    Self.coordinatedRemove(url.appending(path: name))
                }
            }
            try Self.coordinatedWrite(JSONEncoder.iso.encode(FolderLayout.Info(keyID: keyID)), to: root.appending(path: FolderLayout.infoName))
        }
    }

    /// Every capture file in the folder, with its modification time.
    func list(root: URL) async throws -> [Listed] {
        try await run {
            let fm = FileManager.default
            guard fm.fileExists(atPath: root.path) else { throw Problem.missing }
            var out: [Listed] = []
            for folder in [FolderLayout.itemsFolder, FolderLayout.imagesFolder, FolderLayout.deletedFolder] {
                let dir = root.appending(path: folder)
                let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for url in urls {
                    guard let entry = FolderLayout.parse(url.lastPathComponent), entry.kind.folder == folder else { continue }
                    let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
                        .timeIntervalSinceReferenceDate ?? 0
                    out.append(Listed(url: url, entry: entry, mtime: mtime))
                }
            }
            return out
        }
    }

    func exists(root: URL, _ id: UUID, _ kind: FolderLayout.Kind) async -> Bool {
        (try? await run {
            FileManager.default.fileExists(atPath: root.appending(path: kind.folder).appending(path: FolderLayout.fileName(id, kind)).path)
        }) ?? false
    }

    /// Which of these captures have no details file in the folder.
    func missingItems(root: URL, ids: [UUID]) async -> [UUID] {
        (try? await run {
            let dir = root.appending(path: FolderLayout.itemsFolder)
            let names = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            return ids.filter { !names.contains(FolderLayout.fileName($0, .item)) }
        }) ?? ids
    }

    func read(_ url: URL) async -> Data? {
        (try? await run { Self.coordinatedRead(url) }) ?? nil
    }

    func remove(_ urls: [URL]) async {
        _ = try? await run { for url in urls { Self.coordinatedRemove(url) } }
    }

    /// Writes a capture's details and, if given, its picture (sealed here, off the main
    /// thread); clears a deletion of it. Returns the written files' names and times.
    func writeItem(root: URL, id: UUID, sealedDetails: Data, picture: Data?, key: SymmetricKey) async throws -> [String: Double] {
        try await run {
            var written: [String: Double] = [:]
            if let picture {
                let url = root.appending(path: FolderLayout.imagesFolder).appending(path: FolderLayout.fileName(id, .image))
                try Self.coordinatedWrite(try SyncCrypto.seal(picture, using: key), to: url)
                written["\(FolderLayout.imagesFolder)/\(url.lastPathComponent)"] = Self.mtime(url)
            }
            let url = root.appending(path: FolderLayout.itemsFolder).appending(path: FolderLayout.fileName(id, .item))
            try Self.coordinatedWrite(sealedDetails, to: url)
            written["\(FolderLayout.itemsFolder)/\(url.lastPathComponent)"] = Self.mtime(url)
            Self.coordinatedRemove(root.appending(path: FolderLayout.deletedFolder).appending(path: FolderLayout.fileName(id, .deletion)))
            return written
        }
    }

    /// Records a deletion and removes the capture's files.
    func writeDeletion(root: URL, id: UUID, sealed: Data) async throws -> [String: Double] {
        try await run {
            let url = root.appending(path: FolderLayout.deletedFolder).appending(path: FolderLayout.fileName(id, .deletion))
            try Self.coordinatedWrite(sealed, to: url)
            for kind in [FolderLayout.Kind.item, .image] {
                Self.coordinatedRemove(root.appending(path: kind.folder).appending(path: FolderLayout.fileName(id, kind)))
            }
            return ["\(FolderLayout.deletedFolder)/\(url.lastPathComponent)": Self.mtime(url)]
        }
    }

    // MARK: Coordinated file access

    private static func mtime(_ url: URL) -> Double {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSinceReferenceDate ?? 0
    }

    /// Reading through the file coordinator makes a sync service download a file kept online.
    static func coordinatedRead(_ url: URL) -> Data? {
        var result: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { target in
            result = try? Data(contentsOf: target)
        }
        return result
    }

    static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var thrown: Error?
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { target in
            do { try data.write(to: target, options: .atomic) } catch { thrown = error }
        }
        if let error { throw error }
        if let thrown { throw thrown }
    }

    static func coordinatedRemove(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &error) { target in
            try? FileManager.default.removeItem(at: target)
        }
    }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
