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

@Suite struct FolderLayoutTests {
    let id = UUID(uuidString: "6C1D0E2A-0001-4C6E-9C1A-CA9701E50001")!

    @Test func namesRoundTrip() {
        let name = FolderLayout.fileName(id, .item)
        #expect(name == "6C1D0E2A-0001-4C6E-9C1A-CA9701E50001.clitem")
        #expect(FolderLayout.parse(name) == .init(id: id, kind: .item, isConflict: false))
        #expect(FolderLayout.parse(FolderLayout.fileName(id, .image))?.kind == .image)
        #expect(FolderLayout.parse(FolderLayout.fileName(id, .deletion))?.kind == .deletion)
    }

    @Test func conflictedCopiesFromEachService() {
        let base = id.uuidString
        for name in ["\(base) (Steve's conflicted copy 2026-10-24).clitem", "\(base)-MacBook-Pro.clitem", "\(base) (1).clitem"] {
            #expect(FolderLayout.parse(name) == .init(id: id, kind: .item, isConflict: true), "\(name)")
        }
    }

    @Test func ignoresOtherFiles() {
        for name in [".DS_Store", "Folder.json", "\(id.uuidString).clitem.tmp", "~$\(id.uuidString).clitem",
                     "notes.clitem", "\(id.uuidString).png", ".dropbox"] {
            #expect(FolderLayout.parse(name) == nil, "\(name)")
        }
    }

    @Test func newestVersionWinsAndDeletionWinsTies() {
        let t = Date()
        #expect(FolderLayout.newest([]) == nil)
        #expect(FolderLayout.newest([(t, false), (t.addingTimeInterval(5), false), (t.addingTimeInterval(1), false)]) == 1)
        #expect(FolderLayout.newest([(t, false), (t, true)]) == 1)
        #expect(FolderLayout.newest([(t, true), (t, false)]) == 0)
        #expect(FolderLayout.newest([(t.addingTimeInterval(9), false), (t, true)]) == 0)
    }

    @Test func deletionAndInfoRoundTrip() throws {
        let deletion = SyncedDeletion(id: id, at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(try SyncedDeletion.decode(deletion.encoded()) == deletion)
        let info = FolderLayout.Info(keyID: "abc", created: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try JSONEncoder().encode(info)
        #expect(try JSONDecoder().decode(FolderLayout.Info.self, from: data) == info)
    }
}

@Suite struct AnnotationTests {
    let style = AnnotationStyle(color: .red, lineWidth: 4, shadow: false)

    @Test func itemsKeepTheirAnnotations() throws {
        var item = CaptureItem(kind: .region, name: "With marks", pixelWidth: 200, pixelHeight: 100)
        item.annotations = [
            Annotation(kind: .rectangle, rect: CGRect(x: 10, y: 10, width: 50, height: 30), style: style),
            Annotation(kind: .arrow, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 40, y: 40), style: style),
            Annotation(kind: .text, rect: CGRect(x: 5, y: 60, width: 80, height: 30), text: "Look here", style: style),
            Annotation(kind: .pen, points: [CGPoint(x: 1, y: 1), CGPoint(x: 5, y: 9)], style: style),
        ]
        let decoded = try SyncedItem.decode(SyncedItem(item: item).encoded()).item
        #expect(decoded.annotations == item.annotations)
        // Captures from before annotations decode with none.
        let older = try PropertyListSerialization.data(fromPropertyList: ["id": UUID().uuidString, "created": Date()], format: .binary, options: 0)
        #expect(try PropertyListDecoder().decode(CaptureItem.self, from: older).annotations.isEmpty)
    }

    @Test func hitTesting() {
        let box = Annotation(kind: .rectangle, rect: CGRect(x: 10, y: 10, width: 100, height: 50), style: style)
        #expect(box.hit(CGPoint(x: 10, y: 30)))
        #expect(!box.hit(CGPoint(x: 60, y: 35)), "an empty box is picked up by its edge")
        var filled = box
        filled.style.filled = true
        #expect(filled.hit(CGPoint(x: 60, y: 35)))
        let arrow = Annotation(kind: .arrow, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), style: style)
        #expect(arrow.hit(CGPoint(x: 50, y: 3)))
        #expect(!arrow.hit(CGPoint(x: 50, y: 30)))
        let ring = Annotation(kind: .ellipse, rect: CGRect(x: 0, y: 0, width: 100, height: 100), style: style)
        #expect(ring.hit(CGPoint(x: 100, y: 50)))
        #expect(!ring.hit(CGPoint(x: 50, y: 50)))
    }

