import Foundation
import SwiftData

@Model
final class DayLog {
    var id: UUID = UUID()
    var date: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \FoodEntry.dayLog)
    var foodEntries: [FoodEntry] = []

    @Relationship(deleteRule: .cascade, inverse: \ManualWorkout.dayLog)
    var manualWorkouts: [ManualWorkout] = []

    init(id: UUID = UUID(), date: Date) {
        self.id = id
        self.date = Calendar.current.startOfDay(for: date)
    }

    var totalConsumedCalories: Double {
        foodEntries.reduce(0) { $0 + $1.totalCalories }
    }

    var totalProtein: Double { foodEntries.reduce(0) { $0 + $1.totalProtein } }
    var totalCarbs: Double { foodEntries.reduce(0) { $0 + $1.totalCarbs } }
    var totalFat: Double { foodEntries.reduce(0) { $0 + $1.totalFat } }

    var totalManualBurned: Double {
        manualWorkouts.reduce(0) { $0 + $1.caloriesBurned }
    }

    func entries(for meal: MealType) -> [FoodEntry] {
        foodEntries
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
        foodEntries.count + manualWorkouts.count
    }

    var latestActivityTimestamp: Date {
        let entryLatest = foodEntries.map(\.timestamp).max() ?? .distantPast
        let workoutLatest = manualWorkouts.map(\.timestamp).max() ?? .distantPast
        return max(entryLatest, workoutLatest)
    }
}
