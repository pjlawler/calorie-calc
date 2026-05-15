import Foundation
import SwiftData

@Model
final class UserProfile {
    var id: UUID = UUID()

    var dailyNetCalorieGoal: Int = 1_600
    var dailyGrossCalorieGoal: Int = 1_800
    var dailyWorkoutCalorieGoal: Int = 500

    var bankSplit: BankSplit = BankSplit.fiveTwo
    var weekStart: Weekday = Weekday.monday
    /// Legacy storage. Banking days are now derived from `weekStart` + `bankSplit` on the fly,
    /// so this value is ignored. Kept as a field so existing SwiftData stores migrate without loss.
    var bankingWeekdayRawValues: [Int] = []

    var weightUnit: WeightUnit = WeightUnit.pounds
    var energyUnit: EnergyUnit = EnergyUnit.kilocalories

    /// When `true`, the daily-log view surfaces a Supplements section between Snacks and
    /// Workouts and the picker sheet is reachable. Default off — opt-in for users who track
    /// vitamins/supplements separately from food.
    var tracksSupplements: Bool = false

    /// When `true`, the Progress tab's preset windows (7d/30d/etc.) end at today; when
    /// `false`, they end at yesterday and shift back one day so the same number of days
    /// is covered. Lets the user drop a still-developing morning weigh-in from the trend.
    var includesTodayInProgress: Bool = true

    var startingWeight: Double?
    var startingWeightLoggedAt: Date?
    var goalWeight: Double?

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        dailyNetCalorieGoal: Int = 1_600,
        dailyGrossCalorieGoal: Int = 1_800,
        dailyWorkoutCalorieGoal: Int = 500,
        bankSplit: BankSplit = .fiveTwo,
        weekStart: Weekday = .monday,
        weightUnit: WeightUnit = .pounds,
        energyUnit: EnergyUnit = .kilocalories,
        startingWeight: Double? = nil,
        startingWeightLoggedAt: Date? = nil,
        goalWeight: Double? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.dailyNetCalorieGoal = dailyNetCalorieGoal
        self.dailyGrossCalorieGoal = dailyGrossCalorieGoal
        self.dailyWorkoutCalorieGoal = dailyWorkoutCalorieGoal
        self.bankSplit = bankSplit
        self.weekStart = weekStart
        self.weightUnit = weightUnit
        self.energyUnit = energyUnit
        self.startingWeight = startingWeight
        self.startingWeightLoggedAt = startingWeightLoggedAt
        self.goalWeight = goalWeight
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Banking days are the first `bankSplit.bankingDayCount` weekdays starting at `weekStart`.
    /// E.g. week starts Sunday + 5/2 → banking = Sun–Thu, off = Fri, Sat.
    func isBankingDay(_ weekday: Weekday) -> Bool {
        let offset = (weekday.rawValue - weekStart.rawValue + 7) % 7
        return offset < bankSplit.bankingDayCount
    }

    var bankingWeekdays: Set<Weekday> {
        Set(Weekday.allCases.filter(isBankingDay))
    }

    var offWeekdays: Set<Weekday> {
        Set(Weekday.allCases).subtracting(bankingWeekdays)
    }
}
