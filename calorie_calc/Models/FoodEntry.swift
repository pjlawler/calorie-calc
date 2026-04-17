import Foundation
import SwiftData

@Model
final class FoodEntry {
    @Attribute(.unique) var id: UUID

    var name: String
    var brand: String?

    var servingDescription: String
    var servingSizeGrams: Double?

    var quantity: Double

    var caloriesPerServing: Double
    var proteinPerServing: Double
    var carbsPerServing: Double
    var fatPerServing: Double

    var mealType: MealType
    var source: FoodSource
    var externalId: String?

    var timestamp: Date

    var dayLog: DayLog?

    init(
        id: UUID = UUID(),
        name: String,
        brand: String? = nil,
        servingDescription: String,
        servingSizeGrams: Double? = nil,
        quantity: Double = 1,
        caloriesPerServing: Double,
        proteinPerServing: Double = 0,
        carbsPerServing: Double = 0,
        fatPerServing: Double = 0,
        mealType: MealType,
        source: FoodSource,
        externalId: String? = nil,
        timestamp: Date = .now,
        dayLog: DayLog? = nil
    ) {
        self.id = id
        self.name = name
        self.brand = brand
        self.servingDescription = servingDescription
        self.servingSizeGrams = servingSizeGrams
        self.quantity = quantity
        self.caloriesPerServing = caloriesPerServing
        self.proteinPerServing = proteinPerServing
        self.carbsPerServing = carbsPerServing
        self.fatPerServing = fatPerServing
        self.mealType = mealType
        self.source = source
        self.externalId = externalId
        self.timestamp = timestamp
        self.dayLog = dayLog
    }

    var totalCalories: Double { caloriesPerServing * quantity }
    var totalProtein: Double { proteinPerServing * quantity }
    var totalCarbs: Double { carbsPerServing * quantity }
    var totalFat: Double { fatPerServing * quantity }
}