    @Test func geometryHelpers() {
        #expect(Annotation.rect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 0, y: 30), constrain: false) == CGRect(x: 0, y: 10, width: 10, height: 20))
        #expect(Annotation.rect(from: .zero, to: CGPoint(x: 10, y: 30), constrain: true).size == CGSize(width: 30, height: 30))
        let snapped = Annotation.lineEnd(from: .zero, to: CGPoint(x: 100, y: 8), constrain: true)
        #expect(abs(snapped.y) < 0.001)
        var moved = Annotation(kind: .callout, rect: CGRect(x: 0, y: 0, width: 10, height: 10), tail: CGPoint(x: 20, y: 20), style: style)
        moved.offset(dx: 5, dy: -5)
        #expect(moved.rect.origin == CGPoint(x: 5, y: -5) && moved.tail == CGPoint(x: 25, y: 15))
        let steps = [Annotation(kind: .step, style: style), Annotation(kind: .arrow, style: style), Annotation(kind: .step, style: style)]
        let numbers = Annotation.stepNumbers(steps)
        #expect(numbers[steps[0].id] == 1 && numbers[steps[2].id] == 2 && numbers[steps[1].id] == nil)
    }

    /// The picture's pixel at (x, y) in points from the top left, as RGBA bytes.
    func pixel(_ image: CGImage, _ x: Int, _ y: Int, scale: Int = 1) -> [UInt8] {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        // Bitmap memory rows run from the top.
        let offset = (y * scale) * image.width * 4 + (x * scale) * 4
        return Array(UnsafeBufferPointer(start: data + offset, count: 4))
    }

