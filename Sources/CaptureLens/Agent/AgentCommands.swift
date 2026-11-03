import AppKit
import CaptureLensKit

/// Everything an agent can do in SnagAnything. Add a command here and the CLI, `help`, and
/// the MCP tools all get it. Each `run` is on the main actor and calls the same code as the
/// library window, the menus and the snaganything:// actions, so the window updates live.
enum AgentCommands {
    static let all: [AgentCommand] = [
        AgentCommand(name: "status", summary: "Show the version, whether the library is locked (`libraryLocked`), how many captures it holds (`captures`), and whether a capture or recording is under way.",
                     example: "snag status --json", readOnly: true) { _ in
            let store = LibraryStore.shared
            let lock = LibraryLock.shared
            return ["app": AppInfo.name, "version": AppInfo.version,
                    "libraryLocked": lock.isLocked, "lockEnabled": lock.isEnabled,
                    "captures": store.items.count, "unreadable": store.unreadable, "encrypted": store.isEncrypted,
                    "capturing": CaptureEngine.shared.isBusy, "recording": ScreenRecorder.shared.isActive,
                    "screenRecordingAllowed": ScreenAccess.granted,
                    "libraryWindowOpen": LibraryWindow.shared.window?.isVisible == true]
        },

        // MARK: Library

        AgentCommand(name: "captures list", summary: "List captures, newest first, narrowed like the library's search and filters. Returns `captures` (id, name, kind, created in UTC, app, tags, favorite, pinned, width, height), `total` (every match, whatever --limit is) and `nextOffset` when there are more.",
                     params: [.init(name: "search", help: "words in the name, notes, tags, app, web page or the text read from the picture. Also tag:x, app:x, site:x"),
                              .init(name: "kind", help: "region, window, screen, imported, video or text"),
                              .init(name: "tag", help: "only captures with this tag"),
                              .init(name: "app", help: "only captures from this app (its name or bundle ID)"),
                              .init(name: "website", help: "only captures of this site, like apple.com"),
                              .init(name: "date", help: "today, yesterday, week (last 7 days), month (last 30 days) or year, in this Mac's time zone"),
                              .init(name: "favorites", kind: .boolean, help: "only favorites"),
                              .init(name: "pinned", kind: .boolean, help: "only pinned captures"),
                              .init(name: "notes", kind: .boolean, help: "only captures with notes"),
                              .init(name: "sort", help: "newest (default), oldest or name"),
                              .init(name: "limit", kind: .integer, help: "at most this many (default 50)"),
                              .init(name: "offset", kind: .integer, help: "skip this many, for the next page")],
                     example: "snag captures list --search invoice --kind window --limit 10 --json", readOnly: true) { args in
            try unlocked()
            let items = LibraryQuery.filter(LibraryStore.shared.items, with: try filter(args), sort: try sort(args))
            return try page(items, args) { summary($0) }
        },
        AgentCommand(name: "captures show", summary: "Show one capture: its name, tags, notes, where it came from, size and layers.",
                     params: [idParam],
                     example: "snag captures show 3f2a9c1e --json", readOnly: true) { args in
            detail(try find(args))
        },
        AgentCommand(name: "captures text", summary: "Show the text read from a capture's picture.",
                     params: [idParam],
                     example: "snag captures text 3f2a9c1e --json", readOnly: true) { args in
            let item = try find(args)
            return ["id": short(item.id), "name": item.name, "text": item.recognizedText,
                    "analyzing": LibraryStore.shared.analyzing.contains(item.id)]
        },
        AgentCommand(name: "captures export", summary: "Save a capture as a PNG (a video as an MP4), with its markup and adjustments drawn in, as Copy and drag do.",
                     params: [idParam,
                              .init(name: "to", kind: .path, required: true, help: "a file, or a folder to save it in under the capture's name"),
                              .init(name: "original", kind: .boolean, help: "the picture as taken, without markup or adjustments"),
                              .init(name: "overwrite", kind: .boolean, help: "replace a file that's already there")],
                     example: "snag captures export 3f2a9c1e --to ~/Desktop --json") { args in
            let item = try find(args)
            return try export(item, to: try absolutePath(args.required("to")), original: try args.bool("original") == true,
                              overwrite: try args.bool("overwrite") == true)
        },
        AgentCommand(name: "captures update", summary: "Change a capture's name, notes, tags, favorite or pin. Only the options you give change.",
                     params: [idParam,
                              .init(name: "name", help: "a new name"),
                              .init(name: "notes", help: "new notes, replacing the old ones (\"\" clears them)"),
                              .init(name: "add-tags", help: "tags to add, separated by commas"),
                              .init(name: "remove-tags", help: "tags to remove, separated by commas"),
                              .init(name: "favorite", kind: .boolean, help: "true or false"),
                              .init(name: "pinned", kind: .boolean, help: "true or false: keep it in the library's Pinned list")],
                     example: "snag captures update 3f2a9c1e --name \"Login error\" --add-tags bug,login --json") { args in
            let store = LibraryStore.shared
            let before = try find(args)
            let id = before.id
            if let name = args.string("name") {
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentError.invalid("--name can't be empty") }
                store.rename(id, to: name)
            }
            if let notes = args.string("notes"), var item = store.entry(id), item.notes != notes {
                item.notes = notes
                store.update(item)
            }
            let add = list(args.string("add-tags")), remove = list(args.string("remove-tags"))
            if !add.isEmpty || !remove.isEmpty { store.setTags([id], add: add, remove: remove) }
            if let favorite = try args.bool("favorite"), store.entry(id)?.favorite != favorite { store.toggleFavorite([id]) }
            if let pinned = try args.bool("pinned"), store.entry(id)?.pinned != pinned { store.togglePinned([id]) }
            guard let after = store.entry(id) else { throw AgentError.notFound("the capture went away while it was changing") }
            var result = detail(after)
            result["changed"] = after != before
            return result
        },
        AgentCommand(name: "captures import", summary: "Add a picture, or every picture in a folder, to the library, as dropping them on the Dock icon does.",
                     params: [.init(name: "path", kind: .path, required: true, positional: true, help: "a picture file, or a folder of them")],
                     example: "snag captures import ~/Downloads/diagram.png --json") { args in
            try unlocked()
            let url = URL(fileURLWithPath: try absolutePath(args.required("path")))
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
                throw AgentError.notFound("nothing at \(url.path)")
            }
            let files = isFolder.boolValue
                ? ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                : [url]
            let before = Set(LibraryStore.shared.items.map(\.id))
            let count = LibraryStore.shared.importFiles(files)
            guard count > 0 else { throw AgentError.invalid("no pictures there: SnagAnything imports PNG, JPEG, HEIC, TIFF and other image files") }
            let added = LibraryStore.shared.items.filter { !before.contains($0.id) }
            return ["imported": count, "captures": added.map { summary($0) }]
        },
        AgentCommand(name: "captures delete", summary: "Delete a capture from the library, on every Mac that syncs it. Without --yes it only shows what it would delete.",
                     params: [idParam],
                     example: "snag captures delete 3f2a9c1e --yes --json", destructive: true) { args in
            let item = try find(args)
            guard args.confirmed else {
                return ["wouldDelete": summary(item),
                        "hint": "add --yes to delete it. It can't be undone, and it goes from every Mac that syncs this library"]
            }
            LibraryStore.shared.delete([item.id])
            return ["deleted": short(item.id), "name": item.name]
        },
        AgentCommand(name: "tags list", summary: "List the tags in use, with how many captures have each. Returns `tags` (tag, count) and `total`.",
                     example: "snag tags list --json", readOnly: true) { _ in
            try unlocked()
            let tags = LibraryStore.shared.facets.tags
            return ["tags": tags.map { ["tag": $0.tag, "count": $0.count] as JSONObject }, "total": tags.count]
        },
        AgentCommand(name: "library open", summary: "Bring up the library window, with a capture selected if you give one. A locked library asks the person to unlock it.",
                     params: [.init(name: "id", positional: true, help: "a capture to select (the first 8 characters of its id are enough)")],
                     example: "snag library open 3f2a9c1e --json") { args in
            let id = try args.string("id").map { try find($0).id }
            LibraryWindow.shared.show(select: id)
            return ["open": true, "selected": id.map(short) ?? NSNull(), "locked": LibraryLock.shared.isLocked]
        },

        // MARK: Capturing

        AgentCommand(name: "presets list", summary: "List the capture presets from Settings › Presets.",
                     example: "snag presets list --json", readOnly: true) { _ in
            let presets = Preferences.shared.presets
            return ["presets": presets.map { preset -> JSONObject in
                // By name, as `capture start --preset` takes them: the built-in ones' ids share a start.
                ["name": preset.name, "mode": modeName(preset.mode), "delay": preset.delay,
                 "shortcut": preset.hotKey?.display ?? ""]
            }, "total": presets.count]
        },
        AgentCommand(name: "capture start", summary: "Start a capture, as the menu bar menu does. Most modes wait for the person to pick a window or drag an area; screen and again capture at once. The capture lands in the library: find it with `snag captures list --limit 1`.",
                     params: [.init(name: "mode", help: "area, window, window-or-area, screen, scrolling, text, video or again (the area captured last). Default: the first preset"),
                              .init(name: "preset", help: "a preset's name instead of a mode (see `snag presets list`)"),
                              .init(name: "delay", kind: .integer, help: "seconds to count down first, 0–60")],
                     example: "snag capture start --mode screen --delay 3 --json") { args in
            try startCapture(args)
        },
    ]

    // MARK: Finding captures

    static let idParam = AgentCommand.Param(name: "id", required: true, positional: true,
                                            help: "the capture's id (the first 8 characters are enough)")

    static func short(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }

    @MainActor
    static func unlocked() throws {
        if LibraryLock.shared.isLocked { throw AgentError.locked }
    }

    @MainActor
    static func find(_ args: Args) throws -> CaptureItem { try find(try args.required("id")) }

    /// The capture whose id starts with `prefix`.
    @MainActor
    static func find(_ prefix: String) throws -> CaptureItem {
        try unlocked()
        let key = prefix.lowercased()
        let matches = LibraryStore.shared.items.filter { $0.id.uuidString.lowercased().hasPrefix(key) }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw AgentError.notFound("no capture with id \(prefix). Run `snag captures list`")
        default: throw AgentError.invalid("\(matches.count) captures have ids starting \(prefix). Give more of the id")
        }
    }

    // MARK: Results

    static func summary(_ item: CaptureItem) -> JSONObject {
        var json: JSONObject = ["id": short(item.id), "name": item.name, "kind": item.kind.rawValue,
                                "created": JSON.date(item.created), "app": item.source.appName ?? "", "tags": item.tags,
                                "favorite": item.favorite, "pinned": item.pinned,
                                "width": item.pixelWidth, "height": item.pixelHeight]
        if let website = item.source.website { json["website"] = website }
        return json
    }

    static func detail(_ item: CaptureItem) -> JSONObject {
        var json = summary(item)
        json["fullID"] = item.id.uuidString
        json["modified"] = JSON.date(item.modified)
        json["notes"] = item.notes
        json["nameIsAutomatic"] = item.nameIsAutomatic
        json["scale"] = item.scale
        json["markup"] = item.annotations.count
        json["adjusted"] = !item.edits.isEmpty
        json["pointerShown"] = item.cursor?.visible == true
        json["textLength"] = item.recognizedText.count
        var source: JSONObject = [:]
        let s = item.source
        for (key, value) in [("app", s.appName), ("bundleID", s.bundleID), ("windowTitle", s.windowTitle), ("url", s.url),
                             ("pageTitle", s.pageTitle), ("display", s.displayName), ("tool", s.tool)] {
            if let value, !value.isEmpty { source[key] = value }
        }
        json["source"] = source
        if let video = item.video { json["seconds"] = video.duration }
        return json
    }

    static func page<T>(_ all: [T], _ args: Args, _ json: (T) -> JSONObject) throws -> JSONObject {
        let limit = try args.int("limit", default: 50)
        let offset = try args.int("offset", default: 0)
        guard limit > 0, offset >= 0 else { throw AgentError.usage("--limit must be 1 or more, and --offset 0 or more") }
        let slice = all.dropFirst(offset).prefix(limit)
        var result: JSONObject = ["captures": slice.map(json), "total": all.count]
        if offset + slice.count < all.count { result["nextOffset"] = offset + slice.count }
        return result
    }

    // MARK: Options

    static func list(_ text: String?) -> [String] {
        (text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// MCP clients send paths as they are, so they must already be absolute.
    static func absolutePath(_ path: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw AgentError.usage("\"\(path)\" isn't a full path. Give one that starts with / or ~") }
        return expanded
    }

    @MainActor
    static func filter(_ args: Args) throws -> LibraryFilter {
        var filter = LibraryFilter()
        filter.text = args.string("search") ?? ""
        if let kind = args.string("kind") {
            guard let value = CaptureItem.Kind(rawValue: kind.lowercased()) else {
                throw AgentError.usage("--kind must be one of \(CaptureItem.Kind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            filter.kinds = [value]
        }
        if let tag = args.string("tag") { filter.tags = [tag] }
        if let app = args.string("app") {
            // The library keys apps by bundle ID (or name); people know them by name.
            let match = LibraryStore.shared.facets.apps.first {
                $0.key.caseInsensitiveCompare(app) == .orderedSame || $0.name.caseInsensitiveCompare(app) == .orderedSame
            }
            filter.apps = [match?.key ?? app]
        }
        if let site = args.string("website") {
            let host = site.lowercased()
            filter.websites = [host.hasPrefix("www.") ? String(host.dropFirst(4)) : host]
        }
        if let date = args.string("date") {
            let ranges: [String: LibraryFilter.DateRange] = ["today": .today, "yesterday": .yesterday, "week": .lastWeek,
                                                             "month": .lastMonth, "year": .thisYear]
            guard let range = ranges[date.lowercased()] else { throw AgentError.usage("--date must be today, yesterday, week, month or year") }
            filter.dateRange = range
        }
        filter.favoritesOnly = try args.bool("favorites") == true
        filter.pinnedOnly = try args.bool("pinned") == true
        filter.withNotesOnly = try args.bool("notes") == true
        return filter
    }

    static func sort(_ args: Args) throws -> LibrarySort {
        guard let raw = args.string("sort") else { return .newest }
        guard let sort = LibrarySort(rawValue: raw.lowercased()) else { throw AgentError.usage("--sort must be newest, oldest or name") }
        return sort
    }

    // MARK: Exporting

    @MainActor
    static func export(_ item: CaptureItem, to path: String, original: Bool, overwrite: Bool) throws -> JSONObject {
        let isVideo = item.kind == .video && VideoStore.shared.has(item.id)
        let ext = isVideo ? "mp4" : "png"
        var target = URL(fileURLWithPath: path)
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isFolder), isFolder.boolValue {
            let name = item.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            target = target.appending(path: "\(name).\(ext)")
        }
        guard FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path) else {
            throw AgentError.notFound("no folder \(target.deletingLastPathComponent().path)")
        }
        if FileManager.default.fileExists(atPath: target.path) && !overwrite {
            throw AgentError.invalid("\(target.path) is already there. Add --overwrite to replace it, or give another --to")
        }
        if isVideo {
            guard let movie = VideoExport.temporaryFile(item) else { throw AgentError.invalid("couldn't write the video. Try again") }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: movie, to: target)
        } else {
            guard let png = original ? LibraryStore.shared.pngData(item.id) : Flattener.png(item) else {
                throw AgentError.invalid("couldn't read the picture of \(short(item.id)) on this Mac")
            }
            try png.write(to: target, options: .atomic)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
        return ["id": short(item.id), "path": target.path, "bytes": size, "withMarkup": !original && Flattener.needsDrawing(item)]
    }

    // MARK: Capturing

    static let modes: [(name: String, mode: CaptureMode)] = [
        ("area", .region), ("window", .window), ("window-or-area", .allInOne), ("screen", .screen),
        ("scrolling", .scrolling), ("video", .recording), ("exact-size", .fixedSize),
    ]

    /// Asking for Screen Recording from here would put the system prompt up out of nowhere.
    @MainActor
    static func screenAccess() throws {
        guard ScreenAccess.granted else {
            throw AgentError.invalid("SnagAnything isn't allowed to record the screen. Ask the person to turn it on in "
                                     + "System Settings › Privacy & Security › Screen & System Audio Recording")
        }
    }

    static func modeName(_ mode: CaptureMode) -> String { modes.first { $0.mode == mode }?.name ?? mode.rawValue }

    @MainActor
    static func startCapture(_ args: Args) throws -> JSONObject {
        let engine = CaptureEngine.shared
        guard !engine.isBusy else { throw AgentError.busy("a capture is already under way. Wait for it, then try again") }
        let delay = try args.int("delay", default: 0)
        guard (0...60).contains(delay) else { throw AgentError.usage("--delay must be 0 to 60 seconds") }
        let presets = Preferences.shared.presets

        var preset: CapturePreset
        if let name = args.string("preset") {
            guard let match = presets.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
                throw AgentError.notFound("no preset called \"\(name)\". Run `snag presets list`")
            }
            preset = match
        } else if let name = args.string("mode")?.lowercased() {
            switch name {
            case "again":
                guard engine.lastRegion != nil else { throw AgentError.invalid("nothing to capture again: capture an area first") }
                try screenAccess()
                engine.captureAgain()
                return ["started": "again", "waitsForPerson": false, "next": "run `snag captures list --limit 1`"]
            case "text":
                try screenAccess()
                engine.captureText()
                return ["started": "text", "waitsForPerson": true,
                        "next": "the person drags over the text; then run `snag captures list --kind text --limit 1`"]
            default:
                guard let mode = modes.first(where: { $0.name == name })?.mode else {
                    throw AgentError.usage("--mode must be one of \((modes.map(\.name) + ["text", "again"]).joined(separator: ", "))")
                }
                // The person's own preset for that mode, so their clipboard and after-capture choices hold.
                preset = presets.first { $0.mode == mode && $0.delay == 0 } ?? CapturePreset(name: mode.title, mode: mode)
            }
        } else {
            guard let first = presets.first else { throw AgentError.invalid("there are no presets. Give --mode") }
            preset = first
        }
        if args.string("delay") != nil { preset.delay = delay }
        if preset.mode == .recording && ScreenRecorder.shared.isActive {
            throw AgentError.busy("a recording is under way. The person stops it from its control bar or the menu bar menu")
        }
        try screenAccess()
        engine.run(preset)
        let immediate = preset.mode == .screen
        return ["started": modeName(preset.mode), "preset": preset.name, "delay": preset.delay, "waitsForPerson": !immediate,
                "next": immediate ? "run `snag captures list --limit 1` in a moment"
                    : "the person picks what to capture; then run `snag captures list --limit 1`"]
    }
}
