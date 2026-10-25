import Foundation

/// What the library is narrowed to: the search field plus the filter chips and sidebar.
public struct LibraryFilter: Equatable, Sendable {
    public enum DateRange: Equatable, Sendable, Hashable {
        case any, today, yesterday, lastWeek, lastMonth, thisYear
        case custom(start: Date, end: Date)

        public static let presets: [DateRange] = [.today, .yesterday, .lastWeek, .lastMonth, .thisYear]

        public var title: String {
            switch self {
            case .any: "Any Date"
            case .today: "Today"
            case .yesterday: "Yesterday"
            case .lastWeek: "Last 7 Days"
            case .lastMonth: "Last 30 Days"
            case .thisYear: "This Year"
            case .custom(let start, let end):
                Calendar.current.isDate(start, inSameDayAs: end)
                    ? start.formatted(date: .abbreviated, time: .omitted)
                    : "\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))"
            }
        }

        /// The dates it covers, start inclusive and end exclusive; nil for any date.
        public func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
            let today = calendar.startOfDay(for: now)
            func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
            switch self {
            case .any: return nil
            case .today: return DateInterval(start: today, end: day(1))
            case .yesterday: return DateInterval(start: day(-1), end: today)
            case .lastWeek: return DateInterval(start: day(-6), end: day(1))
            case .lastMonth: return DateInterval(start: day(-29), end: day(1))
            case .thisYear:
                let start = calendar.date(from: calendar.dateComponents([.year], from: now))!
                return DateInterval(start: start, end: day(1))
            case .custom(let start, let end):
                let s = calendar.startOfDay(for: min(start, end))
                let e = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(start, end)))!
                return DateInterval(start: s, end: e)
            }
        }
    }

    public var text = ""
    public var dateRange: DateRange = .any
    public var kinds: Set<CaptureItem.Kind> = []
    /// Apps by bundle ID (or name, when an app had none).
    public var apps: Set<String> = []
    public var websites: Set<String> = []
    /// Items must carry every one of these tags.
    public var tags: Set<String> = []
    public var favoritesOnly = false
    public var withNotesOnly = false

    public init() {}

    /// Whether anything besides the search text narrows the list.
    public var hasChips: Bool {
        dateRange != .any || !kinds.isEmpty || !apps.isEmpty || !websites.isEmpty || !tags.isEmpty
            || favoritesOnly || withNotesOnly
    }

    public var isEmpty: Bool { !hasChips && text.trimmingCharacters(in: .whitespaces).isEmpty }
}

public enum LibrarySort: String, CaseIterable, Sendable {
    case newest, oldest, name

    public var title: String {
        switch self {
        case .newest: "Newest First"
        case .oldest: "Oldest First"
        case .name: "Name"
        }
    }
}

/// Searching, filtering and tidying the library, kept apart from storage so it can be tested.
public enum LibraryQuery {
    /// The search text broken into what it asks for: plain words (each must appear in the
    /// name, tags, notes, recognized text or source), `tag:`, `app:` and `site:` terms, and
    /// a date ("yesterday", "March 3", "2026-10-01") that limits the day.
    public struct ParsedSearch: Equatable, Sendable {
        public var words: [String] = []
        public var tags: [String] = []
        public var apps: [String] = []
        public var sites: [String] = []
        public var day: DateInterval?
    }

    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> ParsedSearch {
        var parsed = ParsedSearch()
        var remaining = text
        func day(_ date: Date) -> DateInterval {
            let start = calendar.startOfDay(for: date)
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
        }
        // "today" and "yesterday" relative to `now`; other dates anywhere in the text, found
        // the way Mail and Notes find them.
        let relative = ["today": 0, "yesterday": -1]
        if let (word, offset) = relative.first(where: { word, _ in
            remaining.split(whereSeparator: \.isWhitespace).contains { $0.lowercased() == word }
        }) {
            parsed.day = day(calendar.date(byAdding: .day, value: offset, to: now)!)
            remaining = remaining.split(whereSeparator: \.isWhitespace).filter { $0.lowercased() != word }.joined(separator: " ")
        } else if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let date = match.date, let range = Range(match.range, in: text),
           isDateLike(String(text[range])) {
            parsed.day = day(date)
            remaining.removeSubrange(range)
        }
        for token in remaining.split(whereSeparator: \.isWhitespace).map(String.init) {
            let lower = token.lowercased()
            func value(_ prefix: String) -> String? {
                guard lower.hasPrefix(prefix), token.count > prefix.count else { return nil }
                return fold(String(token.dropFirst(prefix.count)))
            }
            if let v = value("tag:") { parsed.tags.append(v) }
            else if let v = value("app:") { parsed.apps.append(v) }
            else if let v = value("site:") { parsed.sites.append(v) }
            else { parsed.words.append(fold(token)) }
        }
        return parsed
    }