    func whitePicture(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    @Test func flattenDrawsMarksWhereTheyAreAndLeavesTheRest() throws {
        let base = whitePicture(width: 400, height: 200) // 200 × 100 points at 2×
        let marks = [
            Annotation(kind: .rectangle, rect: CGRect(x: 20, y: 10, width: 60, height: 40), style: AnnotationStyle(color: .red, lineWidth: 4, shadow: false)),
            Annotation(kind: .step, rect: CGRect(x: 150, y: 60, width: 30, height: 30), style: AnnotationStyle(color: .blue, shadow: false)),
        ]
        let flat = try #require(AnnotationRenderer.flatten(base: base, scale: 2, annotations: marks, cursor: nil))
        #expect(flat.width == 400 && flat.height == 200)
        let edge = pixel(flat, 20, 30, scale: 2)          // left edge of the box: red
        #expect(edge[0] > 200 && edge[1] < 120 && edge[2] < 120)
        let inside = pixel(flat, 50, 30, scale: 2)        // inside the empty box: still white
        #expect(inside[0] > 240 && inside[1] > 240 && inside[2] > 240)
        let step = pixel(flat, 154, 75, scale: 2)          // the step's disc, off its number: blue
        #expect(step[2] > 200 && step[0] < 100)
        // The original is untouched: annotations never go into its pixels.
        #expect(pixel(base, 20, 30, scale: 2)[1] == 255)
    }

    @Test func spotlightDimsOutsideOnly() throws {
        let base = whitePicture(width: 100, height: 100)
        let spot = Annotation(kind: .spotlight, rect: CGRect(x: 30, y: 30, width: 40, height: 40), style: style)
        let flat = try #require(AnnotationRenderer.flatten(base: base, scale: 1, annotations: [spot], cursor: nil))
        #expect(pixel(flat, 50, 50)[0] > 240)
        #expect(pixel(flat, 5, 5)[0] < 140)
    }

    @Test func textAndArrowsDrawSomething() throws {
        let base = whitePicture(width: 300, height: 120)
        let text = Annotation(kind: .text, rect: CGRect(x: 10, y: 10, width: 280, height: 60), text: "MMMMMMMM",
                              style: AnnotationStyle(color: .black, fontSize: 40, shadow: false))
        let flat = try #require(AnnotationRenderer.flatten(base: base, scale: 1, annotations: [text], cursor: nil))
        let dark = (10..<280).contains { x in (12..<60).contains { y in pixel(flat, x, y)[0] < 80 } }
        #expect(dark, "the text appears in its box")
        #expect(pixel(flat, 150, 110)[0] > 240, "and not below it")
        #expect(AnnotationRenderer.textSize("Hello", style: text.style, width: 500).width > 60)
    }
}

@Suite struct CalloutTests {
    @Test func calloutTailJoinsTheBubbleWithoutAHole() throws {
        let ctx = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let base = ctx.makeImage()!
        let callout = Annotation(kind: .callout, rect: CGRect(x: 150, y: 100, width: 120, height: 60), tail: CGPoint(x: 20, y: 20),
                                 style: AnnotationStyle(color: .purple, shadow: false))
        let flat = try #require(AnnotationRenderer.flatten(base: base, scale: 1, annotations: [callout], cursor: nil))
        let tests = AnnotationTests()
        // Where the wedge crosses the bubble (between its middle and the tail): purple, not white.
        let crossing = tests.pixel(flat, 175, 115)
        #expect(crossing[0] > 120 && crossing[1] < 120, "overlap filled: \(crossing)")
        #expect(tests.pixel(flat, 60, 43)[1] < 150, "the tail reaches out toward its point")
    }
}

@Suite struct EditTests {
    let helper = AnnotationTests()

