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
