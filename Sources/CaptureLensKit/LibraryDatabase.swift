import CryptoKit
import Foundation
import SQLite3

/// The capture library on disk: one SQLite database holding every item, its full-size
/// picture and a small thumbnail, so saving a capture writes a few rows instead of
/// rewriting the library.
///
/// With a library key set (`sealKey`), every item and picture is sealed with AES-256-GCM
/// before it is written, so the file on its own reveals nothing. Each row records whether
/// it is sealed, so turning encryption on or off rewrites the rows once (`reseal`). Search
/// runs on the items in memory, so nothing readable is kept in an index.
///
/// Also keeps sync bookkeeping: tombstones for deleted items and small values in `kv`.
public final class LibraryDatabase: @unchecked Sendable {
    public struct DatabaseError: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let url: URL

    /// Seals what is written, and opens what was sealed. Nil writes plainly; sealed rows
    /// then can't be read (`unreadableCount`).
    public var sealKey: SymmetricKey? {
        get { lock.withLock { _sealKey } }
        set { lock.withLock { _sealKey = newValue } }
    }
    private var _sealKey: SymmetricKey?

    public init(url: URL, sealKey: SymmetricKey? = nil) throws {
        self.url = url
        _sealKey = sealKey
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw DatabaseError("Couldn't open the library: \(message)")
        }
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")
        // Deleted pictures are scrubbed rather than left in free pages.
        try exec("PRAGMA secure_delete = ON")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    // MARK: Schema

    private func migrate() throws {
        let version = try scalarInt("PRAGMA user_version") ?? 0
        if version < 1 {
            try transaction {
                try exec("""
                    CREATE TABLE IF NOT EXISTS items (
                        id TEXT PRIMARY KEY,
                        created REAL NOT NULL,
                        modified REAL NOT NULL,
                        sealed INTEGER NOT NULL,
                        meta BLOB NOT NULL
                    )
                    """)
                try exec("CREATE INDEX IF NOT EXISTS items_created ON items(created DESC)")
                try exec("""
                    CREATE TABLE IF NOT EXISTS images (
                        id TEXT PRIMARY KEY,
                        sealed INTEGER NOT NULL,
                        image BLOB NOT NULL,
                        thumbnail BLOB
                    )
                    """)
                try exec("CREATE TABLE IF NOT EXISTS tombstones (id TEXT PRIMARY KEY, at REAL NOT NULL)")
                try exec("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value BLOB)")
                try exec("PRAGMA user_version = 1")
            }
        }
    }

    // MARK: Sealing

    private func encode(_ data: Data) throws -> (Data, Int) {
        guard let key = sealKey else { return (data, 0) }
        return (try SyncCrypto.seal(data, using: key), 1)
    }

    private func decode(_ data: Data, sealed: Bool) -> Data? {
        guard sealed else { return data }
        guard let key = sealKey else { return nil }
        return try? SyncCrypto.open(data, using: key)
    }

    // MARK: Items

    /// Every item that can be read, newest first.
    public func allItems() -> [CaptureItem] {
        (try? rows("SELECT meta, sealed FROM items ORDER BY created DESC") { self.item($0) })?.compactMap { $0 } ?? []
    }

    public func item(_ id: UUID) -> CaptureItem? {
        (try? rows("SELECT meta, sealed FROM items WHERE id = ?", [id.uuidString]) { self.item($0) })?.first ?? nil
    }

    private func item(_ stmt: OpaquePointer?) -> CaptureItem? {
        guard let data = decode(Self.blob(stmt, 0), sealed: sqlite3_column_int(stmt, 1) != 0) else { return nil }
        return try? Self.decoder.decode(CaptureItem.self, from: data)
    }

    public var count: Int { (try? scalarInt("SELECT count(*) FROM items")) ?? 0 }

    /// Items sealed with a key this Mac doesn't have.
    public var unreadableCount: Int {
        guard sealKey == nil else { return 0 }
        return (try? scalarInt("SELECT count(*) FROM items WHERE sealed = 1")) ?? 0
    }

    public var sealedCount: Int { (try? scalarInt("SELECT count(*) FROM items WHERE sealed = 1")) ?? 0 }

