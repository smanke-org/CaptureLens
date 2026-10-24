import AppKit
import CaptureLensKit
import CryptoKit
import Observation
import UniformTypeIdentifiers

/// Every capture, saved in Application Support/CaptureLens/Library.sqlite: each item, its
/// full-size picture and a thumbnail (see `LibraryDatabase`). With encryption on (the
/// default), all of it is sealed with a key kept in this Mac's keychain. With sync on,
/// items also travel between Macs, end-to-end encrypted (see `LibrarySync`).
///
/// `items` mirrors the database newest first for the views; every change writes just the
/// rows it touches.
@Observable
@MainActor
final class LibraryStore {
    static let shared = LibraryStore()

    private(set) var items: [CaptureItem] = []
    /// Items being read and named right after capture.
    private(set) var analyzing: Set<UUID> = []
    /// Items in the database this Mac can't open (encrypted with a key that's gone).
    private(set) var unreadable = 0
    private(set) var isEncrypted = false
    /// Turning encryption on or off rewrites the library; this is true meanwhile.
    private(set) var isResealing = false
    private(set) var lastError: String?

    @ObservationIgnored private var thumbnailCache: [UUID: NSImage] = [:]
    @ObservationIgnored private(set) var db: LibraryDatabase?

    let folder: URL = {
        if let override = ProcessInfo.processInfo.environment["CAPTURELENS_LIBRARY_FOLDER"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CaptureLens", directoryHint: .isDirectory)
    }()

    private var databaseURL: URL { folder.appending(path: "Library.sqlite") }

    /// Per Mac, never synced: each Mac has its own key.
    private static let encryptKey = "library.encrypt"

    private init() {
        let wantsEncryption = AppDefaults.store.object(forKey: Self.encryptKey) as? Bool ?? true
        var key = LibraryKeychain.loadKey()
        if wantsEncryption && key == nil {
            key = SymmetricKey(size: .bits256)
            LibraryKeychain.saveKey(key!)
        }
        do {
            let db = try LibraryDatabase(url: databaseURL, sealKey: wantsEncryption ? key : nil)
            self.db = db
            isEncrypted = wantsEncryption
            items = db.allItems()
            unreadable = db.sealKey == nil ? db.unreadableCount : max(0, db.count - items.count)
        } catch {
            lastError = error.localizedDescription
            NSLog("CaptureLens: \(error.localizedDescription)")
        }
    }

    // MARK: - Adding

    /// Saves a new capture, then reads its text and names it in the background.
    @discardableResult
    func add(image: CGImage, kind: CaptureItem.Kind, scale: Double, source: CaptureItem.Source,
             cursor: CursorLayer?, created: Date = Date()) -> CaptureItem? {
        guard let db, let png = image.pngData else { return nil }
        let item = CaptureItem(created: created, kind: kind, name: CaptureNaming.fallback(source: source, date: created),
                               source: source, pixelWidth: image.width, pixelHeight: image.height, scale: scale,
                               cursor: cursor, origin: DeviceIdentity.deviceID)
        let thumb = image.thumbnail().pngData
        do {
            try db.upsert(item, image: png, thumbnail: thumb)
        } catch {
            lastError = error.localizedDescription
            NSLog("CaptureLens: couldn't save the capture: \(error.localizedDescription)")
            return nil
        }
        items.insert(item, at: 0)
        LibrarySync.shared.localDidChange([item.id])
        analyze(item.id, image: image, rename: true)
        return item
    }

    /// Pictures dropped on the Dock icon or chosen with Import.
    func importFiles(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls {
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                  let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { continue }
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let scale = image.size.width > 0 ? Double(cg.width) / Double(image.size.width) : 1
            guard var item = add(image: cg, kind: .imported, scale: max(1, scale), source: .init(), cursor: nil, created: date) else { continue }
            // The file's own name is a better start than "Capture <date>".
            item.name = CaptureNaming.clean(url.deletingPathExtension().lastPathComponent) ?? item.name
            save(item, touch: false)
            added += 1
        }
        return added
    }

    /// Reads the text (for search) and, if `rename` and the name is still automatic, asks
    /// the on-device model for a name.
    func analyze(_ id: UUID, image: CGImage? = nil, rename: Bool) {
        guard !analyzing.contains(id) else { return }
        let prefs = Preferences.shared
        guard let picture = image ?? fullImage(id).flatMap({ $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }) else { return }
        analyzing.insert(id)
        Task {
            defer { analyzing.remove(id) }
            var text = entry(id)?.recognizedText ?? ""
            if prefs.recognizeText || rename, text.isEmpty {
                text = (try? await Recognizer.text(in: picture)) ?? ""
            }
            var name: String?
            if rename && (prefs.autoName || image == nil) {
                let labels = await Recognizer.labels(in: picture)
                if let current = entry(id) {
                    name = await AutoNamer.suggest(text: text, labels: labels, source: current.source)
                }
            }
            // Read again: the user may have renamed or deleted it meanwhile.
            guard var item = entry(id) else { return }
            var changed = false
            if prefs.recognizeText, item.recognizedText != text { item.recognizedText = text; changed = true }
            if let name, item.nameIsAutomatic, item.name != name { item.name = name; changed = true }
            if changed { save(item) }
        }
    }

    // MARK: - Changing

    func update(_ item: CaptureItem) { save(item) }

    func rename(_ id: UUID, to name: String) {
        guard var item = entry(id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        item.name = trimmed
        item.nameIsAutomatic = false
        save(item)
    }

    /// Asks the on-device model for a fresh name, replacing the current one.
    func suggestName(_ id: UUID) {
        guard var item = entry(id) else { return }
        item.nameIsAutomatic = true
        save(item, touch: false)
        analyze(id, rename: true)
    }

    func setTags(_ ids: Set<UUID>, add: [String] = [], remove: [String] = []) {
        let removeKeys = Set(remove.map(LibraryQuery.fold))
        for id in ids {
            guard var item = entry(id) else { continue }
            let tags = LibraryQuery.normalizedTags(item.tags.filter { !removeKeys.contains(LibraryQuery.fold($0)) } + add)
            guard tags != item.tags else { continue }
            item.tags = tags
            save(item)
        }
    }

    /// Renames a tag on every item that has it (or merges it into an existing one).
    func renameTag(_ old: String, to new: String) {
        let ids = Set(items.filter { $0.tags.contains { LibraryQuery.fold($0) == LibraryQuery.fold(old) } }.map(\.id))
        for id in ids {
            guard var item = entry(id) else { continue }
            item.tags = LibraryQuery.normalizedTags(item.tags.map { LibraryQuery.fold($0) == LibraryQuery.fold(old) ? new : $0 })
            save(item)
        }
    }

    func toggleFavorite(_ ids: Set<UUID>) {
        let makeFavorite = ids.contains { entry($0)?.favorite == false }
        for id in ids {
            guard var item = entry(id), item.favorite != makeFavorite else { continue }
            item.favorite = makeFavorite
            save(item)
        }
    }

    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty, let db else { return }
        do {
            try db.delete(Array(ids), tombstone: Date())
        } catch {
            NSLog("CaptureLens: couldn't delete from the library: \(error.localizedDescription)")
            return
        }
        for id in ids { thumbnailCache[id] = nil }
        items.removeAll { ids.contains($0.id) }
        LibrarySync.shared.localDidChange(ids)
    }

    private func save(_ item: CaptureItem, touch: Bool = true) {
        guard let db, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var item = item
        if touch { item.modified = Self.now }
        do { try db.upsert(item) } catch {
            NSLog("CaptureLens: couldn't save to the library: \(error.localizedDescription)")
            return
        }
        items[index] = item
        LibrarySync.shared.localDidChange([item.id])
    }

    /// Whole milliseconds, so a date read back from iCloud compares equal to the one written.
    private static var now: Date {
        Date(timeIntervalSinceReferenceDate: (Date().timeIntervalSinceReferenceDate * 1000).rounded(.down) / 1000)
    }

    // MARK: - Changes from other Macs

    /// A newer copy of an item, or a new one (with its picture), arrived from another Mac.
    func applyRemote(_ incoming: [(CaptureItem, image: Data?)]) {
        guard let db, !incoming.isEmpty else { return }
        let rows: [(CaptureItem, image: Data?, thumbnail: Data?)] = incoming.map { item, image in
            let thumb = image.flatMap { NSImage(data: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }?.thumbnail().pngData
            return (item, image: image, thumbnail: thumb)
        }
        do { try db.upsert(rows) } catch {
            NSLog("CaptureLens: couldn't save synced captures: \(error.localizedDescription)")
            return
        }
        var byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (item, image) in incoming {
            byID[item.id] = item
            if image != nil { thumbnailCache[item.id] = nil }
        }
        items = byID.values.sorted { $0.created > $1.created }
    }

    /// Items deleted on another Mac.
    func applyRemoteDeletions(_ deletions: [(UUID, Date)]) {
        guard let db, !deletions.isEmpty else { return }
        let ids = Set(deletions.map(\.0))
        do {
            try db.transaction {
                for (id, at) in deletions { try db.delete([id], tombstone: at) }
            }
        } catch {
            NSLog("CaptureLens: couldn't apply synced deletions: \(error.localizedDescription)")
            return
        }
        for id in ids { thumbnailCache[id] = nil }
        items.removeAll { ids.contains($0.id) }
    }

    // MARK: - Reading

    func entry(_ id: UUID) -> CaptureItem? { items.first { $0.id == id } }

    func thumbnail(_ item: CaptureItem) -> NSImage? {
        if let cached = thumbnailCache[item.id] { return cached }
        guard let data = db?.thumbnail(item.id) ?? db?.image(item.id), let image = NSImage(data: data) else { return nil }
        thumbnailCache[item.id] = image
        return image
    }

    /// The full-size picture, sized in points so it shows at its on-screen size.
    func fullImage(_ id: UUID) -> NSImage? {
        guard let data = db?.image(id), let image = NSImage(data: data) else { return nil }
        if let item = entry(id), item.scale > 0, let rep = image.representations.first {
            image.size = NSSize(width: Double(rep.pixelsWide) / item.scale, height: Double(rep.pixelsHigh) / item.scale)
        }
        return image
    }

    func pngData(_ id: UUID) -> Data? { db?.image(id) }

    // MARK: - Encryption at rest

    /// Seals or unseals the whole library on this Mac.
    func setEncrypted(_ on: Bool) {
        guard let db, on != isEncrypted, !isResealing else { return }
        isResealing = true
        let previous = db.sealKey
        var key = LibraryKeychain.loadKey()
        if on && key == nil {
            key = SymmetricKey(size: .bits256)
            LibraryKeychain.saveKey(key!)
        }
        db.sealKey = on ? key : nil
        Task.detached(priority: .userInitiated) {
            let failures = (try? db.reseal(previous: previous ?? key)) ?? -1
            await MainActor.run {
                let store = LibraryStore.shared
                store.isResealing = false
                store.isEncrypted = on
                AppDefaults.store.set(on, forKey: Self.encryptKey)
                if failures != 0 { store.lastError = "Some captures couldn't be rewritten." }
                NSLog("CaptureLens: library encryption \(on ? "on" : "off")")
            }
        }
    }

    /// How much room the library takes on disk.
    var diskSize: Int64 {
        let names = ["Library.sqlite", "Library.sqlite-wal", "Library.sqlite-shm"]
        return names.reduce(0) { total, name in
            let size = (try? folder.appending(path: name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }
}

/// The key that seals the library on this Mac, kept in the login keychain. It never leaves
/// the Mac; other Macs get captures through sync, sealed with the sync key instead.
enum LibraryKeychain {
    static let service = "com.smanke.CaptureLens.library"
    /// A test copy with its own defaults keeps its key apart from the real one.
    static let account: String = AppDefaults.suiteName.map { "library-key-test-\($0)" } ?? "library-key"

    static func saveKey(_ key: SymmetricKey) {
        deleteKey()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "CaptureLens library key",
            kSecValueData as String: key.withUnsafeBytes { Data($0) },
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess { NSLog("CaptureLens: couldn't save the library key (\(status))") }
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
