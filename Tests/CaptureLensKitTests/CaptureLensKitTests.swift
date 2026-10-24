import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import CaptureLensKit

/// A line at row `row` (0 = top) of a page with lines 0.05 tall and 0.03 apart.
private func line(_ text: String, row: Double, x: Double = 0.05, width: Double = 0.9, gapRows: Double = 0) -> RecognizedLine {
    let top = 0.95 - (row + gapRows) * 0.08
    return RecognizedLine(text: text, box: CGRect(x: x, y: top - 0.05, width: width, height: 0.05))
}

@Suite struct AssemblerTests {
    @Test func keepsLineBreaks() {
        let lines = [line("second", row: 1), line("first", row: 0)]
        #expect(TextAssembler.assemble(lines, keepLineBreaks: true) == "first\nsecond")
    }

    @Test func reflowsWrappedParagraph() {
        let lines = [line("The quick brown fox jumps over", row: 0),
                     line("the lazy dog.", row: 1, width: 0.3)]
        #expect(TextAssembler.assemble(lines, keepLineBreaks: false) == "The quick brown fox jumps over the lazy dog.")
    }

    @Test func mendsHyphenation() {
        let lines = [line("an extra-", row: 0), line("ordinary day", row: 1)]
        #expect(TextAssembler.assemble(lines, keepLineBreaks: false) == "an extraordinary day")
    }

    @Test func keepsShortSentenceEndAsBreak() {
        let lines = [line("Title.", row: 0, width: 0.2), line("Body text here", row: 1)]
        #expect(TextAssembler.assemble(lines, keepLineBreaks: false) == "Title.\nBody text here")
    }

    @Test func blankGapMakesParagraph() {
        let lines = [line("One", row: 0), line("Two", row: 1, gapRows: 1)]
        #expect(TextAssembler.assemble(lines, keepLineBreaks: false) == "One\n\nTwo")
    }

    @Test func listItemsStayOnTheirOwnLines() {
        let lines = [line("Groceries", row: 0), line("• milk", row: 1), line("• eggs", row: 2), line("1. first", row: 3)]
        #expect(TextAssembler.assemble(lines, keepLineBreaks: false) == "Groceries\n• milk\n• eggs\n1. first")
    }

    @Test func sameRowJoinsLeftToRightWithTabForColumns() {
        let lines = [line("Price", row: 0, x: 0.6, width: 0.2), line("Item", row: 0, x: 0.05, width: 0.2),
                     line("Apple", row: 1, x: 0.05, width: 0.2), line("1.00", row: 1, x: 0.6, width: 0.2)]
        #expect(TextAssembler.assemble(lines, keepLineBreaks: false) == "Item\tPrice\nApple\t1.00")
    }

    @Test func emptyInput() {
        #expect(TextAssembler.assemble([], keepLineBreaks: false) == "")
    }
}

@Suite struct CryptoTests {
    @Test func syncKeyringUnlocksOnlyWithItsPassphrase() throws {
        let (keyring, key) = try SyncCrypto.createKeyring(passphrase: "correct horse", iterations: 1_000)
        let unwrapped = try SyncCrypto.unwrap(keyring, passphrase: "correct horse")
        #expect(SyncCrypto.keyID(for: unwrapped) == keyring.keyID)
        #expect(SyncCrypto.keyID(for: key) == keyring.keyID)
        #expect(throws: SyncCrypto.CryptoError.self) { try SyncCrypto.unwrap(keyring, passphrase: "wrong horse") }
    }

    @Test func sealedFilesHideTheirContents() throws {
        let key = SymmetricKey(size: .bits256)
        let plain = Data(String(repeating: "captureShortcut=⌃⌥⌘1 ", count: 40).utf8)
        let sealed = try SyncCrypto.seal(plain, using: key)
        #expect(sealed.prefix(4) == Data("CLE1".utf8))
        #expect(sealed.range(of: Data("captureShortcut".utf8)) == nil)
        #expect(try SyncCrypto.open(sealed, using: key) == plain)
        #expect(throws: SyncCrypto.CryptoError.self) { try SyncCrypto.open(sealed, using: SymmetricKey(size: .bits256)) }
        #expect(throws: SyncCrypto.CryptoError.self) { try SyncCrypto.open(plain, using: key) }
    }

}

private func item(_ name: String, daysAgo: Double = 0, now: Date, tags: [String] = [], notes: String = "", text: String = "",
                  app: String? = nil, bundle: String? = nil, url: String? = nil, kind: CaptureItem.Kind = .region,
                  favorite: Bool = false) -> CaptureItem {
    CaptureItem(created: now.addingTimeInterval(-daysAgo * 86_400), kind: kind, name: name, tags: tags, notes: notes,
                recognizedText: text, favorite: favorite,
                source: .init(appName: app, bundleID: bundle, url: url), pixelWidth: 200, pixelHeight: 100)
}

