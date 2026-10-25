import AppKit
import CaptureLensKit
import CryptoKit
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Brings captures made with other tools into the library as they're made: macOS
/// screenshots (⇧⌘3, ⇧⌘4, ⇧⌘5 and the Screenshot app, wherever they're saved) and Snagit's
/// captures. Spotlight finds them; the files stay where they are. Each comes in once, even if
/// it's deleted from the library later, and one another Mac already brought in (from a
/// Desktop in iCloud, say) isn't added again. Pictures only. Photos is never looked at.
@Observable
@MainActor
final class CaptureCollector {
    static let shared = CaptureCollector()

    enum Tool: String, CaseIterable, Identifiable {
        case screenshot, snagit
        var id: String { rawValue }

        var title: String { self == .screenshot ? "macOS screenshots" : "Snagit captures" }
        /// What a capture's source says took it.
        var name: String { self == .screenshot ? "Screenshot" : "Snagit" }
        /// Added to each capture collected, so they're easy to filter.
        var tag: String { self == .screenshot ? "OS Screenshot" : "SnagIt Screenshot" }
        var detail: String {
            self == .screenshot
                ? "Taken with ⇧⌘3, ⇧⌘4, ⇧⌘5 or the Screenshot app, wherever they're saved"
                : "New captures in Snagit's folders, with their apps, web addresses and tags"
        }
    }

