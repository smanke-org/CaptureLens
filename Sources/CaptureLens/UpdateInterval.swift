import SwiftUI

/// How often to look for updates on its own: a number of hours, days, weeks or months.
/// The number and the unit are stored apart, so "2 weeks" stays "2 weeks" rather than
/// turning into "14 days".
struct UpdateInterval: Equatable {
    enum Unit: String, CaseIterable {
        case hours, days, weeks, months

        /// The largest number allowed for the unit: a week of hours, three months of days,
        /// half a year of weeks, a year of months.
        var maximum: Int {
            switch self {
            case .hours: 168
            case .days: 90
            case .weeks: 26
            case .months: 12
            }
        }

        var seconds: TimeInterval {
            switch self {
            case .hours: 60 * 60
            case .days: 24 * 60 * 60
            case .weeks: 7 * 24 * 60 * 60
            case .months: 30 * 24 * 60 * 60
            }
        }

        /// "day" or "days".
        func name(for count: Int) -> String {
            count == 1 ? String(rawValue.dropLast()) : rawValue
        }
    }

    let value: Int
    let unit: Unit

    /// Keeps the number between 1 and the unit's maximum.
    init(value: Int, unit: Unit) {
        self.unit = unit
        self.value = min(max(value, 1), unit.maximum)
    }

    /// Also what earlier versions, which checked every 30 minutes, move to.
    static let standard = UpdateInterval(value: 1, unit: .days)

    static let valueKey = "updateInterval.value"
    static let unitKey = "updateInterval.unit"

    var seconds: TimeInterval { Double(value) * unit.seconds }

    /// "every day", "every 3 weeks".
    var phrase: String {
        value == 1 ? "every \(unit.name(for: 1))" : "every \(value) \(unit.name(for: value))"
    }

    private static var defaults: UserDefaults { .standard }

    static var current: UpdateInterval {
        get {
            // Read loosely: a synced file from another Mac could hold anything.
            let unit = defaults.string(forKey: unitKey).flatMap(Unit.init) ?? standard.unit
            let value = (defaults.object(forKey: valueKey) as? NSNumber)?.intValue ?? standard.value
            return UpdateInterval(value: value, unit: unit)
        }
        set {
            defaults.set(newValue.value, forKey: valueKey)
            defaults.set(newValue.unit.rawValue, forKey: unitKey)
        }
    }
}

/// "Check every [1] [day]", for the Updates section of Settings.
struct UpdateIntervalPicker: View {
    @Binding var interval: UpdateInterval
    var label = "Check every"
    /// Bumped on every commit, so the field shows the stored number even when the typed one
    /// was out of range and the stored one didn't change (typing 0 over 1).
    @State private var redraw = 0

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField("Number", value: Binding(
                    get: { interval.value },
                    set: { interval = UpdateInterval(value: $0, unit: interval.unit); redraw += 1 }
                ), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
                .id(redraw)
                Picker("Unit", selection: Binding(
                    get: { interval.unit },
                    set: { interval = UpdateInterval(value: interval.value, unit: $0) }
                )) {
                    ForEach(UpdateInterval.Unit.allCases, id: \.self) { Text($0.name(for: interval.value)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .help("From 1 to \(interval.unit.maximum) \(interval.unit.rawValue)")
    }
}
