import AppKit
@preconcurrency import AVFoundation
import CaptureLensKit
import Observation
import SwiftUI

/// Moves a Snagit library into CaptureLens: every capture in Snagit's folders (its autosave
/// folder and wherever its library lives, such as a OneDrive folder), with its date, app,
/// window, web address and tags, and its markup editable where CaptureLens has the same tool.
/// Videos are copied to a folder of their own and stay on this Mac. Nothing in Snagit's
/// folders is changed, and the Photos library is never looked at.
@Observable
@MainActor
final class SnagitImporter {
    static let shared = SnagitImporter()

    struct Folder: Identifiable, Equatable {
        var id: URL { url }
        let url: URL
        var captures = 0
        var videos = 0
        var videoBytes: Int64 = 0
    }

    struct Summary: Equatable {
        var imported = 0
        var editable = 0
        var asDrawn = 0
        var empty = 0
        var duplicates = 0
        var alreadyImported = 0
        var failed = 0
        var videos = 0
    }

    enum Phase: Equatable { case idle, scanning, ready, importing, done }

    private(set) var phase = Phase.idle
    private(set) var folders: [Folder] = []
    private(set) var done = 0
    private(set) var total = 0
    private(set) var summary = Summary()
    /// Imported captures still waiting to be named.
    private(set) var naming = 0
    var includeVideos = true
    var nameCaptures = true
    var videoFolder: URL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appending(path: "CaptureLens Imports", directoryHint: .isDirectory)
    @ObservationIgnored private var cancelled = false

    /// How different (0–255, per 8 × 8 block) CaptureLens's drawing of converted markup may be
    /// from Snagit's before the capture comes in as Snagit drew it instead.
    /// Tuned on a real library: conversions that drew right scored up to 26, ones that didn't
    /// 40 and up.
    nonisolated static let matchLimit = 32.0

    // MARK: - Finding Snagit's folders

    func scan() {
        guard phase != .importing else { return }
        phase = .scanning
        Task {
            let found = await Self.findFolders()
            folders = await Task.detached(priority: .userInitiated) { found.map(Self.count) }.value
                .filter { $0.captures > 0 || $0.videos > 0 }
            phase = .ready
        }
    }

    func add(_ url: URL) {
        guard !folders.contains(where: { $0.url == url }) else { return }
        Task {
            let folder = await Task.detached { Self.count(url) }.value
            folders.append(folder)
            if phase == .idle || phase == .done { phase = .ready }
        }
    }

    func remove(_ url: URL) { folders.removeAll { $0.url == url } }

    /// "~/Pictures/Snagit/…", for showing.
    static func shortPath(_ url: URL) -> String {
        var path = url.path
        #if DEBUG
        // The screenshots' made-up folders read like real ones.
        if let fake = ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_SHOTS"].flatMap({ _ in path.range(of: "CaptureLens Shot Snagit/") }) {
            path = NSHomeDirectory() + "/" + path[fake.upperBound...].replacingOccurrences(of: "OneDrive/", with: "Library/CloudStorage/OneDrive-Personal/")
        }
        if ProcessInfo.processInfo.environment["CAPTURELENS_DEBUG_SHOTS"] != nil, path.contains("CaptureLens Shot Videos") {
            path = NSHomeDirectory() + "/Movies/CaptureLens Imports"
        }
        #endif
        return path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    #if DEBUG
    /// Exactly these folders, counted now, for the self-test.
    func debugUse(_ urls: [URL], videoFolder: URL) {
        folders = urls.map(Self.count)
        self.videoFolder = videoFolder
        nameCaptures = false
        phase = .ready
    }

    var debugWindow: NSWindow? { NSApp.windows.first { $0.title == "Import from Snagit" } }
    #endif

    /// Snagit's usual places, and any other folder of Snagit captures Spotlight knows about.
    static func findFolders() async -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        let pictures = home.appending(path: "Pictures/Snagit")
        if let inside = try? fm.contentsOfDirectory(at: pictures, includingPropertiesForKeys: nil) {
            candidates += inside.filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        let clouds = home.appending(path: "Library/CloudStorage")
        for service in (try? fm.contentsOfDirectory(at: clouds, includingPropertiesForKeys: nil)) ?? [] {
            for name in (try? fm.contentsOfDirectory(atPath: service.path)) ?? [] where name.localizedCaseInsensitiveContains("snagit") {
                candidates.append(service.appending(path: name))
            }
        }
        let iCloud = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        for name in (try? fm.contentsOfDirectory(atPath: iCloud.path)) ?? [] where name.localizedCaseInsensitiveContains("snagit") {
            candidates.append(iCloud.appending(path: name))
        }
        candidates += await spotlightFolders()
        var seen = Set<String>()
        return candidates.map(\.standardizedFileURL).filter { url in
            let path = url.path
            guard !path.contains(".photoslibrary"), !path.contains("/.Trash"), !url.lastPathComponent.hasPrefix("."),
                  url.lastPathComponent != "library-conversion-backup" else { return false }
            return seen.insert(path).inserted
        }
    }