    /// How far back to look when a tool is turned on.
    enum Lookback: String, CaseIterable, Identifiable {
        case none, week, month, quarter, all
        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: "Only New Ones"
            case .week: "From the Last 7 Days"
            case .month: "From the Last 30 Days"
            case .quarter: "From the Last 90 Days"
            case .all: "All of Them"
            }
        }

        func since(_ now: Date) -> Date {
            switch self {
            case .none: now
            case .week: now.addingTimeInterval(-7 * 86_400)
            case .month: now.addingTimeInterval(-30 * 86_400)
            case .quarter: now.addingTimeInterval(-90 * 86_400)
            case .all: .distantPast
            }
        }
    }

    /// The tools being collected from on this Mac (a per-Mac choice: it's about this Mac's files).
    private(set) var enabled: Set<Tool> = Set(Tool.allCases.filter { AppDefaults.store.bool(forKey: "collect.\($0.rawValue)") })
    /// Captures brought in from each tool on this Mac.
    private(set) var counts: [Tool: Int] = Dictionary(uniqueKeysWithValues: Tool.allCases.map {
        ($0, AppDefaults.store.integer(forKey: "collect.\($0.rawValue).count"))
    })
    /// Found and waiting to come in.
    private(set) var waiting = 0

    private struct Found {
        let url: URL
        let tool: Tool
        let created: Date
        /// For a screenshot: "selection", "window" or "display", and where on screen it was.
        let captureType: String?
        let rect: CGRect?
        var tries = 0
    }

    @ObservationIgnored private var queries: [Tool: NSMetadataQuery] = [:]
    @ObservationIgnored private var queryObservers: [Tool: [NSObjectProtocol]] = [:]
    /// Files looked at this session, so a changed one isn't looked at twice.
    @ObservationIgnored private var seen: Set<String> = []
    @ObservationIgnored private var found: [Found] = []
    @ObservationIgnored private var working = false
    /// Apps as they came to the front, to tell which one a screenshot was of.
    @ObservationIgnored private var activations: [(date: Date, app: NSRunningApplication)] = []
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    func isOn(_ tool: Tool) -> Bool { enabled.contains(tool) }

    func start() {
        #if !APPSTORE
        // A sandboxed build can't read files it wasn't given.
        for tool in enabled { watch(tool) }
        #endif
    }

    func turnOn(_ tool: Tool, lookingBack lookback: Lookback) {
        AppDefaults.store.set(lookback.since(Date()), forKey: "collect.\(tool.rawValue).since")
        AppDefaults.store.set(true, forKey: "collect.\(tool.rawValue)")
        enabled.insert(tool)
        watch(tool)
    }

    func turnOff(_ tool: Tool) {
        AppDefaults.store.set(false, forKey: "collect.\(tool.rawValue)")
        enabled.remove(tool)
        queries.removeValue(forKey: tool)?.stop()
        queryObservers.removeValue(forKey: tool)?.forEach { NotificationCenter.default.removeObserver($0) }
        found.removeAll { $0.tool == tool }
        seen.removeAll()
        waiting = found.count
    }

    private func since(_ tool: Tool) -> Date {
        AppDefaults.store.object(forKey: "collect.\(tool.rawValue).since") as? Date ?? Date()
    }

    // MARK: - Finding them

    private func watch(_ tool: Tool) {
        guard queries[tool] == nil else { return }
        watchActivations()
        let query = NSMetadataQuery()
        switch tool {
        case .screenshot:
            // macOS marks every screenshot it saves; the file type is checked as they come.
            query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        case .snagit:
            query.predicate = NSPredicate(format: "%K LIKE[c] '*.snagx'", NSMetadataItemFSNameKey)
        }
        query.searchScopes = Self.scopes(for: tool)
        query.notificationBatchingInterval = 1
        let center = NotificationCenter.default
        queryObservers[tool] = [
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    query.disableUpdates()
                    self?.consider(query.results, from: tool)
                    query.enableUpdates()
                }
            },
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] note in
                let added = note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [Any] ?? []
                let changed = note.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [Any] ?? []
                MainActor.assumeIsolated { self?.consider(added + changed, from: tool) }
            },
        ]
        queries[tool] = query
        query.start()
    }

    /// Where to look: the home folder, and wherever screenshots are saved if that's elsewhere.
    private static func scopes(for tool: Tool) -> [Any] {
        #if DEBUG
        // Tests look only in their own folder, never at the real Desktop.
        if let folder = ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_COLLECT_FOLDER"] {
            return [URL(fileURLWithPath: folder, isDirectory: true)]
        }
        #endif
        var scopes: [Any] = [NSMetadataQueryUserHomeScope]
        if tool == .screenshot,
           let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
           !location.isEmpty {
            let folder = URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
            if !folder.path.hasPrefix(NSHomeDirectory()) { scopes.append(folder) }
        }
        return scopes
    }

    private func consider(_ results: [Any], from tool: Tool) {
        guard enabled.contains(tool) else { return }
        let cutoff = since(tool)
        for case let item as NSMetadataItem in results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String, !seen.contains(path),
                  !path.contains(".photoslibrary"), !path.contains("/.Trash/") else { continue }
            let url = URL(fileURLWithPath: path)
            // Hidden: a screenshot still being written.
            guard !url.lastPathComponent.hasPrefix(".") else { continue }
            if tool == .screenshot {
                guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image), type != .pdf else { continue }
            }
            let created = item.value(forAttribute: kMDItemContentCreationDate as String) as? Date
                ?? item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date ?? Date()
            seen.insert(path)
            guard created >= cutoff else { continue }
            var rect: CGRect?
            if let numbers = item.value(forAttribute: "kMDItemScreenCaptureGlobalRect") as? [NSNumber], numbers.count == 4 {
                rect = CGRect(x: numbers[0].doubleValue, y: numbers[1].doubleValue,
                              width: numbers[2].doubleValue, height: numbers[3].doubleValue)
            }
            found.append(Found(url: url, tool: tool, created: created,
                               captureType: item.value(forAttribute: "kMDItemScreenCaptureType") as? String, rect: rect))
        }
        waiting = found.count
        bringIn()
    }

    // MARK: - Bringing them in

    private func bringIn() {
        guard !working, !found.isEmpty else { return }
        working = true
        Task {
            var added: [Tool: Int] = [:]
            while !found.isEmpty {
                let store = LibraryStore.shared
                guard let db = store.db else {
                    // The library isn't open yet (or can't be): try again in a bit.
                    try? await Task.sleep(for: .seconds(10))
                    continue
                }
                let batch = Array(found.prefix(24))
                found.removeFirst(batch.count)
                // A file still being written waits for the next round.
                var ready: [Found] = [], later: [Found] = []
                for var file in batch {
                    let modified = (try? file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    if Date().timeIntervalSince(modified) < 2 && file.tries < 30 {
                        file.tries += 1
                        later.append(file)
                    } else {
                        ready.append(file)
                    }
                }
                let prepared = await withTaskGroup(of: (Found, SnagitImporter.Prepared?).self) { group in
                    for file in ready { group.addTask { (file, Self.prepare(file)) } }
                    var all: [(Found, SnagitImporter.Prepared?)] = []
                    for await result in group { all.append(result) }
                    return all
                }
                var keep: [(SnagitImporter.Prepared, key: String, tool: Tool)] = []
                for (file, capture) in prepared {
                    guard var capture else { continue }
                    let key = file.tool == .snagit ? SnagitImporter.importedKey(capture.fingerprint) : "import.screenshot.\(capture.fingerprint)"
                    guard db.data(forKey: key) == nil, !keep.contains(where: { $0.key == key }), !isInLibrary(capture) else { continue }
                    if file.tool == .screenshot { capture.source = await source(of: file) }
                    capture.tags = LibraryQuery.normalizedTags(capture.tags + [file.tool.tag])
                    keep.append((capture, key, file.tool))
                }
                let ids = store.addImported(keep.map(\.0))
                if !ids.isEmpty {
                    for entry in keep { try? db.set(Data([1]), forKey: entry.key) }
                    for entry in keep { added[entry.tool, default: 0] += 1 }
                    ActivityStore.shared.record(ActivityKey.imported, count: ids.count)
                    nameInBackground(ids)
                }
                found += later
                waiting = found.count
                if !later.isEmpty && later.count == found.count { try? await Task.sleep(for: .seconds(1)) }
            }
            for (tool, count) in added {
                counts[tool, default: 0] += count
                AppDefaults.store.set(counts[tool], forKey: "collect.\(tool.rawValue).count")
            }
            // One at a time needs no fanfare; a batch from turning a tool on gets a word.
            let total = added.values.reduce(0, +)
            if total > 1 { Notice.shared.show("Added \(total) captures from other tools", symbol: "square.and.arrow.down.on.square") }
            working = false
            waiting = found.count
            bringIn()
        }
    }

    /// Already here: the same size, taken at the same moment (brought in on another Mac, or
    /// imported from Snagit there).
    private func isInLibrary(_ capture: SnagitImporter.Prepared) -> Bool {
        LibraryStore.shared.items.contains {
            $0.pixelWidth == capture.pixelWidth && $0.pixelHeight == capture.pixelHeight
                && abs($0.created.timeIntervalSince(capture.created)) < 1
        }
    }

    private func nameInBackground(_ ids: [UUID]) {
        Task {
            for id in ids { await LibraryStore.shared.analyzeNow(id) }
        }
    }

    nonisolated private static func prepare(_ file: Found) -> SnagitImporter.Prepared? {
        switch file.tool {
        case .snagit:
            if case .prepared(let capture) = SnagitImporter.prepare(file.url) { return capture }
            return nil
        case .screenshot:
            guard let data = try? Data(contentsOf: file.url),
                  let reader = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(reader, 0, nil) else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any]
            // A Retina screenshot says 144 dots per inch: two pixels to a point.
            let dpi = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
            let png = UTType(filenameExtension: file.url.pathExtension) == .png ? data : image.pngData
            guard let png else { return nil }
            let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let kind: CaptureItem.Kind = switch file.captureType {
            case "selection": .region
            case "window": .window
            case "display": .screen
            default: .imported
            }
            return SnagitImporter.Prepared(fingerprint: fingerprint, png: png, thumbnail: image.thumbnail().pngData,
                                           pixelWidth: image.width, pixelHeight: image.height, scale: max(1, dpi / 72),
                                           annotations: [], created: file.created, source: .init(tool: Tool.screenshot.name),
                                           tags: [], favorite: false, text: "", editable: false, hadMarkup: false,
                                           difference: nil, kind: kind)
        }
    }

    // MARK: - Where a screenshot was taken

    private func watchActivations() {
        guard activationObserver == nil else { return }
        if let front = NSWorkspace.shared.frontmostApplication { activations.append((Date(), front)) }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self?.activations.append((Date(), app))
                if let count = self?.activations.count, count > 50 { self?.activations.removeFirst(count - 50) }
            }
        }
    }

    /// Apps that are part of taking the screenshot, not what it's of.
    private static let screenshotApps: Set<String> = ["com.apple.screencaptureui", "com.apple.screenshot.launcher", "com.apple.Screenshot"]

    /// The app (and, for a window or an area, the window) a screenshot was of, when it was
    /// taken in the last two minutes; macOS doesn't record it. An older one says only what took it.
    private func source(of file: Found) async -> CaptureItem.Source {
        var source = CaptureItem.Source(tool: Tool.screenshot.name)
        guard Date().timeIntervalSince(file.created) < 120 else { return source }
        let front = activations.last {
            $0.date <= file.created && $0.app.processIdentifier != getpid()
                && !Self.screenshotApps.contains($0.app.bundleIdentifier ?? "")
        }?.app
        if file.captureType != "display", let rect = file.rect {
            // Spotlight's rectangle is from the top left of the main screen; windows' from the bottom left.
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            let center = CGPoint(x: rect.midX, y: mainHeight - rect.midY)
            if let window = ScreenWindow.onScreen().first(where: { $0.frame.contains(center) }) {
                source = SourceInfo.describe(frame: nil, windows: [], window: window, display: nil)
                source.tool = Tool.screenshot.name
            }
        }
        if source.appName == nil, let front {
            source.appName = front.localizedName
            source.bundleID = front.bundleIdentifier
        }
        // The page is still showing only if the browser is still in front.
        if Preferences.shared.recordWebAddress, let bundleID = source.bundleID, SourceInfo.isBrowser(bundleID),
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID,
           let page = await SourceInfo.webPage(bundleID: bundleID) {
            source.url = page.url
            source.pageTitle = page.title
        }
        return source
    }
}
