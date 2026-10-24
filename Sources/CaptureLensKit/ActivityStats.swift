import Foundation

/// How far back the Activity graph looks. It widens as CaptureLens collects more history:
/// a week at first, then 30, 90 and 180 days, then a year.
public enum StatsRange: Int, CaseIterable, Sendable {
    case week = 7, month = 30, quarter = 90, halfYear = 180, year = 365

    public var days: Int { rawValue }

    /// How the bars are grouped: a bar per day up to 30 days, per week for 90 and 180
    /// days, per month for a year.
    public var bucket: StatsBucket {
        switch self {
        case .week, .month: .day
        case .quarter, .halfYear: .week
        case .year: .month
        }
    }

    public var title: String {
        switch self {
        case .week: "last 7 days"
        case .month: "last 30 days"
        case .quarter: "last 90 days"
        case .halfYear: "last 180 days"
        case .year: "last year"
        }
    }

    /// The smallest range that covers `span` days of data (counting the first day and
    /// today); more than 180 days shows a year.
    public static func covering(span: Int) -> StatsRange {
        allCases.first { span <= $0.days } ?? .year
    }
}

public enum StatsBucket: Sendable { case day, week, month }

/// One bar on the Activity graph.
public struct StatsBar: Equatable, Identifiable, Sendable {
    public var start: Date
    /// Exclusive.
    public var end: Date
    public var count: Int
    public var id: Date { start }

    public init(start: Date, end: Date, count: Int) {
        self.start = start
        self.end = end
        self.count = count
    }
}

/// Turns per-day counts into the bars for the Activity graph.
public enum CaptureStats {
    /// The range to show, given the first day anything was recorded.
    public static func range(firstDay: Date?, today: Date, calendar: Calendar = .current) -> StatsRange {
        guard let firstDay else { return .week }
        let start = calendar.startOfDay(for: firstDay), end = calendar.startOfDay(for: today)
        let span = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        return covering(span)
    }

    static func covering(_ span: Int) -> StatsRange { StatsRange.covering(span: span) }

    /// Bars covering `range` and ending today. Weeks are counted back from today so the
    /// last bar always includes it; months are calendar months, the current one partial.
    public static func bars(counts: [Date: Int], range: StatsRange, today: Date,
                            calendar: Calendar = .current) -> [StatsBar] {
        let todayStart = calendar.startOfDay(for: today)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        let firstDay = calendar.date(byAdding: .day, value: -(range.days - 1), to: todayStart)!

        var edges: [Date] = []
        switch range.bucket {
        case .day:
            edges = (0...range.days).map { calendar.date(byAdding: .day, value: $0, to: firstDay)! }
        case .week:
            let weeks = Int((Double(range.days) / 7).rounded(.up))
            edges = (0...weeks).reversed().map { calendar.date(byAdding: .day, value: -7 * $0, to: tomorrow)! }
        case .month:
            let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: todayStart))!
            edges = (0...11).reversed().map { calendar.date(byAdding: .month, value: -$0, to: thisMonth)! }
            edges.append(tomorrow)
        }

        var bars = zip(edges, edges.dropFirst()).map { StatsBar(start: $0, end: $1, count: 0) }
        for (day, count) in counts where count > 0 {
            let start = calendar.startOfDay(for: day)
            guard start >= edges.first!, start < edges.last! else { continue }
            if let index = bars.firstIndex(where: { start >= $0.start && start < $0.end }) {
                bars[index].count += count
            }
        }
        return bars
    }
}

/// The per-day counts CaptureLens keeps for Settings › Activity: numbers only, never what
/// was captured. Days are stored as "yyyy-MM-dd" in the Mac's time zone. Each count has a
/// key: a kind of capture ("area", "window", "video"…) or something done with captures
/// ("marks", "copies", "recordingSeconds"…); see `ActivityKey`.
public struct ActivityLog: Codable, Equatable, Sendable {
    /// The first day anything was recorded, even if that day has since been trimmed.
    public var firstDay: String?
    /// Day → key → count.
    public var days: [String: [String: Int]]
    /// Kind → count since counting began, kept apart from `days` because old days are
    /// trimmed. Nil in a log that hasn't counted anything yet; `lifetimeTotals` then adds up
    /// the days.
    public var lifetime: [String: Int]?

    public init(firstDay: String? = nil, days: [String: [String: Int]] = [:], lifetime: [String: Int]? = nil) {
        self.firstDay = firstDay
        self.days = days
        self.lifetime = lifetime
    }