    /// The data detector also reads times ("at 5") and lone numbers; only whole dates count.
    static func isDateLike(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        if ["today", "yesterday"].contains(lower) { return true }
        let hasLetters = lower.rangeOfCharacter(from: .letters) != nil
        let digits = lower.filter(\.isNumber).count
        let separators = lower.filter { "-/.".contains($0) }.count
        // "March 3", "3 Oct", "Monday"; or "2026-10-01", "10/1/2026".
        return (hasLetters && lower.count >= 3 && !lower.hasPrefix("at ")) || (digits >= 3 && separators >= 1)
    }

    /// Items that pass the filter, sorted.
    public static func filter(_ items: [CaptureItem], with filter: LibraryFilter, sort: LibrarySort = .newest,
                              now: Date = Date()) -> [CaptureItem] {
        let search = parse(filter.text, now: now)
        let interval = filter.dateRange.interval(now: now)
        let wantedTags = Set(filter.tags.map(fold)) .union(search.tags)
        let result = items.filter { item in
            if filter.favoritesOnly && !item.favorite { return false }
            if filter.withNotesOnly && item.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            if !filter.kinds.isEmpty && !filter.kinds.contains(item.kind) { return false }
            if !filter.apps.isEmpty && !filter.apps.contains(appKey(item)) { return false }
            if !filter.websites.isEmpty && !filter.websites.contains(item.source.website ?? "") { return false }
            if let interval, !interval.contains(item.created) || item.created == interval.end { return false }
            if let day = search.day, !(day.start <= item.created && item.created < day.end) { return false }
            if !wantedTags.isEmpty {
                let have = Set(item.tags.map(fold))
                guard wantedTags.isSubset(of: have) else { return false }
            }
            if !search.apps.isEmpty {
                let app = fold(item.source.appName ?? "")
                guard search.apps.allSatisfy(app.contains) else { return false }
            }
            if !search.sites.isEmpty {
                let site = fold(item.source.url ?? "")
                guard search.sites.allSatisfy(site.contains) else { return false }
            }
            if !search.words.isEmpty {
                let haystack = fold(searchBody(item))
                guard search.words.allSatisfy(haystack.contains) else { return false }
            }
            return true
        }
        switch sort {
        case .newest: return result.sorted { $0.created > $1.created }
        case .oldest: return result.sorted { $0.created < $1.created }
        case .name: return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// Everything a capture is found by.
    public static func searchBody(_ item: CaptureItem) -> String {
        [item.name, item.tags.joined(separator: " "), item.notes, item.recognizedText,
         item.source.appName ?? "", item.source.windowTitle ?? "", item.source.url ?? "", item.source.pageTitle ?? ""]
            .joined(separator: "\n")
    }

    /// The key an app is filtered by.
    public static func appKey(_ item: CaptureItem) -> String {
        item.source.bundleID ?? item.source.appName ?? ""
    }

    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: Tags

    /// Tags as typed: trimmed, a leading # dropped, no blanks, no repeats (ignoring case),
    /// in the order given.
    public static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in tags {
            var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while tag.hasPrefix("#") { tag.removeFirst() }
            tag = tag.trimmingCharacters(in: .whitespaces)
            guard !tag.isEmpty, seen.insert(fold(tag)).inserted else { continue }
            out.append(String(tag.prefix(40)))
        }
        return out
    }

    /// Every tag in use, with how many items carry it, by name. Spelling follows the most
    /// recent item that uses it.
    public static func tagCounts(_ items: [CaptureItem]) -> [(tag: String, count: Int)] {
        var counts: [String: (tag: String, count: Int, date: Date)] = [:]
        // The same few tags repeat across thousands of captures, and folding is slow.
        var folded: [String: String] = [:]
        for item in items {
            for tag in item.tags {
                let key = folded[tag] ?? fold(tag)
                folded[tag] = key
                var entry = counts[key] ?? (tag, 0, .distantPast)
                entry.count += 1
                if item.created > entry.date { entry.tag = tag; entry.date = item.created }
                counts[key] = entry
            }
        }
        return counts.values.map { ($0.tag, $0.count) }
            .sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }

    /// Apps that captures came from: (filter key, name, count), most used first.
    public static func appCounts(_ items: [CaptureItem]) -> [(key: String, name: String, count: Int)] {
        var counts: [String: (name: String, count: Int)] = [:]
        for item in items {
            let key = appKey(item)
            guard !key.isEmpty else { continue }
            counts[key, default: (item.source.appName ?? key, 0)].count += 1
        }
        return counts.map { ($0.key, $0.value.name, $0.value.count) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    public static func websiteCounts(_ items: [CaptureItem]) -> [(site: String, count: Int)] {
        var counts: [String: Int] = [:]
        for item in items { if let site = item.source.website { counts[site, default: 0] += 1 } }
        return counts.map { ($0.key, $0.value) }.sorted { ($0.count, $1.site) > ($1.count, $0.site) }
    }
}

/// Tags, apps and websites in use, with how many captures each has: what the sidebar, the
/// filter menus and the tag picker list.
public struct LibraryFacets {
    public let tags: [(tag: String, count: Int)]
    public let apps: [(key: String, name: String, count: Int)]
    public let websites: [(site: String, count: Int)]

    public init(_ items: [CaptureItem]) {
        tags = LibraryQuery.tagCounts(items)
        apps = LibraryQuery.appCounts(items)
        websites = LibraryQuery.websiteCounts(items)
    }
}

/// Names for captures: tidying what on-device naming suggests, and the fallback when it
/// can't run.
public enum CaptureNaming {
    public static let maxLength = 60

    /// A suggestion made fit for a name: one line, no quotes or trailing period, no
    /// characters Finder refuses (/ and :), and not too long.
    public static func clean(_ suggestion: String) -> String? {
        var name = suggestion.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Name:", "Title:", "Filename:", "File name:"] where name.lowercased().hasPrefix(prefix.lowercased()) {
            name = String(name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’`*_#"))
        if name.hasSuffix(".") { name.removeLast() }
        for ext in [".png", ".jpg", ".jpeg"] where name.lowercased().hasSuffix(ext) { name.removeLast(ext.count) }
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if name.count > maxLength {
            // Cut at a word boundary.
            let cut = name.prefix(maxLength)
            name = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        }
        return name.count >= 2 ? name : nil
    }

    /// A name from what is known about the source when there's no suggestion: the page or
    /// window title with the app, else "Capture <date>".
    public static func fallback(source: CaptureItem.Source, date: Date) -> String {
        let title = [source.pageTitle, source.windowTitle].compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        let name: String?
        switch (title, source.appName) {
        case (let t?, let app?) where !t.localizedCaseInsensitiveContains(app): name = "\(app) – \(t)"
        case (let t?, _): name = t
        case (nil, let app?): name = "\(app) \(stamp(date))"
        default: name = nil
        }
        return name.flatMap(clean) ?? "Capture \(stamp(date))"
    }

    /// "2026-10-24 at 13.05.12", as macOS names screenshots.
    public static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: date)
    }
}