    /// Folders holding .snagx files, from Spotlight (it never opens the Photos library).
    private static func spotlightFolders() async -> [URL] {
        await withCheckedContinuation { continuation in
            let query = NSMetadataQuery()
            query.predicate = NSPredicate(format: "%K LIKE[c] '*.snagx'", NSMetadataItemFSNameKey)
            query.searchScopes = [NSMetadataQueryUserHomeScope]
            nonisolated(unsafe) var observer: NSObjectProtocol?
            nonisolated(unsafe) var finished = false
            func finish() {
                guard !finished else { return }
                finished = true
                query.stop()
                if let observer { NotificationCenter.default.removeObserver(observer) }
                var folders = Set<URL>()
                for case let item as NSMetadataItem in query.results {
                    if let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                        folders.insert(URL(fileURLWithPath: path).deletingLastPathComponent())
                    }
                }
                continuation.resume(returning: Array(folders))
            }
            observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { _ in
                MainActor.assumeIsolated { finish() }
            }
            query.start()
            // Spotlight off, or very slow: go with what the usual places found.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { MainActor.assumeIsolated { finish() } }
        }
    }

    nonisolated static func count(_ url: URL) -> Folder {
        var folder = Folder(url: url)
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for file in files {
            switch file.pathExtension.lowercased() {
            case "snagx": folder.captures += 1
            case "mp4", "mov", "m4v":
                folder.videos += 1
                folder.videoBytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            default: break
            }
        }
        return folder
    }

    // MARK: - Importing

    func start() {
        guard phase == .ready, !folders.isEmpty else { return }
        cancelled = false
        summary = Summary()
        done = 0
        phase = .importing
        let urls = folders.map(\.url)
        Task {
            let fm = FileManager.default
            var captures: [URL] = [], movies: [URL] = []
            for folder in urls {
                for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                    switch file.pathExtension.lowercased() {
                    case "snagx": captures.append(file)
                    case "mp4", "mov", "m4v": movies.append(file)
                    default: break
                    }
                }
            }
            // Oldest first, so the library ends up newest first like everything else.
            captures.sort { $0.lastPathComponent < $1.lastPathComponent }
            total = captures.count + (includeVideos ? movies.count : 0)
            await importCaptures(captures)
            if includeVideos && !cancelled { await importVideos(movies) }
            phase = .done
            Notice.shared.show("Imported \(summary.imported) from Snagit", symbol: "square.and.arrow.down.on.square")
        }
    }

    func cancel() { cancelled = true }

    func reset() {
        phase = folders.isEmpty ? .idle : .ready
        summary = Summary()
        done = 0
        total = 0
    }

    private func importCaptures(_ files: [URL]) async {
        let store = LibraryStore.shared
        guard let db = store.db else { return }
        var seen = Set<String>()
        var batch: [Prepared] = []
        var named: [UUID] = []
        // A few at a time off the main thread; the library takes them in batches.
        let chunks = stride(from: 0, to: files.count, by: 24).map { Array(files[$0..<min($0 + 24, files.count)]) }
        for chunk in chunks {
            if cancelled { break }
            let results = await withTaskGroup(of: Outcome.self) { group in
                for file in chunk { group.addTask { Self.prepare(file) } }
                var all: [Outcome] = []
                for await result in group { all.append(result) }
                return all
            }
            for result in results {
                done += 1
                switch result {
                case .empty: summary.empty += 1
                case .failed: summary.failed += 1
                case .prepared(let prepared):
                    if seen.contains(prepared.fingerprint) { summary.duplicates += 1; continue }
                    seen.insert(prepared.fingerprint)
                    if db.data(forKey: Self.importedKey(prepared.fingerprint)) != nil { summary.alreadyImported += 1; continue }
                    batch.append(prepared)
                }
            }
            if batch.count >= 48 || chunk == chunks.last || cancelled {
                let ids = store.addImported(batch)
                for prepared in batch { try? db.set(Data([1]), forKey: Self.importedKey(prepared.fingerprint)) }
                summary.imported += ids.count
                ActivityStore.shared.record(ActivityKey.imported, count: ids.count)
                summary.editable += batch.filter(\.editable).count
                summary.asDrawn += batch.filter { !$0.editable && $0.hadMarkup }.count
                named += ids
                batch.removeAll()
            }
        }
        if nameCaptures { nameInBackground(named) }
    }

    static func importedKey(_ fingerprint: String) -> String { "import.snagit.\(fingerprint)" }

    /// Names the imported captures from what's in them, one at a time.
    private func nameInBackground(_ ids: [UUID]) {
        naming += ids.count
        Task {
            for id in ids {
                await LibraryStore.shared.analyzeNow(id)
                naming -= 1
            }
        }
    }

    // MARK: Videos

    private func importVideos(_ files: [URL]) async {
        let store = LibraryStore.shared
        guard let db = store.db else { return }
        try? FileManager.default.createDirectory(at: videoFolder, withIntermediateDirectories: true)
        var seen = Set<String>()
        for file in files {
            if cancelled { break }
            done += 1
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let key = "import.snagit.video.\(file.lastPathComponent.lowercased())-\(size)"
            guard seen.insert(key).inserted else { summary.duplicates += 1; continue }
            guard db.data(forKey: key) == nil else { summary.alreadyImported += 1; continue }
            var target = videoFolder.appending(path: file.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = videoFolder.appending(path: "\(file.deletingPathExtension().lastPathComponent) \(n).\(file.pathExtension)")
                n += 1
            }
            do {
                // On the same disk this is a clone: instant, and it takes no extra room until changed.
                try await Task.detached(priority: .utility) { try FileManager.default.copyItem(at: file, to: target) }.value
                let asset = AVURLAsset(url: target)
                let duration = try await asset.load(.duration).seconds
                let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
                guard let poster = await VideoStore.frame(of: asset, at: min(0.5, duration / 2), exact: false) else { throw GrabError(message: "No picture") }
                let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                var info = VideoInfo(duration: duration, hasAudio: hasAudio)
                info.staysOnMac = true
                guard var item = store.add(image: poster, kind: .video, scale: 1, source: .init(), cursor: nil, created: created,
                                           video: info, analyze: false) else { throw GrabError(message: "Couldn't save") }
                VideoStore.shared.attach(target, to: item.id)
                item.name = CaptureNaming.clean(file.deletingPathExtension().lastPathComponent) ?? item.name
                item.nameIsAutomatic = false
                store.update(item)
                try? db.set(Data([1]), forKey: key)
                summary.videos += 1
                summary.imported += 1
                ActivityStore.shared.record(ActivityKey.imported)
            } catch {
                try? FileManager.default.removeItem(at: target)
                summary.failed += 1
                NSLog("CaptureLens: couldn't import a Snagit video: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - One capture

    struct Prepared: Sendable {
        let fingerprint: String
        let png: Data
        let thumbnail: Data?
        let pixelWidth: Int
        let pixelHeight: Int
        let scale: Double
        let annotations: [Annotation]
        let created: Date
        var source: CaptureItem.Source
        var tags: [String]
        let favorite: Bool
        let text: String
        /// Came with editable marks.
        let editable: Bool
        /// Had markup at all (editable or drawn in).
        let hadMarkup: Bool
        /// How far CaptureLens's drawing was from Snagit's (for tuning; nil if not compared).
        let difference: Double?
        /// What it comes in as: a macOS screenshot keeps whether it was an area, a window or
        /// the screen.
        var kind = CaptureItem.Kind.imported
    }

    enum Outcome: Sendable {
        case prepared(Prepared)
        case empty
        case failed
    }

    /// Reads a .snagx and decides how it comes in: the picture with editable marks when they
    /// draw the way Snagit drew them, otherwise Snagit's own drawing.
    nonisolated static func prepare(_ file: URL) -> Outcome {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped),
              let capture = try? SnagitImport.read(data, rtf: richText) else { return .failed }
        if capture.isEmpty { return .empty }
        guard let fingerprint = capture.fingerprint else { return .failed }
        let created = capture.created ?? ((try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date())
        let hadMarkup = !capture.annotations.isEmpty || !capture.unsupported.isEmpty
        let picture = capture.picture.flatMap(AnnotationRenderer.image(from:))
        let drawn = capture.drawn.flatMap(AnnotationRenderer.image(from:))

        var source = capture.source
        source.tool = "Snagit"
        func make(_ png: Data, _ image: CGImage, annotations: [Annotation], editable: Bool, difference: Double?) -> Outcome {
            let scale = capture.canvas.width > 0 ? Double(image.width) / capture.canvas.width : capture.scale
            let shown = annotations.isEmpty ? image : (AnnotationRenderer.flatten(base: image, scale: scale, annotations: annotations, cursor: nil) ?? image)
            return .prepared(Prepared(fingerprint: fingerprint, png: png, thumbnail: shown.thumbnail().pngData, pixelWidth: image.width,
                                      pixelHeight: image.height, scale: max(scale, 0.1), annotations: annotations, created: created,
                                      source: source, tags: capture.tags, favorite: capture.favorite,
                                      text: capture.recognizedText, editable: editable, hadMarkup: hadMarkup, difference: difference))
        }

        if let picture, let png = capture.picture, capture.pictureFillsCanvas, !hadMarkup {
            return make(png, picture, annotations: [], editable: false, difference: nil)
        }
        if let picture, let png = capture.picture, capture.convertible {
            let scale = capture.canvas.width > 0 ? Double(picture.width) / capture.canvas.width : capture.scale
            guard let ours = AnnotationRenderer.flatten(base: picture, scale: scale, annotations: capture.annotations, cursor: nil) else { return .failed }
            // Without Snagit's drawing to check against, trust the conversion.
            guard let drawn else { return make(png, picture, annotations: capture.annotations, editable: true, difference: nil) }
            let difference = ImageCompare.difference(ours, drawn)
            if difference <= matchLimit {
                return make(png, picture, annotations: capture.annotations, editable: true, difference: difference)
            }
            if let drawnPNG = capture.drawn {
                return make(drawnPNG, drawn, annotations: [], editable: false, difference: difference)
            }
        }
        if let drawn, let png = capture.drawn { return make(png, drawn, annotations: [], editable: false, difference: nil) }
        if let picture, let png = capture.picture { return make(png, picture, annotations: [], editable: false, difference: nil) }
        return .failed
    }

    /// Snagit keeps text as RTF.
    nonisolated static func richText(_ data: Data) -> SnagitImport.RichText? {
        guard let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                 documentAttributes: nil), text.length > 0 else { return nil }
        let attributes = text.attributes(at: 0, effectiveRange: nil)
        let font = attributes[.font] as? NSFont
        let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB)
        return (text.string, font.map { Double($0.pointSize) },
                color.map { RGBA(Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent), Double($0.alphaComponent)) },
                font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }
}

extension LibraryStore {
    /// Adds imported captures in one go (sync and naming follow separately).
    func addImported(_ prepared: [SnagitImporter.Prepared]) -> [UUID] {
        guard let db, !prepared.isEmpty else { return [] }
        let rows: [(CaptureItem, image: Data?, thumbnail: Data?)] = prepared.map { p in
            var item = CaptureItem(created: p.created, kind: p.kind, name: CaptureNaming.fallback(source: p.source, date: p.created),
                                   tags: p.tags, recognizedText: p.text, favorite: p.favorite, source: p.source,
                                   pixelWidth: p.pixelWidth, pixelHeight: p.pixelHeight, scale: p.scale,
                                   annotations: p.annotations, origin: DeviceIdentity.deviceID)
            item.modified = Date()
            return (item, image: p.png, thumbnail: p.thumbnail)
        }
        do { try db.upsert(rows) } catch {
            NSLog("CaptureLens: couldn't save imported captures: \(error.localizedDescription)")
            return []
        }
        insertImported(rows.map(\.0))
        let ids = Set(rows.map(\.0.id))
        LibrarySync.shared.localDidChange(ids)
        FolderSync.shared.localDidChange(ids)
        return rows.map(\.0.id)
    }
}

// MARK: - The window

/// Import from Snagit: the folders found, what's in them, and the import itself.
@MainActor
final class SnagitImportWindow: NSObject {
    static let shared = SnagitImportWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "Import from Snagit"
            window.isReleasedWhenClosed = false
            let hosting = NSHostingController(rootView: SnagitImportView())
            hosting.sizingOptions = [.preferredContentSize]
            window.contentViewController = hosting
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        let importer = SnagitImporter.shared
        if importer.phase == .idle || importer.phase == .done { importer.reset(); importer.scan() }
    }
}