@Suite struct LibraryQueryTests {
    // Noon, so "today" and "yesterday" don't straddle midnight in any time zone the tests run in.
    let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_792_000_000))!

    var items: [CaptureItem] {
        [
            item("Quarterly Revenue Chart", now: now, tags: ["Work", "finance"], text: "Revenue Q3 total 4,200",
                 app: "Safari", bundle: "com.apple.Safari", url: "https://www.example.com/report"),
            item("Build error", daysAgo: 1, now: now, notes: "Linker fails on Intel", text: "ld: symbol not found",
                 app: "Xcode", bundle: "com.apple.dt.Xcode", kind: .window),
            item("Café menu", daysAgo: 10, now: now, tags: ["food"], favorite: true),
            item("Old diagram", daysAgo: 400, now: now, tags: ["work"], kind: .screen),
        ]
    }

    func names(_ filter: LibraryFilter, sort: LibrarySort = .newest) -> [String] {
        LibraryQuery.filter(items, with: filter, sort: sort, now: now).map(\.name)
    }

    @Test func wordsMatchNameTagsNotesAndTextIgnoringCaseAndAccents() {
        var f = LibraryFilter()
        f.text = "revenue"
        #expect(names(f) == ["Quarterly Revenue Chart"])
        f.text = "linker intel"
        #expect(names(f) == ["Build error"])
        f.text = "cafe"
        #expect(names(f) == ["Café menu"])
        f.text = "symbol"
        #expect(names(f) == ["Build error"])
        f.text = "example.com"
        #expect(names(f) == ["Quarterly Revenue Chart"])
    }

    @Test func prefixedTermsAndTags() {
        var f = LibraryFilter()
        f.text = "tag:work"
        #expect(names(f) == ["Quarterly Revenue Chart", "Old diagram"])
        f.text = "app:xcode"
        #expect(names(f) == ["Build error"])
        f.text = "site:example"
        #expect(names(f) == ["Quarterly Revenue Chart"])
        f.text = ""
        f.tags = ["WORK", "Finance"]
        #expect(names(f) == ["Quarterly Revenue Chart"])
    }

    @Test func dateRangesAndDatesInTheSearch() {
        var f = LibraryFilter()
        f.dateRange = .today
        #expect(names(f) == ["Quarterly Revenue Chart"])
        f.dateRange = .yesterday
        #expect(names(f) == ["Build error"])
        f.dateRange = .lastMonth
        #expect(names(f) == ["Quarterly Revenue Chart", "Build error", "Café menu"])
        f.dateRange = .custom(start: now.addingTimeInterval(-11 * 86_400), end: now.addingTimeInterval(-9 * 86_400))
        #expect(names(f) == ["Café menu"])
        f.dateRange = .any
        f.text = "yesterday"
        #expect(names(f) == ["Build error"])
        let tenDaysAgo = now.addingTimeInterval(-10 * 86_400)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMMM d, yyyy"
        f.text = formatter.string(from: tenDaysAgo)
        #expect(names(f) == ["Café menu"])
    }

    @Test func chipsAndSorting() {
        var f = LibraryFilter()
        f.kinds = [.window, .screen]
        #expect(names(f) == ["Build error", "Old diagram"])
        f.kinds = []
        f.favoritesOnly = true
        #expect(names(f) == ["Café menu"])
        f.favoritesOnly = false
        f.withNotesOnly = true
        #expect(names(f) == ["Build error"])
        f.withNotesOnly = false
        f.apps = ["com.apple.Safari"]
        #expect(names(f) == ["Quarterly Revenue Chart"])
        f.apps = []
        f.websites = ["example.com"]
        #expect(names(f) == ["Quarterly Revenue Chart"])
        #expect(names(LibraryFilter(), sort: .name) == ["Build error", "Café menu", "Old diagram", "Quarterly Revenue Chart"])
        #expect(names(LibraryFilter(), sort: .oldest).first == "Old diagram")
    }

    @Test func tagsAreTidiedAndCounted() {
        #expect(LibraryQuery.normalizedTags([" #Work ", "work", "", "Finance", "##finance"]) == ["Work", "Finance"])
        let counts = LibraryQuery.tagCounts(items)
        #expect(counts.map(\.tag) == ["finance", "food", "Work"])
        #expect(counts.first { $0.tag == "Work" }?.count == 2)
        #expect(LibraryQuery.appCounts(items).map(\.name).sorted() == ["Safari", "Xcode"])
        #expect(LibraryQuery.websiteCounts(items).map(\.site) == ["example.com"])
    }

    @Test func namesAreCleanedOrFallBack() {
        #expect(CaptureNaming.clean("\"Revenue chart for Q3.\"") == "Revenue chart for Q3")
        #expect(CaptureNaming.clean("Title: Login screen\nextra") == "Login screen")
        #expect(CaptureNaming.clean("a/b: c.png") == "a-b - c")
        #expect(CaptureNaming.clean(" ") == nil)
        let long = String(repeating: "word ", count: 30)
        #expect(CaptureNaming.clean(long)!.count <= CaptureNaming.maxLength)
        let date = Date(timeIntervalSince1970: 0)
        #expect(CaptureNaming.fallback(source: .init(appName: "Safari", windowTitle: "Example Page"), date: date) == "Safari – Example Page")
        #expect(CaptureNaming.fallback(source: .init(), date: date).hasPrefix("Capture 19"))
    }
}

