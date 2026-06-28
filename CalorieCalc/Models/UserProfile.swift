import Foundation
import SwiftData

@Model
final class UserProfile {
    var id: UUID = UUID()

    var dailyNetCalorieGoal: Int = 2_000
    var dailyGrossCalorieGoal: Int = 1_800
    var dailyWorkoutCalorieGoal: Int = 150

    var bankSplit: BankSplit = BankSplit.sixOne
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
    var includesTodayInProgress: Bool = false

    var startingWeight: Double?
    var startingWeightLoggedAt: Date?
    var goalWeight: Double?

    // MARK: AI Plan Analyzer inputs
    // Biometrics the AI Plan Analyzer uses for calorie math (Mifflin–St Jeor) and to
    // prefill its form on a re-run. All optional so the feature stays opt-in and the
    // SwiftData/CloudKit store migrates without a manual step (scalars, so the CloudKit
    // optional-to-many rule doesn't apply). Enum-backed fields are stored as raw strings
    // and exposed through the typed computed accessors below.
    var heightCm: Double?
    var birthYear: Int?
    var biologicalSexRaw: String?
    var nonExerciseActivityRaw: String?
    var weightGoalPaceRaw: String?
    /// Last free-text preferences the user gave the analyzer, so re-runs prefill it.
    var planPreferencesNote: String?

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        dailyNetCalorieGoal: Int = 2_000,
        dailyGrossCalorieGoal: Int = 1_800,
        dailyWorkoutCalorieGoal: Int = 150,
        bankSplit: BankSplit = .sixOne,
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

    /// Copies every user-editable field from `other` onto this profile, leaving identity
    /// (`id`, `createdAt`) untouched. Used by `DataDeduplicator` to fold the most recently
    /// edited duplicate's values onto the canonical (earliest) row before deleting the rest,
    /// so a user's latest plan/settings survive the collapse instead of the stale first row.
    func copySettings(from other: UserProfile) {
        dailyNetCalorieGoal = other.dailyNetCalorieGoal
        dailyGrossCalorieGoal = other.dailyGrossCalorieGoal
        dailyWorkoutCalorieGoal = other.dailyWorkoutCalorieGoal
        bankSplit = other.bankSplit
        weekStart = other.weekStart
        bankingWeekdayRawValues = other.bankingWeekdayRawValues
        weightUnit = other.weightUnit
        energyUnit = other.energyUnit
        tracksSupplements = other.tracksSupplements
        includesTodayInProgress = other.includesTodayInProgress
        startingWeight = other.startingWeight
        startingWeightLoggedAt = other.startingWeightLoggedAt
        goalWeight = other.goalWeight
        heightCm = other.heightCm
        birthYear = other.birthYear
        biologicalSexRaw = other.biologicalSexRaw
        nonExerciseActivityRaw = other.nonExerciseActivityRaw
        weightGoalPaceRaw = other.weightGoalPaceRaw
        planPreferencesNote = other.planPreferencesNote
        updatedAt = other.updatedAt
    }

    // MARK: AI Plan Analyzer typed accessors

    /// Typed view over `biologicalSexRaw`. Stored raw so the schema migrates cleanly.
    var biologicalSex: BiologicalSex? {
        get { biologicalSexRaw.flatMap(BiologicalSex.init(rawValue:)) }
        set { biologicalSexRaw = newValue?.rawValue }
    }

    /// Typed view over `nonExerciseActivityRaw`.
    var nonExerciseActivity: NonExerciseActivityLevel? {
        get { nonExerciseActivityRaw.flatMap(NonExerciseActivityLevel.init(rawValue:)) }
        set { nonExerciseActivityRaw = newValue?.rawValue }
    }

    /// Typed view over `weightGoalPaceRaw`.
    var weightGoalPace: WeightGoalPace? {
        get { weightGoalPaceRaw.flatMap(WeightGoalPace.init(rawValue:)) }
        set { weightGoalPaceRaw = newValue?.rawValue }
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