private struct SnagitImportView: View {
    @State private var importer = SnagitImporter.shared

    private var captures: Int { importer.folders.reduce(0) { $0 + $1.captures } }
    private var videos: Int { importer.folders.reduce(0) { $0 + $1.videos } }
    private var videoBytes: Int64 { importer.folders.reduce(0) { $0 + $1.videoBytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bring your Snagit captures into CaptureLens, with their dates, apps, web addresses and tags. Markup comes in editable where CaptureLens has the same tool; otherwise the capture comes in as Snagit drew it. Snagit's files aren't changed.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            switch importer.phase {
            case .idle, .scanning:
                HStack { ProgressView().controlSize(.small); Text("Looking for Snagit's folders…") }
            case .ready:
                ready
            case .importing:
                importing
            case .done:
                done
            }
        }
        .padding(20)
        .frame(width: 560, alignment: .topLeading)
        .frame(minHeight: 200, alignment: .top)
    }

    @ViewBuilder private var ready: some View {
        GroupBox("Folders") {
            VStack(alignment: .leading, spacing: 6) {
                if importer.folders.isEmpty {
                    Text("No Snagit captures were found. Add the folder where Snagit keeps them.").foregroundStyle(.secondary)
                }
                ForEach(importer.folders) { folder in
                    HStack {
                        Image(systemName: "folder")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(SnagitImporter.shortPath(folder.url)).lineLimit(1).truncationMode(.middle)
                            Text("\(folder.captures) capture file\(folder.captures == 1 ? "" : "s")\(folder.videos > 0 ? ", \(folder.videos) video\(folder.videos == 1 ? "" : "s")" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { importer.remove(folder.url) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Leave this folder out")
                    }
                }
                Button("Add Folder…") { chooseFolder() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        if videos > 0 {
            Toggle(isOn: $importer.includeVideos) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bring in \(videos) video\(videos == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: videoBytes, countStyle: .file)))")
                    Text("Copied to \(SnagitImporter.shortPath(importer.videoFolder)). They play in the library but stay on this Mac: they never sync. On the same disk, copies take no extra room.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if importer.includeVideos {
                Button("Choose Video Folder…") { chooseVideoFolder() }.controlSize(.small)
            }
        }
        Toggle(isOn: $importer.nameCaptures) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Name captures from what's in them")
                Text("Done on this Mac in the background after the import; it can take a while for thousands of captures.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Text("Empty placeholders Snagit left (with no picture) and captures already imported are skipped. The same capture in two folders comes in once.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
            Button("Look Again") { importer.scan() }
            Spacer()
            Button("Import \(captures) Capture Files") { importer.start() }
                .keyboardShortcut(.defaultAction)
                .disabled(importer.folders.isEmpty)
        }
    }

    @ViewBuilder private var importing: some View {
        ProgressView(value: Double(importer.done), total: Double(max(importer.total, 1))) {
            Text("Importing \(importer.done) of \(importer.total)…")
        }
        Text("\(importer.summary.imported) added so far").font(.callout).foregroundStyle(.secondary)
        HStack {
            Spacer()
            Button("Stop") { importer.cancel() }
        }
    }

    @ViewBuilder private var done: some View {
        let s = importer.summary
        Label("Imported \(s.imported) from Snagit", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            row("With editable markup", s.editable)
            row("Markup drawn in, as in Snagit", s.asDrawn)
            row("Videos", s.videos)
            row("Empty placeholders skipped", s.empty)
            row("Duplicates skipped", s.duplicates)
            row("Already imported", s.alreadyImported)
            if s.failed > 0 { row("Couldn't be read", s.failed) }
        }
        if importer.naming > 0 {
            HStack { ProgressView().controlSize(.small); Text("Naming \(importer.naming) captures in the background…").foregroundStyle(.secondary) }
        }
        HStack {
            Spacer()
            Button("Show Library") { LibraryWindow.shared.show() }.keyboardShortcut(.defaultAction)
        }
    }

    private func row(_ title: String, _ value: Int) -> some View {
        GridRow {
            Text(title)
            Text(value.formatted()).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder of Snagit captures (.snagx files)"
        if panel.runModal() == .OK, let url = panel.url { importer.add(url) }
    }

    private func chooseVideoFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose where imported videos are kept"
        if panel.runModal() == .OK, let url = panel.url { importer.videoFolder = url }
    }
}