@Suite struct LibraryDatabaseTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "CaptureLensTest-\(UUID().uuidString)/Library.sqlite")
    }

    @Test func storesItemsPicturesAndDeletions() throws {
        let db = try LibraryDatabase(url: tempURL())
        let now = Date()
        var a = item("First", now: now, tags: ["x"])
        let b = item("Second", daysAgo: 1, now: now)
        try db.upsert([(a, image: Data([1, 2, 3]), thumbnail: Data([4])), (b, image: Data([5]), thumbnail: nil)])
        #expect(db.allItems().map(\.name) == ["First", "Second"])
        #expect(db.image(a.id) == Data([1, 2, 3]))
        #expect(db.thumbnail(a.id) == Data([4]))
        #expect(db.thumbnail(b.id) == nil)
        a.name = "Renamed"
        a.cursor = CursorLayer(png: Data([9]), width: 20, height: 30, x: 5, y: 6)
        try db.upsert(a)
        #expect(db.item(a.id)?.name == "Renamed")
        #expect(db.item(a.id)?.cursor?.frame == CGRect(x: 5, y: 6, width: 20, height: 30))
        #expect(db.image(a.id) == Data([1, 2, 3]), "updating details keeps the picture")
        try db.delete([b.id], tombstone: now)
        #expect(db.count == 1)
        #expect(db.image(b.id) == nil)
        #expect(db.tombstone(b.id) == now)
        try db.upsert(b)
        #expect(db.tombstone(b.id) == nil, "re-adding clears the tombstone")
    }

    @Test func encryptionAtRestHidesContentsAndReseals() throws {
        let url = tempURL()
        let key = SymmetricKey(size: .bits256)
        let db = try LibraryDatabase(url: url, sealKey: key)
        let secret = item("Secret plans", now: Date(), notes: "launch codes", text: "TOP SECRET")
        let picture = Data(String(repeating: "PNGPIXELS", count: 50).utf8)
        try db.upsert(secret, image: picture, thumbnail: picture)
        try db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        let raw = try Data(contentsOf: url)
        #expect(raw.range(of: Data("launch codes".utf8)) == nil)
        #expect(raw.range(of: Data("PNGPIXELS".utf8)) == nil)
        #expect(db.item(secret.id)?.notes == "launch codes")
        #expect(db.image(secret.id) == picture)

        // Without the key nothing is readable, and nothing is lost.
        db.sealKey = nil
        #expect(db.allItems().isEmpty)
        #expect(db.unreadableCount == 1)

        // Turning encryption off rewrites the rows plainly.
        #expect(try db.reseal(previous: key) == 0)
        #expect(db.sealedCount == 0)
        #expect(db.item(secret.id)?.name == "Secret plans")
        #expect(db.image(secret.id) == picture)

        // And on again with a new key.
        let newKey = SymmetricKey(size: .bits256)
        db.sealKey = newKey
        #expect(try db.reseal(previous: nil) == 0)
        #expect(db.sealedCount == 1)
        #expect(db.thumbnail(secret.id) == picture)
        db.sealKey = key
        #expect(db.item(secret.id) == nil, "the old key no longer opens it")
    }

    @Test func syncedItemRoundTripsAndResolves() throws {
        let original = item("Synced", now: Date(), tags: ["a"])
        let decoded = try SyncedItem.decode(SyncedItem(item: original).encoded())
        #expect(decoded.item == original)
        let t = Date()
        #expect(SyncedItem.wins(t.addingTimeInterval(1), incomingIsDeletion: false, over: t, localIsDeletion: false))
        #expect(!SyncedItem.wins(t, incomingIsDeletion: false, over: t, localIsDeletion: false))
        #expect(SyncedItem.wins(t, incomingIsDeletion: true, over: t, localIsDeletion: false))
        #expect(SyncedItem.wins(t, incomingIsDeletion: false, over: nil, localIsDeletion: false))
    }

    @Test func olderItemsWithoutNewFieldsStillDecode() throws {
        let minimal: [String: Any] = ["id": UUID().uuidString, "created": Date()]
        let data = try PropertyListSerialization.data(fromPropertyList: minimal, format: .binary, options: 0)
        let decoded = try PropertyListDecoder().decode(CaptureItem.self, from: data)
        #expect(decoded.tags.isEmpty && decoded.kind == .region && decoded.nameIsAutomatic)
    }
}