    /// Every count since counting began, by kind.
    public var lifetimeTotals: [String: Int] {
        if let lifetime { return lifetime }
        var result: [String: Int] = [:]
        for perKind in days.values {
            for (kind, count) in perKind { result[kind, default: 0] += count }
        }
        return result
    }

    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func date(for key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    public mutating func record(_ kind: String, count: Int = 1, at date: Date = Date(), calendar: Calendar = .current) {
        guard count > 0 else { return }
        let day = Self.key(for: date, calendar: calendar)
        // Before the first trim drops anything, so an older log starts from all it holds.
        if lifetime == nil { lifetime = lifetimeTotals }
        lifetime?[kind, default: 0] += count
        days[day, default: [:]][kind, default: 0] += count
        if firstDay.map({ day < $0 }) ?? true { firstDay = day }
    }

    /// Drops days older than `keepDays`, so the file stays small. `firstDay` is kept, so the
    /// graph's range still reflects how long CaptureLens has been in use.
    public mutating func trim(keepDays: Int = 400, now: Date = Date(), calendar: Calendar = .current) {
        guard let cutoff = calendar.date(byAdding: .day, value: -keepDays, to: calendar.startOfDay(for: now)) else { return }
        let cutoffKey = Self.key(for: cutoff, calendar: calendar)
        days = days.filter { $0.key >= cutoffKey }
    }

    /// Totals per day for the given kinds.
    public func counts(kinds: Set<String>, calendar: Calendar = .current) -> [Date: Int] {
        var result: [Date: Int] = [:]
        for (key, perKind) in days {
            guard let date = Self.date(for: key, calendar: calendar) else { continue }
            let total = perKind.filter { kinds.contains($0.key) }.values.reduce(0, +)
            if total > 0 { result[date, default: 0] += total }
        }
        return result
    }

    /// Totals per kind since `start`.
    public func totals(since start: Date, calendar: Calendar = .current) -> [String: Int] {
        let startKey = Self.key(for: start, calendar: calendar)
        var result: [String: Int] = [:]
        for (key, perKind) in days where key >= startKey {
            for (kind, count) in perKind { result[kind, default: 0] += count }
        }
        return result
    }
}

extension ActivityLog {
    /// Several Macs' logs added together, for the All Macs graph. Days are matched by
    /// their "yyyy-MM-dd" key, each counted in its own Mac's time zone, and the earliest
    /// first day wins, so the graph's range reflects the Mac that has used CaptureLens longest.
    public static func combined(_ logs: [ActivityLog]) -> ActivityLog {
        var result = ActivityLog()
        for log in logs {
            for (day, perKind) in log.days {
                for (kind, count) in perKind { result.days[day, default: [:]][kind, default: 0] += count }
            }
            if let first = log.firstDay, result.firstDay.map({ first < $0 }) ?? true { result.firstDay = first }
            for (kind, count) in log.lifetimeTotals { result.lifetime = result.lifetime ?? [:]; result.lifetime?[kind, default: 0] += count }
        }
        return result
    }
}

/// One Mac's activity, as shared with the user's other Macs through iCloud. Each Mac writes
/// only its own record, and the counts in it are whole-day totals rather than increments,
/// so a stale, repeated or delayed record can never count anything twice.
public struct DeviceActivity: Codable, Equatable, Sendable {
    public var schema = 1
    public var deviceID: String
    public var deviceName: String
    public var updatedAt: Date
    public var appVersion: String?
    public var log: ActivityLog

    public init(deviceID: String, deviceName: String, updatedAt: Date, appVersion: String?, log: ActivityLog) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.updatedAt = updatedAt
        self.appVersion = appVersion
        self.log = log
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// What Settings › Activity counts.
public enum ActivityKey {
    /// Captures, by kind: the graph's bars.
    public static let area = "area", window = "window", screen = "screen", scrolling = "scrolling", steps = "steps", video = "video"
    public static let captureKinds = [area, window, screen, scrolling, steps, video]
    /// Pictures brought in (files, or from Snagit): counted apart, so an import doesn't
    /// tower over the captures.
    public static let imported = "imported"
    public static let recordingSeconds = "recordingSeconds"
    /// Marks added, and captures copied, saved, exported, dragged out and shared.
    public static let marks = "marks", copies = "copies", saves = "saves", exports = "exports", drags = "drags", shares = "shares"

    public static func title(_ kind: String) -> String {
        switch kind {
        case area: "Area"
        case window: "Window"
        case screen: "Full screen"
        case scrolling: "Scrolling"
        case steps: "Steps"
        case video: "Video"
        default: kind
        }
    }
}

extension CaptureStats {
    /// The graph's bars split by kind: for each kind, its count in every bar (bars in the
    /// same order as `bars(counts:…)` gives them).
    public static func bars(log: ActivityLog, kinds: [String], range: StatsRange, today: Date,
                            calendar: Calendar = .current) -> [(kind: String, bars: [StatsBar])] {
        kinds.map { kind in (kind, bars(counts: log.counts(kinds: [kind], calendar: calendar), range: range, today: today, calendar: calendar)) }
    }
}

/// The apps and websites captured most, from the library itself.
public enum TopSources {
    public static func apps(_ items: [CaptureItem], since start: Date, limit: Int = 5) -> [(name: String, bundleID: String?, count: Int)] {
        var counts: [String: (String?, Int)] = [:]
        for item in items where item.created >= start {
            guard let name = item.source.appName, !name.isEmpty else { continue }
            counts[name, default: (item.source.bundleID, 0)].1 += 1
        }
        return counts.map { (name: $0.key, bundleID: $0.value.0, count: $0.value.1) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
            .prefix(limit).map { $0 }
    }

    public static func websites(_ items: [CaptureItem], since start: Date, limit: Int = 5) -> [(site: String, count: Int)] {
        var counts: [String: Int] = [:]
        for item in items where item.created >= start {
            if let site = item.source.website { counts[site, default: 0] += 1 }
        }
        return counts.map { (site: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.site) > ($1.count, $0.site) }
            .prefix(limit).map { $0 }
    }
}