    /// 200 × 100 points at 2×: left half red, right half blue, so turns and crops can be told apart.
    func picture() -> CGImage {
        let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 200, y: 0, width: 200, height: 200))
        return ctx.makeImage()!
    }

    func render(_ edits: ImageEdits, annotations: [Annotation] = [], mask: CGImage? = nil) throws -> CGImage {
        try #require(EditRenderer.render(base: picture(), scale: 2, edits: edits, annotations: annotations, cursor: nil, mask: mask))
    }

    @Test func noEditsLeavesThePicture() throws {
        let out = try render(.none)
        #expect(out.width == 400 && out.height == 200)
    }

    @Test func cropKeepsThePartChosen() throws {
        var edits = ImageEdits()
        edits.crop = CGRect(x: 110, y: 10, width: 50, height: 40)   // inside the blue half
        let out = try render(edits)
        #expect(out.width == 100 && out.height == 80)
        #expect(helper.pixel(out, 10, 10)[2] > 200)
        #expect(edits.outputSize(for: CGSize(width: 200, height: 100)) == CGSize(width: 50, height: 40))
    }

    @Test func rotationTurnsClockwise() throws {
        let out = try render(ImageEdits().rotated(clockwise: true))
        #expect(out.width == 200 && out.height == 400)
        // Turned clockwise, the left (red) half ends up on top.
        #expect(helper.pixel(out, 50, 20)[0] > 200)
        #expect(helper.pixel(out, 50, 380)[2] > 200)
        #expect(ImageEdits().rotated(clockwise: false).rotation == 3)
    }

    @Test func cutOutsRemoveStrips() throws {
        var edits = ImageEdits()
        edits.cuts = [CutOut(axis: .vertical, from: 80, to: 120, seam: .straight)]
        let out = try render(edits)
        #expect(out.width == 320 && out.height == 200)
        #expect(edits.outputSize(for: CGSize(width: 200, height: 100)).width == 160)
        // A torn seam leaves a small gap between the two sides.
        edits.cuts = [CutOut(axis: .horizontal, from: 30, to: 60, seam: .torn)]
        let torn = try render(edits)
        #expect(torn.height == 200 - 60 + 16)
        let counted = edits.outputSize(for: CGSize(width: 200, height: 100)).height
        #expect(counted == 78, "the size counts the gap: \(counted)")
        #expect(helper.pixel(torn, 100, 68)[3] < 40, "the gap (rows 60–76) is transparent")
    }

    @Test func resizeBorderAndShadow() throws {
        var edits = ImageEdits()
        edits.outputScale = 0.5
        #expect(try render(edits).width == 200)
        edits.outputScale = 1
        edits.border = Border(width: 4, color: .green, cornerRadius: 0, shadow: false)
        let framed = try render(edits)
        #expect(framed.width == 400)
        let edge = helper.pixel(framed, 1, 50)
        #expect(edge[1] > 150 && edge[0] < 100, "the border is green")
        edits.border?.shadow = true
        let shadowed = try render(edits)
        #expect(shadowed.width == 400 + 72, "a margin for the shadow")
    }

    @Test func edgesCutIntoTheSides() throws {
        var edits = ImageEdits()
        edits.edges = EdgeEffect(kind: .torn, sides: [.bottom])
        let torn = try render(edits)
        let bottomRow = (0..<400).filter { helper.pixel(torn, $0, 199)[3] < 50 }.count
        #expect(bottomRow > 20, "parts of the bottom edge are torn away")
        #expect(helper.pixel(torn, 100, 1)[3] == 255, "the top is untouched")
        edits.edges = EdgeEffect(kind: .fade, sides: [.left])
        let faded = try render(edits)
        #expect(helper.pixel(faded, 0, 50)[3] < 60)
        #expect(helper.pixel(faded, 100, 50)[3] == 255)
    }

    @Test func backgroundRemovalKeepsTheMask() throws {
        let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 100, y: 50, width: 200, height: 100))   // the subject, in the middle
        var edits = ImageEdits()
        edits.removeBackground = true
        let out = try render(edits, mask: ctx.makeImage()!)
        #expect(helper.pixel(out, 100, 50)[3] == 255)
        #expect(helper.pixel(out, 5, 5)[3] == 0)
        // Without a mask it's left alone.
        #expect(helper.pixel(try render(edits), 5, 5)[3] == 255)
    }

    @Test func blurPixelateAndRedactHideWhatsUnder() throws {
        let marks = [Annotation(kind: .redact, rect: CGRect(x: 10, y: 10, width: 40, height: 40), style: AnnotationStyle(color: .black, shadow: false)),
                     Annotation(kind: .blur, rect: CGRect(x: 80, y: 10, width: 40, height: 40), style: .standard)]
        let out = try render(.none, annotations: marks)
        #expect(helper.pixel(out, 30, 30, scale: 2)[0] < 40, "redacted in black")
        // Blurred across the red/blue border at x = 100: purple in the middle, not pure.
        let mid = helper.pixel(out, 100, 30, scale: 2)
        #expect(mid[0] > 40 && mid[2] > 40)
        let hit = Annotation(kind: .pixelate, rect: CGRect(x: 0, y: 0, width: 20, height: 20), style: .standard)
        #expect(hit.hit(CGPoint(x: 10, y: 10)))
    }

    @Test func editsRoundTripAndOlderItemsHaveNone() throws {
        var item = CaptureItem(kind: .region, name: "Edited", pixelWidth: 400, pixelHeight: 200)
        item.edits = ImageEdits(crop: CGRect(x: 1, y: 2, width: 3, height: 4), cuts: [CutOut(axis: .vertical, from: 9, to: 4)],
                                rotation: 3, outputScale: 0.5, border: Border(), edges: EdgeEffect(kind: .wave, sides: [.left, .right]),
                                removeBackground: true)
        #expect(item.edits.cuts[0].from == 4 && item.edits.cuts[0].to == 9)
        #expect(try SyncedItem.decode(SyncedItem(item: item).encoded()).item.edits == item.edits)
        let older = try PropertyListSerialization.data(fromPropertyList: ["id": UUID().uuidString, "created": Date()], format: .binary, options: 0)
        #expect(try PropertyListDecoder().decode(CaptureItem.self, from: older).edits.isEmpty)
    }
}

