import Foundation
import SwiftData

@Model
final class CachedFood {
    // Defaults on every non-optional property are required so SwiftData lightweight migration
    // can populate values for rows from an older store schema. Without them, opening an existing
    // store fails with NSCocoaErrorDomain 134110.
    @Attribute(.unique) var id: UUID = UUID()

    var externalId: String?
    var name: String = ""
    var brand: String?

    /// Food's identity — the immutable picker label for "1 native unit". Mirrors `FoodEntry.nativeUnit`.
    var nativeUnit: String = "ea"
    var nativeUnitGrams: Double?
    var nativeUnitMilliliters: Double?

    /// Sticky picker preset: the unit + quantity the user picked the last time they logged this
    /// food. The portion sheet seeds its UI with these on next open. nil for foods that have
    /// never been logged (e.g. favorited but not consumed).
    var lastSelectedUnit: String?
    var lastSelectedQuantity: Double?

    /// Per-native-unit nutrients (1 bar's worth, 1 gram's worth, …).
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

    var source: FoodSource = FoodSource.manual
    var isFavorite: Bool = false
    var lastUsed: Date = Date()
    var useCount: Int = 0
    var notes: String?

    /// Locked favorite preset — captured the first time the user favorites this food and never
    /// overwritten by subsequent logs.
    var favoriteSelectedUnit: String?
    var favoriteSelectedQuantity: Double?

    // MARK: - Legacy fields (kept for one-shot migration)
    //
    // Pre-redesign schema fields. SwiftData's lightweight migration preserves them when they're
    // declared (as optional) in the new schema with the same names; `LegacyDataMigrator` reads
    // them on first launch after upgrade, parses into the new layout, then nothing touches them
    // again. Safe to drop in a future schema cleanup once every user has been migrated.
    var defaultServingDescription: String?
    var defaultServingSizeGrams: Double?
    var defaultServingSizeMilliliters: Double?
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
        nativeUnit: String,
        nativeUnitGrams: Double? = nil,
        nativeUnitMilliliters: Double? = nil,
        lastSelectedUnit: String? = nil,
        lastSelectedQuantity: Double? = nil,
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
        favoriteSelectedUnit: String? = nil,
        favoriteSelectedQuantity: Double? = nil
    ) {
        self.id = id
        self.externalId = externalId
        self.name = name
        self.brand = brand
        self.nativeUnit = nativeUnit
        self.nativeUnitGrams = nativeUnitGrams
        self.nativeUnitMilliliters = nativeUnitMilliliters
        self.lastSelectedUnit = lastSelectedUnit
        self.lastSelectedQuantity = lastSelectedQuantity
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
        self.favoriteSelectedUnit = favoriteSelectedUnit
        self.favoriteSelectedQuantity = favoriteSelectedQuantity
    }
}