    /// Adds or replaces items, with their pictures where given (full size and thumbnail).
    public func upsert(_ items: [(CaptureItem, image: Data?, thumbnail: Data?)]) throws {
        try transaction {
            for (item, image, thumbnail) in items {
                let id = item.id.uuidString
                let (meta, sealed) = try encode(try Self.encoder.encode(item))
                try run("""
                    INSERT INTO items (id, created, modified, sealed, meta) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET created = excluded.created, modified = excluded.modified,
                        sealed = excluded.sealed, meta = excluded.meta
                    """, [id, item.created.timeIntervalSinceReferenceDate, item.modified.timeIntervalSinceReferenceDate, sealed, meta])
                if let image {
                    let (full, sealedImage) = try encode(image)
                    let thumb = try thumbnail.map { try encode($0).0 }
                    try run("INSERT OR REPLACE INTO images (id, sealed, image, thumbnail) VALUES (?, ?, ?, ?)",
                            [id, sealedImage, full, thumb])
                }
                try run("DELETE FROM tombstones WHERE id = ?", [id])
            }
        }
    }

    public func upsert(_ item: CaptureItem, image: Data? = nil, thumbnail: Data? = nil) throws {
        try upsert([(item, image: image, thumbnail: thumbnail)])
    }

    /// Removes items and their pictures. `tombstone` records the deletion so it can sync.
    public func delete(_ ids: [UUID], tombstone: Date?) throws {
        try transaction {
            for id in ids.map(\.uuidString) {
                try run("DELETE FROM items WHERE id = ?", [id])
                try run("DELETE FROM images WHERE id = ?", [id])
                if let tombstone {
                    try run("INSERT OR REPLACE INTO tombstones (id, at) VALUES (?, ?)", [id, tombstone.timeIntervalSinceReferenceDate])
                }
            }
        }
    }

    /// The full-size picture.
    public func image(_ id: UUID) -> Data? {
        (try? rows("SELECT image, sealed FROM images WHERE id = ?", [id.uuidString]) {
            self.decode(Self.blob($0, 0), sealed: sqlite3_column_int($0, 1) != 0)
        })?.first ?? nil
    }

    public func thumbnail(_ id: UUID) -> Data? {
        (try? rows("SELECT thumbnail, sealed FROM images WHERE id = ? AND thumbnail IS NOT NULL", [id.uuidString]) {
            self.decode(Self.blob($0, 0), sealed: sqlite3_column_int($0, 1) != 0)
        })?.first ?? nil
    }

    /// Rewrites every row under the current `sealKey` (sealing, unsealing, or with a new key).
    /// `previous` opens rows sealed with the old key. Returns how many rows couldn't be read.
    @discardableResult
    public func reseal(previous: SymmetricKey?) throws -> Int {
        let target = sealKey
        var failures = 0
        try transaction {
            func open(_ data: Data, _ sealed: Bool) -> Data? {
                guard sealed else { return data }
                if let previous, let plain = try? SyncCrypto.open(data, using: previous) { return plain }
                if let target, let plain = try? SyncCrypto.open(data, using: target) { return plain }
                return nil
            }
            func seal(_ data: Data) throws -> (Data, Int) {
                guard let target else { return (data, 0) }
                return (try SyncCrypto.seal(data, using: target), 1)
            }
            let items = try rows("SELECT id, meta, sealed FROM items") { (Self.text($0, 0), Self.blob($0, 1), sqlite3_column_int($0, 2) != 0) }
            for (id, meta, sealed) in items {
                guard let plain = open(meta, sealed) else { failures += 1; continue }
                let (out, flag) = try seal(plain)
                try run("UPDATE items SET meta = ?, sealed = ? WHERE id = ?", [out, flag, id])
            }
            let images = try rows("SELECT id, image, thumbnail, sealed FROM images") {
                (Self.text($0, 0), Self.blob($0, 1), sqlite3_column_type($0, 2) == SQLITE_NULL ? nil : Self.blob($0, 2),
                 sqlite3_column_int($0, 3) != 0)
            }
            for (id, image, thumbnail, sealed) in images {
                guard let plain = open(image, sealed) else { failures += 1; continue }
                let thumb = thumbnail.flatMap { open($0, sealed) }
                let (out, flag) = try seal(plain)
                let outThumb = try thumb.map { try seal($0).0 }
                try run("UPDATE images SET image = ?, thumbnail = ?, sealed = ? WHERE id = ?", [out, outThumb, flag, id])
            }
        }
        // Old copies of the rows would otherwise linger in the write-ahead log and free pages.
        try? exec("PRAGMA wal_checkpoint(TRUNCATE)")
        try? exec("VACUUM")
        return failures
    }

