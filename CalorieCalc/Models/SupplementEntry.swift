import Foundation
import SwiftData

/// One log of a vitamin or supplement on a given day. Doesn't carry any nutrition data —
/// supplements are tracked separately from food and don't fold into calorie/macro math.
@Model
final class SupplementEntry {
    var id: UUID = UUID()

    var name: String = ""
    var dose: Double = 0
    var doseUnit: String = "mg"

    /// Soft-hide flag for the recents picker. When the user swipes a recent row in the picker
    /// sheet we set this to `true` on every matching (name, dose, unit) entry so the row stops
    /// surfacing. Logging a fresh entry resets it via the new record's default `false`.
    var hiddenFromRecents: Bool = false

    var notes: String?
    var timestamp: Date = Date()

    var dayLog: DayLog?

    init(
        id: UUID = UUID(),
        name: String,
        dose: Double,
        doseUnit: String,
        hiddenFromRecents: Bool = false,
        notes: String? = nil,
        timestamp: Date = .now,
        dayLog: DayLog? = nil
    ) {
        self.id = id
        self.name = name
        self.dose = dose
        self.doseUnit = doseUnit
        self.hiddenFromRecents = hiddenFromRecents
        self.notes = notes
        self.timestamp = timestamp
        self.dayLog = dayLog
    }
}

extension SupplementEntry {
    /// Picker unit options. Mass first, then volume, then countables. Free-form `doseUnit`
    /// so historical entries with custom units still render — this list just defines what the
    /// add-new form offers.
    static let unitOptions: [String] = [
        "mg", "mcg", "g", "IU",
        "ml",
        "capsule", "tablet", "drop", "scoop",
    ]

    /// Display string for a row: "1000 mg" / "1 capsule".
    var doseDisplay: String {
        let amount: String = dose.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(dose))
            : dose.formatted(.number.precision(.fractionLength(0...2)))
        return "\(amount) \(doseUnit)"
    }
}
