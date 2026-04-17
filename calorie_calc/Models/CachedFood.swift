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

    var caloriesPerServing: Double
    var proteinPerServing: Double
    var carbsPerServing: Double
    var fatPerServing: Double

    var source: FoodSource
    var isFavorite: Bool
    var lastUsed: Date
    var useCount: Int

    init(
        id: UUID = UUID(),
        externalId: String? = nil,
        name: String,
        brand: String? = nil,
        defaultServingDescription: String,
        defaultServingSizeGrams: Double? = nil,
        caloriesPerServing: Double,
        proteinPerServing: Double = 0,
        carbsPerServing: Double = 0,
        fatPerServing: Double = 0,
        source: FoodSource,
        isFavorite: Bool = false,
        lastUsed: Date = .now,
        useCount: Int = 0
    ) {
        self.id = id
        self.externalId = externalId
        self.name = name
        self.brand = brand
        self.defaultServingDescription = defaultServingDescription
        self.defaultServingSizeGrams = defaultServingSizeGrams
        self.caloriesPerServing = caloriesPerServing
        self.proteinPerServing = proteinPerServing
        self.carbsPerServing = carbsPerServing
        self.fatPerServing = fatPerServing
        self.source = source
        self.isFavorite = isFavorite
        self.lastUsed = lastUsed
        self.useCount = useCount
    }
}