    // MARK: Tombstones

    public func tombstone(_ id: UUID) -> Date? {
        (try? rows("SELECT at FROM tombstones WHERE id = ?", [id.uuidString]) { Date(timeIntervalSinceReferenceDate: sqlite3_column_double($0, 0)) })?.first
    }

    public func tombstones() -> [(UUID, Date)] {
        (try? rows("SELECT id, at FROM tombstones") { stmt -> (UUID, Date)? in
            guard let id = UUID(uuidString: Self.text(stmt, 0)) else { return nil }
            return (id, Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1)))
        })?.compactMap { $0 } ?? []
    }

    public func removeTombstone(_ id: UUID) throws {
        try run("DELETE FROM tombstones WHERE id = ?", [id.uuidString])
    }

    // MARK: Key-value

    public func data(forKey key: String) -> Data? {
        (try? rows("SELECT value FROM kv WHERE key = ?", [key]) { Self.blob($0, 0) })?.first
    }

    public func set(_ data: Data?, forKey key: String) throws {
        if let data {
            try run("INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, data])
        } else {
            try run("DELETE FROM kv WHERE key = ?", [key])
        }
    }

    public func removeValues(withPrefix prefix: String) throws {
        try run("DELETE FROM kv WHERE substr(key, 1, ?) = ?", [prefix.count, prefix])
    }

    public func string(forKey key: String) -> String? { data(forKey: key).flatMap { String(data: $0, encoding: .utf8) } }
    public func set(_ string: String?, forKey key: String) throws { try set(string.map { Data($0.utf8) }, forKey: key) }

    // MARK: SQLite plumbing

    public func transaction(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        let nested = sqlite3_get_autocommit(db) == 0
        if nested { return try body() }
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func exec(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw DatabaseError("Database error: \(message)")
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError("Database error: \(String(cString: sqlite3_errmsg(db)))")
        }
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            switch arg {
            case nil: sqlite3_bind_null(stmt, index)
            case let v as String: sqlite3_bind_text(stmt, index, v, -1, Self.transient)
            case let v as Int: sqlite3_bind_int64(stmt, index, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, index, v)
            case let v as Data:
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(v.count), Self.transient) }
            default: sqlite3_bind_null(stmt, index)
            }
        }
        return stmt
    }

    func run(_ sql: String, _ args: [Any?] = []) throws {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw DatabaseError("Database error: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func rows<T>(_ sql: String, _ args: [Any?] = [], _ map: (OpaquePointer?) -> T) throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(map(stmt)) }
        return out
    }

    func scalarInt(_ sql: String, _ args: [Any?] = []) throws -> Int? {
        try rows(sql, args) { sqlite3_column_type($0, 0) == SQLITE_NULL ? nil : Int(sqlite3_column_int64($0, 0)) }.first ?? nil
    }

    static func text(_ stmt: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }

    static func blob(_ stmt: OpaquePointer?, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(stmt, column))
        guard count > 0, let pointer = sqlite3_column_blob(stmt, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    static let encoder = PropertyListEncoder()
    static let decoder = PropertyListDecoder()
}

/// A capture's details as they travel through iCloud (sealed with the sync key). The
/// picture travels beside them as its own sealed asset, sent once, so renaming or tagging
/// a capture only sends these few bytes.
public struct SyncedItem: Codable, Equatable, Sendable {
    public var version = 1
    public var item: CaptureItem

    public init(item: CaptureItem) {
        self.item = item
    }

    public func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SyncedItem {
        try PropertyListDecoder().decode(SyncedItem.self, from: data)
    }

    /// Whether an incoming copy should replace what a Mac has: newer wins; on a tie a
    /// deletion wins, so a delete and an edit in the same second can't bring an item back.
    public static func wins(_ incoming: Date, incomingIsDeletion: Bool, over local: Date?, localIsDeletion: Bool) -> Bool {
        guard let local else { return true }
        if incoming != local { return incoming > local }
        return incomingIsDeletion && !localIsDeletion
    }
}
