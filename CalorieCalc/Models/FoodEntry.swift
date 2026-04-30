import Foundation
import SwiftData

@Model
final class FoodEntry {
    var id: UUID = UUID()

    var name: String = ""
    var brand: String?

    var servingDescription: String = ""
    var servingSizeGrams: Double?
    var servingSizeMilliliters: Double?

    var quantity: Double = 1

    var caloriesPerServing: Double = 0
    var proteinPerServing: Double = 0
    var carbsPerServing: Double = 0
    var fatPerServing: Double = 0

    var saturatedFatPerServing: Double?
    var transFatPerServing: Double?
    var monounsaturatedFatPerServing: Double?
    var polyunsaturatedFatPerServing: Double?
    var cholesterolPerServing: Double?
    var sodiumPerServing: Double?
    var fiberPerServing: Double?
    var sugarsPerServing: Double?
    var addedSugarsPerServing: Double?

    var mealType: MealType = MealType.snack
    var source: FoodSource = FoodSource.manual
    var externalId: String?

    var notes: String?

    var timestamp: Date = Date()

    var dayLog: DayLog?

    init(
        id: UUID = UUID(),
        name: String,
        brand: String? = nil,
        servingDescription: String,
        servingSizeGrams: Double? = nil,
        servingSizeMilliliters: Double? = nil,
        quantity: Double = 1,
        caloriesPerServing: Double,
        proteinPerServing: Double = 0,
        carbsPerServing: Double = 0,
        fatPerServing: Double = 0,
        saturatedFatPerServing: Double? = nil,
        transFatPerServing: Double? = nil,
        monounsaturatedFatPerServing: Double? = nil,
        polyunsaturatedFatPerServing: Double? = nil,
        cholesterolPerServing: Double? = nil,
        sodiumPerServing: Double? = nil,
        fiberPerServing: Double? = nil,
        sugarsPerServing: Double? = nil,
        addedSugarsPerServing: Double? = nil,
        mealType: MealType,
        source: FoodSource,
        externalId: String? = nil,
        notes: String? = nil,
        timestamp: Date = .now,
        dayLog: DayLog? = nil
    ) {
        self.id = id
        self.name = name
        self.brand = brand
        self.servingDescription = servingDescription
        self.servingSizeGrams = servingSizeGrams
        self.servingSizeMilliliters = servingSizeMilliliters
        self.quantity = quantity
        self.caloriesPerServing = caloriesPerServing
        self.proteinPerServing = proteinPerServing
        self.carbsPerServing = carbsPerServing
        self.fatPerServing = fatPerServing
        self.saturatedFatPerServing = saturatedFatPerServing
        self.transFatPerServing = transFatPerServing
        self.monounsaturatedFatPerServing = monounsaturatedFatPerServing
        self.polyunsaturatedFatPerServing = polyunsaturatedFatPerServing
        self.cholesterolPerServing = cholesterolPerServing
        self.sodiumPerServing = sodiumPerServing
        self.fiberPerServing = fiberPerServing
        self.sugarsPerServing = sugarsPerServing
        self.addedSugarsPerServing = addedSugarsPerServing
        self.mealType = mealType
        self.source = source
        self.externalId = externalId
        self.notes = notes
        self.timestamp = timestamp
        self.dayLog = dayLog
    }

    var totalCalories: Double { caloriesPerServing * quantity }
    var totalProtein: Double { proteinPerServing * quantity }
    var totalCarbs: Double { carbsPerServing * quantity }
    var totalFat: Double { fatPerServing * quantity }

    /// Human-readable consumed serving — "2 bars", "200 g", "517 g", "1.34 cups". New entries
    /// (saved with the effective-serving model) have quantity≈1 and pass `servingDescription`
    /// through unchanged; legacy entries get the multiplication applied at render time, with
    /// fallbacks to total mass/volume when the description doesn't parse cleanly.
    var consumedDisplay: String {
        renderConsumedServing(
            description: servingDescription,
            quantity: quantity,
            grams: servingSizeGrams,
            milliliters: servingSizeMilliliters
        )
    }
}
