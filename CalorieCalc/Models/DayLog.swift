import Foundation
import SwiftData

@Model
final class DayLog {
    var id: UUID = UUID()
    var date: Date = Date()

    // CloudKit + SwiftData require to-many relationships to be optional. Default `[]` keeps
    // existing call sites that mutate via `dayLog.foodEntries.append(...)` working — SwiftData
    // unwraps + reassigns the optional behind the scenes. The `*List` accessors below give
    // read-only consumers a non-optional array.
    @Relationship(deleteRule: .cascade, inverse: \FoodEntry.dayLog)
    var foodEntries: [FoodEntry]? = []

    @Relationship(deleteRule: .cascade, inverse: \ManualWorkout.dayLog)
    var manualWorkouts: [ManualWorkout]? = []

    @Relationship(deleteRule: .cascade, inverse: \SupplementEntry.dayLog)
    var supplementEntries: [SupplementEntry]? = []

    init(id: UUID = UUID(), date: Date) {
        self.id = id
        self.date = Calendar.current.startOfDay(for: date)
    }

    /// Non-optional read accessors. Prefer these for math / display so callers don't have to
    /// remember to unwrap. Mutators still go through the stored optional properties.
    var foodEntriesList: [FoodEntry] { foodEntries ?? [] }
    var manualWorkoutsList: [ManualWorkout] { manualWorkouts ?? [] }
    var supplementEntriesList: [SupplementEntry] { supplementEntries ?? [] }

    var totalConsumedCalories: Double {
        foodEntriesList.reduce(0) { $0 + $1.totalCalories }
    }

    var totalProtein: Double { foodEntriesList.reduce(0) { $0 + $1.totalProtein } }
    var totalCarbs: Double { foodEntriesList.reduce(0) { $0 + $1.totalCarbs } }
    var totalFat: Double { foodEntriesList.reduce(0) { $0 + $1.totalFat } }

    var totalManualBurned: Double {
        manualWorkoutsList.reduce(0) { $0 + $1.caloriesBurned }
    }

    func entries(for meal: MealType) -> [FoodEntry] {
        foodEntriesList
            .filter { $0.mealType == meal }
            .sorted { $0.timestamp < $1.timestamp }
    }
}

extension DayLog {
    static func preferredForDay(
        _ logs: [DayLog],
        on date: Date,
        calendar: Calendar = .current
    ) -> DayLog? {
        preferred(in: logs.filter { calendar.isDate($0.date, inSameDayAs: date) })
    }

    static func preferred(in logs: [DayLog]) -> DayLog? {
        guard !logs.isEmpty else { return nil }
        return logs.max { lhs, rhs in
            if lhs.activityCount != rhs.activityCount {
                return lhs.activityCount < rhs.activityCount
            }
            return lhs.latestActivityTimestamp < rhs.latestActivityTimestamp
        }
    }

    var activityCount: Int {
        foodEntriesList.count + manualWorkoutsList.count
    }

    var latestActivityTimestamp: Date {
        let entryLatest = foodEntriesList.map(\.timestamp).max() ?? .distantPast
        let workoutLatest = manualWorkoutsList.map(\.timestamp).max() ?? .distantPast
        return max(entryLatest, workoutLatest)
    }
}
