import Foundation
import SwiftData

@Model
final class FoodEntry {
    var id: UUID = UUID()

    var name: String = ""
    var brand: String?

    /// The food's countable native unit ("bar", "slice", "ea") OR the bare measurement unit when
    /// the food is loose ("g", "ml"). Set when the food is created and never changes after that
    /// — the user can pick a different `selectedUnit` for any given log, but the food's identity
    /// stays anchored to this token.
    var nativeUnit: String = "ea"

    /// Mass of one native unit, in grams. 57 for an RX bar; 1 for "g"; nil for foods with no
    /// mass info (e.g. a non-quantified scoop).
    var nativeUnitGrams: Double?

    /// Volume of one native unit, in milliliters. 240 for "1 cup of milk"; 1 for "ml"; nil for
    /// solids.
    var nativeUnitMilliliters: Double?

    /// What the user picked in the portion sheet's unit dropdown for THIS entry. Could be the
    /// native unit ("bar"), or any compatible measurement unit ("g", "oz", "ml", "cup").
    var selectedUnit: String = "ea"

    /// The user's typed count. Always in `selectedUnit`. So 2 + "bar" = two bars; 114 + "g" =
    /// 114 grams; never bundled together as in the old model.
    var quantity: Double = 1

    /// Per-native-unit nutrients. caloriesPerServing × `nativeUnitsConsumed` = total calories.
    /// Names kept for code-search continuity; "serving" here always means "1 native unit".
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

    // MARK: - Legacy fields (kept for one-shot migration)
    //
    // These fields existed in the previous schema. Keeping them here as optionals lets SwiftData's
    // lightweight migration preserve the data on existing on-device stores — `LegacyDataMigrator`
    // reads them on first launch after the schema change, parses the description into the new
    // `nativeUnit` / `nativeUnitGrams` / `selectedUnit` / `quantity` fields, and then never touches
    // them again. New entries leave these nil. Safe to drop in a future schema cleanup once every
    // user has been migrated.
    var servingDescription: String?
    var servingSizeGrams: Double?
    var servingSizeMilliliters: Double?

    init(
        id: UUID = UUID(),
        name: String,
        brand: String? = nil,
        nativeUnit: String,
        nativeUnitGrams: Double? = nil,
        nativeUnitMilliliters: Double? = nil,
        selectedUnit: String,
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
        self.nativeUnit = nativeUnit
        self.nativeUnitGrams = nativeUnitGrams
        self.nativeUnitMilliliters = nativeUnitMilliliters
        self.selectedUnit = selectedUnit
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

    /// Native units consumed by this entry given the user's `selectedUnit` + `quantity`. The
    /// scalar that turns per-native nutrients into totals.
    var nativeUnitsConsumed: Double {
        ServingMath.nativeUnitsConsumed(
            selectedUnit: selectedUnit,
            quantity: quantity,
            nativeUnit: nativeUnit,
            nativeUnitGrams: nativeUnitGrams,
            nativeUnitMilliliters: nativeUnitMilliliters
        )
    }

    var totalCalories: Double { caloriesPerServing * nativeUnitsConsumed }
    var totalProtein: Double { proteinPerServing * nativeUnitsConsumed }
    var totalCarbs: Double { carbsPerServing * nativeUnitsConsumed }
    var totalFat: Double { fatPerServing * nativeUnitsConsumed }

    /// Row display: "{quantity} {selectedUnit}", no plurals. "2 bar", "114 g", "0.5 bar".
    var consumedDisplay: String {
        ServingMath.displayConsumed(quantity: quantity, unit: selectedUnit)
    }
}