@Suite struct SensitiveTextTests {
    func kinds(_ text: String) -> [String] {
        SensitiveText.find(in: text).map { "\($0.kind.rawValue):\(text[$0.range])" }
    }

    @Test func findsTheUsualSuspects() {
        #expect(kinds("Mail jane.doe@example.com today") == ["email:jane.doe@example.com"])
        #expect(kinds("Card 4111 1111 1111 1111 exp 12/29").first == "card:4111 1111 1111 1111")
        #expect(kinds("SSN 123-45-6789") == ["idNumber:123-45-6789"])
        #expect(kinds("Server 192.168.1.20 is down") == ["ipAddress:192.168.1.20"])
        #expect(kinds("token ghp_abcdefghijklmnopqrstuvwx1234").contains("secret:ghp_abcdefghijklmnopqrstuvwx1234"))
        #expect(kinds("Call (555) 123-4567 now").contains { $0.hasPrefix("phone:") })
    }

    @Test func leavesOrdinaryTextAlone() {
        #expect(kinds("Quarterly revenue grew 12% in 2026").isEmpty)
        #expect(kinds("Order 1234 5678 9012 3456").filter { $0.hasPrefix("card") }.isEmpty, "fails the card checksum")
        #expect(SensitiveText.luhn("4111111111111111"))
        #expect(!SensitiveText.luhn("4111111111111112"))
    }
}

@Suite struct ScrollStitcherTests {
    /// A tall "page": a header bar, rows of varied stripes and blocks (so every height is
    /// distinct), and a footer bar. Returns the page and how to cut viewport frames from it.
    func page(width: Int = 300, contentHeight: Int = 1600, header: Int = 40, footer: Int = 30) -> CGImage {
        let height = header + contentHeight + footer
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Content: a different pattern on each 10-row band (top-left origin thinking).
        for band in 0..<(contentHeight / 10) {
            let y = height - header - (band + 1) * 10
            let shade = CGFloat((band * 37) % 200) / 255
            ctx.setFillColor(CGColor(gray: shade, alpha: 1))
            let x = (band * 53) % (width - 60)
            ctx.fill(CGRect(x: x, y: y, width: 40 + (band * 11) % 20, height: 10))
            ctx.fill(CGRect(x: (x + 120) % (width - 30), y: y + 3, width: 25, height: 4))
        }
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height - header, width: width, height: header))
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: footer))
        return ctx.makeImage()!
    }

    /// What a window `viewport` rows tall shows when its content is scrolled by `offset`:
    /// the fixed header and footer, and the content in between.
    func frame(of page: CGImage, offset: Int, viewport: Int, header: Int = 40, footer: Int = 30) -> CGImage {
        let width = page.width
        let ctx = CGContext(data: nil, width: width, height: viewport, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let visible = viewport - header - footer
        let content = page.cropping(to: CGRect(x: 0, y: header + offset, width: width, height: visible))!
        let top = page.cropping(to: CGRect(x: 0, y: 0, width: width, height: header))!
        let bottom = page.cropping(to: CGRect(x: 0, y: page.height - footer, width: width, height: footer))!
        ctx.draw(top, in: CGRect(x: 0, y: viewport - header, width: width, height: header))
        ctx.draw(content, in: CGRect(x: 0, y: footer, width: width, height: visible))
        ctx.draw(bottom, in: CGRect(x: 0, y: 0, width: width, height: footer))
        return ctx.makeImage()!
    }

    func rowsEqual(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height,
              let sa = ScrollStitcher.signatures(of: a), let sb = ScrollStitcher.signatures(of: b) else { return false }
        return zip(sa, sb).allSatisfy { ScrollStitcher.difference($0, $1) <= 2 }
    }

    @Test func stitchesScrolledFramesBackIntoThePage() throws {
        let full = page()
        let stitcher = ScrollStitcher()
        var offset = 0
        let viewport = 400, visible = 400 - 70
        var results: [ScrollStitcher.Result] = []
        // Uneven scroll steps, as a person scrolls; the last one stops at the end.
        for step in [0, 90, 133, 61, 200, 150, 77, 240, 199, 300, 500] {
            offset = min(offset + step, 1600 - visible)
            results.append(stitcher.add(frame(of: full, offset: offset, viewport: viewport)))
        }
        #expect(results.first == .first)
        #expect(results.contains(.unchanged), "the frame after reaching the end didn't move")
        #expect(!results.contains(.lost))
        let stitched = try #require(stitcher.image())
        #expect(stitched.height == full.height, "header + all content + footer: \(stitched.height) vs \(full.height)")
        #expect(rowsEqual(stitched, full))
    }

    @Test func aStillFrameAddsNothingAndAJumpIsSkipped() throws {
        let full = page()
        let stitcher = ScrollStitcher()
        stitcher.add(frame(of: full, offset: 0, viewport: 400))
        #expect(stitcher.add(frame(of: full, offset: 0, viewport: 400)) == .unchanged)
        #expect(stitcher.add(frame(of: full, offset: 100, viewport: 400)) == .moved(100))
        // A jump with no overlap can't be placed.
        #expect(stitcher.add(frame(of: full, offset: 1200, viewport: 400)) == .lost)
        #expect(stitcher.image()?.height == 400 + 100)
        // Scrolling back to overlap the last frame that fit carries on from there, nothing lost.
        #expect(stitcher.add(frame(of: full, offset: 180, viewport: 400)) == .moved(80))
        #expect(stitcher.image()?.height == 400 + 180)
    }
}

