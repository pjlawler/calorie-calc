import Foundation
import SwiftData

@Model
final class CachedFood {
    @Attribute(.unique) var id: UUID

    var externalId: String?
    var name: String
    var brand: String?

    var defaultServingDescription: String
    var defaultServingSizeGrams: Double?
    var defaultServingSizeMilliliters: Double?

    var caloriesPerServing: Double
    var proteinPerServing: Double
    var carbsPerServing: Double
    var fatPerServing: Double

    var saturatedFatPerServing: Double?
    var transFatPerServing: Double?
    var monounsaturatedFatPerServing: Double?
    var polyunsaturatedFatPerServing: Double?
    var cholesterolPerServing: Double?
    var sodiumPerServing: Double?
    var fiberPerServing: Double?
    var sugarsPerServing: Double?
    var addedSugarsPerServing: Double?

    var source: FoodSource
    var isFavorite: Bool
    var lastUsed: Date
    var useCount: Int
    var notes: String?

    // Locked favorite snapshot — captured the first time the user favorites this food and never
    // overwritten by subsequent logs. Recents (the `default*` fields above) reflect the latest
    // log; the favorite snapshot reflects "the way the user originally saved it".
    var favoriteServingDescription: String?
    var favoriteServingSizeGrams: Double?
    var favoriteServingSizeMilliliters: Double?
    var favoriteCaloriesPerServing: Double?
    var favoriteProteinPerServing: Double?
    var favoriteCarbsPerServing: Double?
    var favoriteFatPerServing: Double?

    init(
        id: UUID = UUID(),
        externalId: String? = nil,
        name: String,
        brand: String? = nil,
        defaultServingDescription: String,
        defaultServingSizeGrams: Double? = nil,
        defaultServingSizeMilliliters: Double? = nil,
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
        source: FoodSource,
        isFavorite: Bool = false,
        lastUsed: Date = .now,
        useCount: Int = 0,
        notes: String? = nil,
        favoriteServingDescription: String? = nil,
        favoriteServingSizeGrams: Double? = nil,
        favoriteServingSizeMilliliters: Double? = nil,
        favoriteCaloriesPerServing: Double? = nil,
        favoriteProteinPerServing: Double? = nil,
        favoriteCarbsPerServing: Double? = nil,
        favoriteFatPerServing: Double? = nil
    ) {
        self.id = id
        self.externalId = externalId
        self.name = name
        self.brand = brand
        self.defaultServingDescription = defaultServingDescription
        self.defaultServingSizeGrams = defaultServingSizeGrams
        self.defaultServingSizeMilliliters = defaultServingSizeMilliliters
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
        self.source = source
        self.isFavorite = isFavorite
        self.lastUsed = lastUsed
        self.useCount = useCount
        self.notes = notes
        self.favoriteServingDescription = favoriteServingDescription
        self.favoriteServingSizeGrams = favoriteServingSizeGrams
        self.favoriteServingSizeMilliliters = favoriteServingSizeMilliliters
        self.favoriteCaloriesPerServing = favoriteCaloriesPerServing
        self.favoriteProteinPerServing = favoriteProteinPerServing
        self.favoriteCarbsPerServing = favoriteCarbsPerServing
        self.favoriteFatPerServing = favoriteFatPerServing
    }
}
