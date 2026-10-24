import Foundation

/// The library as files in a folder that Dropbox, OneDrive, Google Drive or any other sync
/// service keeps in step between Macs. Everything but `Folder.json` is sealed with the sync
/// key, so the service only ever holds ciphertext.
///
///     CaptureLens Library/
///         Folder.json             which sync key the folder belongs to (its public fingerprint)
///         Items/<id>.clitem       a capture's details (a sealed `SyncedItem`), rewritten on each change
///         Images/<id>.climage     its picture (sealed PNG), written once
///         Deleted/<id>.cldel      a deletion (a sealed `SyncedDeletion`), kept 90 days
///
/// Sync services can't merge files, so when two Macs change the same capture at once they
/// keep both, renaming one: "<id> (Steve's conflicted copy 2026-10-24).clitem" (Dropbox),
/// "<id>-MacBook.clitem" (OneDrive), "<id> (1).clitem" (Google Drive). Any file whose name
/// starts with an ID is read as a version of that capture; the newest wins and the others go.
public enum FolderLayout {
    public static let rootName = "CaptureLens Library"
    public static let infoName = "Folder.json"
    public static let itemsFolder = "Items"
    public static let imagesFolder = "Images"
    public static let deletedFolder = "Deleted"

    public enum Kind: String, Sendable {
        case item = "clitem", image = "climage", deletion = "cldel"

        public var folder: String {
            switch self {
            case .item: FolderLayout.itemsFolder
            case .image: FolderLayout.imagesFolder
            case .deletion: FolderLayout.deletedFolder
            }
        }
    }

    /// One file in the folder, as its name describes it.
    public struct Entry: Equatable, Sendable {
        public var id: UUID
        public var kind: Kind
        /// A conflicted copy the sync service made, rather than the file itself.
        public var isConflict: Bool
    }

    public static func fileName(_ id: UUID, _ kind: Kind) -> String {
        "\(id.uuidString).\(kind.rawValue)"
    }

    /// What a file name stands for, or nil for anything that isn't one of ours (".DS_Store",
    /// a partial download such as "x.clitem.tmp" or "~$x", Dropbox's ".dropbox").
    public static func parse(_ name: String) -> Entry? {
        guard let dot = name.lastIndex(of: "."), let kind = Kind(rawValue: String(name[name.index(after: dot)...])),
              name.count >= 36, let id = UUID(uuidString: String(name.prefix(36))) else { return nil }
        let rest = name[name.index(name.startIndex, offsetBy: 36)..<dot]
        return Entry(id: id, kind: kind, isConflict: !rest.isEmpty)
    }

    /// The folder's identity: which sync key its files are sealed with.
    public struct Info: Codable, Equatable, Sendable {
        public var version = 1
        public var keyID: String
        public var created: Date

        public init(keyID: String, created: Date = Date()) {
            self.keyID = keyID
            self.created = created
        }
    }

    /// Of several versions of one capture (the file and its conflicted copies), the one to
    /// keep: the newest change. A deletion beats an edit made in the same instant.
    public static func newest(_ versions: [(modified: Date, isDeletion: Bool)]) -> Int? {
        guard !versions.isEmpty else { return nil }
        var best = 0
        for i in versions.indices.dropFirst() {
            let candidate = versions[i], current = versions[best]
            if SyncedItem.wins(candidate.modified, incomingIsDeletion: candidate.isDeletion,
                               over: current.modified, localIsDeletion: current.isDeletion) {
                best = i
            }
        }
        return best
    }

    /// How long a deletion is kept in the folder, so a Mac that was away catches it.
    public static let deletionLifetime: TimeInterval = 90 * 86_400
}

/// A capture deleted on some Mac, as it travels through a sync folder.
public struct SyncedDeletion: Codable, Equatable, Sendable {
    public var version = 1
    public var id: UUID
    public var at: Date

    public init(id: UUID, at: Date) {
        self.id = id
        self.at = at
    }

    public func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SyncedDeletion {
        try PropertyListDecoder().decode(SyncedDeletion.self, from: data)
    }
}
