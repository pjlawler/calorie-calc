import Foundation

nonisolated enum MealType: String, Codable, CaseIterable, Hashable, Sendable {
    case breakfast
    case lunch
    case dinner
    case snack

    var displayName: String {
        switch self {
        case .breakfast: "Breakfast"
        case .lunch: "Lunch"
        case .dinner: "Dinner"
        case .snack: "Snacks"
        }
    }

    var order: Int {
        switch self {
        case .breakfast: 0
        case .lunch: 1
        case .dinner: 2
        case .snack: 3
        }
    }

    var symbolName: String {
        switch self {
        case .breakfast: "sun.horizon.fill"
        case .lunch: "sun.max.fill"
        case .dinner: "moon.stars.fill"
        case .snack: "takeoutbag.and.cup.and.straw.fill"
        }
    }
}

nonisolated enum FoodSource: String, Codable, CaseIterable, Hashable, Sendable {
    case usdaFDC
    case barcode
    case manual
    case cached
    case photo
}

nonisolated enum BankSplit: String, Codable, CaseIterable, Hashable, Sendable {
    case sevenZero
    case sixOne
    case fiveTwo
    case fourThree
    case threeFour

    var bankingDayCount: Int {
        switch self {
        case .sevenZero: 7
        case .sixOne: 6
        case .fiveTwo: 5
        case .fourThree: 4
        case .threeFour: 3
        }
    }

    var offDayCount: Int { 7 - bankingDayCount }

    var displayName: String {
        switch self {
        case .sevenZero: "7 / 0"
        case .sixOne: "6 / 1"
        case .fiveTwo: "5 / 2"
        case .fourThree: "4 / 3"
        case .threeFour: "3 / 4"
        }
    }
}

nonisolated enum Weekday: Int, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    var id: Int { rawValue }

    var shortName: String {
        switch self {
        case .sunday: "Sun"
        case .monday: "Mon"
        case .tuesday: "Tue"
        case .wednesday: "Wed"
        case .thursday: "Thu"
        case .friday: "Fri"
        case .saturday: "Sat"
        }
    }

    var fullName: String {
        switch self {
        case .sunday: "Sunday"
        case .monday: "Monday"
        case .tuesday: "Tuesday"
        case .wednesday: "Wednesday"
        case .thursday: "Thursday"
        case .friday: "Friday"
        case .saturday: "Saturday"
        }
    }

    /// Start of the week (this weekday, used as the week-start setting) that contains `date` —
    /// i.e. the most recent occurrence of `self` on or before `date`, normalized to midnight.
    /// `Weekday.rawValue` matches `Calendar.component(.weekday:)` (Sun=1…Sat=7), and this reuses
    /// the same `(weekday - weekStart + 7) % 7` offset the plan math uses elsewhere.
    func startOfWeek(containing date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let offset = (weekday - rawValue + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: day) ?? day
    }
}

nonisolated enum WeightUnit: String, Codable, CaseIterable, Hashable, Sendable {
    case pounds
    case kilograms

    var suffix: String {
        switch self {
        case .pounds: "lb"
        case .kilograms: "kg"
        }
    }

    func convert(_ value: Double, to other: WeightUnit) -> Double {
        guard self != other else { return value }
        switch (self, other) {
        case (.pounds, .kilograms): return value * 0.45359237
        case (.kilograms, .pounds): return value / 0.45359237
        default: return value
        }
    }
}

nonisolated enum EnergyUnit: String, Codable, CaseIterable, Hashable, Sendable {
    case kilocalories

    var suffix: String { "kcal" }
}

// MARK: - AI Plan Analyzer inputs

/// Biological sex, used only by the AI Plan Analyzer's BMR formula (Mifflin–St Jeor needs a
/// sex constant). Not surfaced anywhere else in the app.
nonisolated enum BiologicalSex: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case male
    case female

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .male: "Male"
        case .female: "Female"
        }
    }
}

/// Everyday (non-exercise) movement level. Drives the BMR→TDEE multiplier. Deliberate
/// workouts are deliberately excluded here — they're tracked separately by the plan's
/// workout goal, so folding them into this multiplier would double-count exercise. This is
/// why an office worker who also works out is still "sedentary" for this input.
nonisolated enum NonExerciseActivityLevel: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case sedentary
    case light
    case moderate
    case high
    case veryHigh

    var id: String { rawValue }

    /// Physical Activity Level multiplier applied to BMR to estimate maintenance energy
    /// from daily movement only.
    var palMultiplier: Double {
        switch self {
        case .sedentary: 1.2
        case .light: 1.375
        case .moderate: 1.55
        case .high: 1.725
        case .veryHigh: 1.9
        }
    }

    var displayName: String {
        switch self {
        case .sedentary: "Sedentary"
        case .light: "Lightly active"
        case .moderate: "Moderately active"
        case .high: "Very active"
        case .veryHigh: "Extremely active"
        }
    }

    /// One-line description of the day-to-day movement (NOT workouts) each level represents.
    var detail: String {
        switch self {
        case .sedentary: "Desk job, little walking"
        case .light: "On your feet part of the day"
        case .moderate: "Walking or standing much of the day"
        case .high: "Physical job, moving most of the day"
        case .veryHigh: "Heavy labor, on the move all day"
        }
    }
}

/// How aggressively the user wants to lose weight. Maps to a target daily calorie deficit
/// below maintenance; `TDEECalculator` clamps the resulting net to a safe floor.
nonisolated enum WeightGoalPace: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case maintain
    case slow
    case moderate
    case aggressive

    var id: String { rawValue }

    /// Target daily calorie deficit below maintenance. `aggressive` is the requested ceiling;
    /// the actual net is additionally floored by `TDEECalculator.suggestedNet`.
    var dailyDeficit: Int {
        switch self {
        case .maintain: 0
        case .slow: 250
        case .moderate: 500
        case .aggressive: 1_000
        }
    }

    var displayName: String {
        switch self {
        case .maintain: "Maintain weight"
        case .slow: "Lose slowly"
        case .moderate: "Lose at a moderate pace"
        case .aggressive: "Lose as fast as is healthy"
        }
    }

    var detail: String {
        switch self {
        case .maintain: "Stay at your current weight"
        case .slow: "About ½ lb per week"
        case .moderate: "About 1 lb per week"
        case .aggressive: "Up to ~2 lb per week"
        }
    }
}