@Suite struct GuideTests {
    func entries(_ count: Int) -> [GuideEntry] {
        let helper = EditTests()
        return (1...count).map { GuideEntry(image: helper.picture(), pointSize: CGSize(width: 200, height: 100), title: "Step title \($0)",
                                            text: $0 % 2 == 0 ? "Some notes about this step." : "", date: Date(timeIntervalSince1970: 1_800_000_000 + Double($0) * 60)) }
    }

    @Test func everyTemplateRendersAPicture() throws {
        for template in GuideTemplate.allCases {
            let doc = GuideRenderer.Document(template: template, title: "How to do it", subtitle: "October 2026", entries: entries(5))
            let image = try #require(GuideRenderer.image(doc, width: 900, scale: 1))
            #expect(image.width == 900)
            #expect(image.height > 300, "\(template): \(image.height)")
        }
        // Two to a row makes the reference sheet shorter than the steps.
        let steps = GuideRenderer.image(.init(template: .steps, title: "T", entries: entries(6)), scale: 1)!
        let sheet = GuideRenderer.image(.init(template: .reference, title: "T", entries: entries(6)), scale: 1)!
        #expect(sheet.height < steps.height)
    }

    @Test func pdfPagesKeepStepsWhole() throws {
        let doc = GuideRenderer.Document(template: .steps, title: "Long guide", entries: entries(12))
        let pdf = try #require(GuideRenderer.pdf(doc))
        #expect(pdf.starts(with: Data("%PDF".utf8)))
        let pages = GuideRenderer.pageCount(pdf)
        #expect(pages >= 3 && pages <= 12, "\(pages) pages")
        // A picture taller than a page is shrunk to fit one page rather than cut: with the
        // title on page 1, the whole step goes to page 2.
        let tall = GuideEntry(image: EditTests().picture(), pointSize: CGSize(width: 400, height: 3000), title: "Tall")
        #expect(GuideRenderer.pageCount(GuideRenderer.pdf(.init(template: .steps, title: "T", entries: [tall]))!) == 2)
        let blocks = GuideRenderer.layout(.init(template: .steps, title: "T", entries: [tall]), contentWidth: 532, maxImageHeight: 712 - 80)
        #expect(blocks[1].height <= 712, "the step fits on one page")
    }
}
