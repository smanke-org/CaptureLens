import CaptureLensKit
import Charts
import SwiftUI

/// Settings › Activity: how many captures CaptureLens has made, by kind, over time, plus
/// recording time, the apps and websites captured most, and how often captures were marked
/// up and shared. The graph starts at a week and widens to 30, 90 and 180 days, then a year,
/// as days of data build up. With settings sync on, it can add up every Mac.
struct ActivitySettings: View {
    @State private var store = ActivityStore.shared
    @State private var sync = ActivitySync.shared
    @State private var settingsSync = SettingsSync.shared
    @State private var library = LibraryStore.shared
    @State private var hovered: Date?
    /// Whether everything shows every Mac or only this one. Kept on each Mac, not synced.
    @AppStorage("activity.showAllMacs", store: AppDefaults.store) private var showAllMacs = true

    private static let kinds = ActivityKey.captureKinds
    private static let colors: [Color] = [.blue, .purple, .teal, .orange, .green, .pink]

    var body: some View {
        let now = Date()
        let remotes = sync.activeRemotes
        let allMacs = showAllMacs && !remotes.isEmpty
        let log = allMacs ? sync.combinedLog : store.log
        let range = CaptureStats.range(firstDay: log.firstDay.flatMap { ActivityLog.date(for: $0) }, today: now)
        let stacks = CaptureStats.bars(log: log, kinds: Self.kinds, range: range, today: now)
        let bars = CaptureStats.bars(counts: log.counts(kinds: Set(Self.kinds)), range: range, today: now)
        let start = bars.first?.start ?? now
        let totals = log.totals(since: start)
        let total = Self.kinds.reduce(0) { $0 + (totals[$1] ?? 0) }
        let hoveredBar = hovered.flatMap { date in bars.first { date >= $0.start && date < $0.end } }
        let where_ = remotes.isEmpty ? "" : allMacs ? " on \(remotes.count + 1) Macs" : " on this Mac"

        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    if !remotes.isEmpty {
                        Picker("Show", selection: $showAllMacs) {
                            Text("This Mac").tag(false)
                            Text("All Macs").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 8)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(total, format: .number)
                            .font(.system(size: 34, weight: .semibold))
                            .monospacedDigit()
                        Text("capture\(total == 1 ? "" : "s") in the \(range.title)\(where_)")
                            .foregroundStyle(.secondary)
                    }
                    Text(breakdown(totals))
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    chart(stacks, bars: bars, range: range, hovered: hoveredBar)
                        .frame(height: 200)
                        .padding(.top, 10)

                    Text(hoveredBar.map { readout($0, stacks: stacks, bars: bars, range: range) } ?? "Hover over a bar to see its count.")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(hoveredBar == nil ? .tertiary : .primary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.vertical, 4)
            } footer: {
                Text("The graph widens as you use CaptureLens: 7 days at first, then 30, 90 and 180 days, then a year. Only the numbers are kept, never what you captured. Imported pictures aren't counted as captures.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Recordings in the \(range.title)") {
                LabeledContent("Videos recorded", value: (totals[ActivityKey.video] ?? 0).formatted())
                LabeledContent("Time recorded", value: Self.duration(totals[ActivityKey.recordingSeconds] ?? 0))
            }

            mostCaptured(since: start, allMacs: allMacs, range: range)

            Section("Markup and sharing in the \(range.title)") {
                LabeledContent("Marks added", value: (totals[ActivityKey.marks] ?? 0).formatted())
                LabeledContent("Copied", value: (totals[ActivityKey.copies] ?? 0).formatted())
                LabeledContent("Saved with Save As", value: (totals[ActivityKey.saves] ?? 0).formatted())
                LabeledContent("Exported", value: (totals[ActivityKey.exports] ?? 0).formatted())
                LabeledContent("Dragged out", value: (totals[ActivityKey.drags] ?? 0).formatted())
                LabeledContent("Shared", value: (totals[ActivityKey.shares] ?? 0).formatted())
                if let imported = totals[ActivityKey.imported], imported > 0 {
                    LabeledContent("Pictures imported", value: imported.formatted())
                }
            }

            macsSection()
        }
        .formStyle(.grouped)
        .onAppear { sync.refresh() }
    }

    // MARK: Most captured

    /// Worked out from the library: this Mac's captures, or every Mac's.
    @ViewBuilder
    private func mostCaptured(since start: Date, allMacs: Bool, range: StatsRange) -> some View {
        let me = DeviceIdentity.deviceID
        let items = library.items.filter { $0.kind != .imported && (allMacs || $0.origin == nil || $0.origin == me) }
        let apps = TopSources.apps(items, since: start)
        let sites = TopSources.websites(items, since: start)
        Section {
            if apps.isEmpty && sites.isEmpty {
                Text("Nothing captured in the \(range.title) yet.").foregroundStyle(.secondary)
            }
            ForEach(apps, id: \.name) { app in
                LabeledContent {
                    Text(app.count, format: .number).monospacedDigit()
                } label: {
                    Label {
                        Text(app.name)
                    } icon: {
                        if let id = app.bundleID { AppIcon(bundleID: id) } else { Image(systemName: "app.dashed") }
                    }
                }
            }
            if !sites.isEmpty {
                ForEach(sites, id: \.site) { site in
                    LabeledContent {
                        Text(site.count, format: .number).monospacedDigit()
                    } label: {
                        Label(site.site, systemImage: "globe")
                    }
                }
            }
        } header: {
            Text("Captured most in the \(range.title)")
        } footer: {
            Text("From the captures in your library, so deleted ones aren't counted.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Macs

    @ViewBuilder
    private func macsSection() -> some View {
        let remotes = sync.activeRemotes
        Section {
            if !remotes.isEmpty {
                macRow(DeviceIdentity.deviceName, status: "This Mac", log: store.log)
                ForEach(remotes, id: \.deviceID) { mac in
                    macRow(mac.deviceName, status: "Synced \(mac.updatedAt.formatted(.relative(presentation: .named)))", log: mac.log)
                }
            }
        } header: {
            HStack {
                Text("All Macs")
                Spacer()
                if !remotes.isEmpty {
                    Text("\(Self.captures(in: sync.combinedLog).formatted()) captures").monospacedDigit()
                }
            }
        } footer: {
            Group {
                if !settingsSync.isEnabled && remotes.isEmpty {
                    Text("Turn on “Sync settings with your other Macs” in General to add up captures from every Mac that uses CaptureLens.")
                } else if !settingsSync.isReady && remotes.isEmpty {
                    Text("Waiting for your sync passphrase in General to add up captures from your other Macs.")
                } else if remotes.isEmpty {
                    Text("Captures from your other Macs are added here once CaptureLens on them has settings sync turned on.")
                } else {
                    Text("Each Mac's captures since CaptureLens started counting there. Only the numbers are shared, encrypted like your settings.")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func macRow(_ name: String, status: String, log: ActivityLog) -> some View {
        LabeledContent {
            Text(Self.captures(in: log), format: .number).monospacedDigit()
        } label: {
            Text(name)
            Text(status)
        }
    }

    private static func captures(in log: ActivityLog) -> Int {
        let totals = log.lifetimeTotals
        return kinds.reduce(0) { $0 + (totals[$1] ?? 0) }
    }

    // MARK: Graph

    @ViewBuilder
    private func chart(_ stacks: [(kind: String, bars: [StatsBar])], bars: [StatsBar], range: StatsRange, hovered: StatsBar?) -> some View {
        let peak = bars.map(\.count).max() ?? 0
        let segments = Self.segments(stacks)
        Chart(segments) { segment in
            // A ranged bar spans exactly its days; trimming each end leaves a gap between bars.
            let gap = segment.end.timeIntervalSince(segment.start) * 0.12
            RectangleMark(xStart: .value("From", segment.start.addingTimeInterval(gap)),
                          xEnd: .value("To", segment.end.addingTimeInterval(-gap)),
                          yStart: .value("Captures", segment.low), yEnd: .value("Captures", segment.high))
                .foregroundStyle(by: .value("Kind", ActivityKey.title(segment.kind)))
                .opacity(hovered == nil || hovered?.start == segment.start ? 1 : 0.4)
        }
        .chartForegroundStyleScale(domain: Self.kinds.map(ActivityKey.title), range: Self.colors)
        .chartLegend(position: .bottom, alignment: .center)
        .chartXSelection(value: $hovered)
        .chartYScale(domain: 0...max(peak, 4))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.25))
                AxisValueLabel().foregroundStyle(Color.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: xTicks(bars, range: range)) { value in
                AxisValueLabel(centered: false) {
                    if let date = value.as(Date.self) { Text(axisLabel(date, range: range)) }
                }
                .foregroundStyle(Color.secondary)
            }
        }
        .overlay {
            if peak == 0 {
                Text("No captures yet. Press \(Preferences.shared.presets.first?.hotKey?.display ?? "the capture shortcut") to take one.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// One piece of a stacked bar: a kind's share of one bar, from `low` to `high`.
    struct Segment: Identifiable {
        let kind: String
        let start: Date
        let end: Date
        let low: Int
        let high: Int
        var id: String { "\(kind)-\(start.timeIntervalSince1970)" }
    }

    static func segments(_ stacks: [(kind: String, bars: [StatsBar])]) -> [Segment] {
        guard let first = stacks.first else { return [] }
        var result: [Segment] = []
        for index in first.bars.indices {
            var low = 0
            for stack in stacks {
                let bar = stack.bars[index]
                guard bar.count > 0 else { continue }
                result.append(Segment(kind: stack.kind, start: bar.start, end: bar.end, low: low, high: low + bar.count))
                low += bar.count
            }
        }
        return result
    }

    private func xTicks(_ bars: [StatsBar], range: StatsRange) -> [Date] {
        guard !bars.isEmpty else { return [] }
        let step: Int = switch range {
        case .week: 1
        case .month: 5
        case .quarter: 2
        case .halfYear: 4
        case .year: 2
        }
        // From the left, never on the last bar, whose label would run off the edge.
        let last = range == .week ? bars.count - 1 : bars.count - 2
        return stride(from: 0, through: max(last, 0), by: step).map { bars[$0].start }
    }

    private func axisLabel(_ date: Date, range: StatsRange) -> String {
        switch range {
        case .week: date.formatted(.dateTime.weekday(.abbreviated))
        case .month, .quarter, .halfYear: date.formatted(.dateTime.month(.abbreviated).day())
        case .year: date.formatted(.dateTime.month(.abbreviated))
        }
    }

    private func readout(_ bar: StatsBar, stacks: [(kind: String, bars: [StatsBar])], bars: [StatsBar], range: StatsRange) -> String {
        let index = bars.firstIndex(of: bar) ?? 0
        let parts = stacks.compactMap { stack -> String? in
            let n = stack.bars[index].count
            return n > 0 ? "\(n) \(ActivityKey.title(stack.kind).lowercased())" : nil
        }
        let count = "\(bar.count.formatted()) capture\(bar.count == 1 ? "" : "s")" + (parts.count > 1 ? " (\(parts.joined(separator: ", ")))" : "")
        let lastDay = bar.end.addingTimeInterval(-1)
        switch range.bucket {
        case .day: return "\(bar.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())): \(count)"
        case .week: return "\(bar.start.formatted(.dateTime.month(.abbreviated).day())) – \(lastDay.formatted(.dateTime.month(.abbreviated).day())): \(count)"
        case .month: return "\(bar.start.formatted(.dateTime.month(.wide).year())): \(count)"
        }
    }

    private func breakdown(_ totals: [String: Int]) -> String {
        let parts = Self.kinds.compactMap { kind -> String? in
            guard let n = totals[kind], n > 0 else { return nil }
            return "\(n.formatted()) \(ActivityKey.title(kind).lowercased())"
        }
        return parts.isEmpty ? "Nothing captured yet" : parts.joined(separator: " · ")
    }

    static func duration(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return seconds == 0 ? "None" : formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) s"
    }
}
