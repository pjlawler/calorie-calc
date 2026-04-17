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
