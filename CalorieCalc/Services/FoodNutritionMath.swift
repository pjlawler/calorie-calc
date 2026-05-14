import Foundation

/// Shared math for turning a user-entered serving (qty + unit + optional grams + macros) into
/// the per-native-unit representation stored on `CachedFood` and `FoodEntry`. Used by Manual
/// Entry, Edit Food, and Edit Entry — keeping the conversion in one place so the three sheets
/// derive identical native shapes from the same inputs.
nonisolated enum FoodNutritionMath {

    struct Identity {
        let nativeUnit: String
        let nativeUnitGrams: Double?
        let nativeUnitMilliliters: Double?
        let calsPerNative: Double
        let proteinPerNative: Double
        let carbsPerNative: Double
        let fatPerNative: Double
        /// The unit + quantity the user typed. Stored as the picker's initial preset so the
        /// food re-opens showing what the user actually entered.
        let initialSelectedUnit: String
        let initialSelectedQuantity: Double
    }

    /// Map the user's (amount + unit) + macros into the food's identity.
    /// - Mass unit (g/oz/lb/kg): native = "g", per-native = per-gram. `amount` converts to grams.
    /// - Volume unit (ml/fl oz/cup/...): native = "ml", per-native = per-ml.
    /// - Countable (bar/slice/ea/...): native = unit, per-native = per-one-named-unit.
    ///   `countableGrams` (optional) — gram weight of one named unit, e.g. "1 bar = 42 g".
    static func deriveIdentity(
        unit: String,
        quantity: Double,
        countableGrams: Double?,
        cals: Double,
        protein: Double,
        carbs: Double,
        fat: Double
    ) -> Identity {
        if ServingMath.isMassUnit(unit) {
            let totalGrams = ServingMath.grams(forSelectedUnit: unit, quantity: quantity) ?? quantity
            let divisor = totalGrams > 0 ? totalGrams : 1
            return Identity(
                nativeUnit: "g",
                nativeUnitGrams: 1,
                nativeUnitMilliliters: nil,
                calsPerNative: cals / divisor,
                proteinPerNative: protein / divisor,
                carbsPerNative: carbs / divisor,
                fatPerNative: fat / divisor,
                initialSelectedUnit: unit,
                initialSelectedQuantity: quantity
            )
        }
        if ServingMath.isVolumeUnit(unit) {
            let totalMl = ServingMath.milliliters(forSelectedUnit: unit, quantity: quantity) ?? quantity
            let divisor = totalMl > 0 ? totalMl : 1
            return Identity(
                nativeUnit: "ml",
                nativeUnitGrams: nil,
                nativeUnitMilliliters: 1,
                calsPerNative: cals / divisor,
                proteinPerNative: protein / divisor,
                carbsPerNative: carbs / divisor,
                fatPerNative: fat / divisor,
                initialSelectedUnit: unit,
                initialSelectedQuantity: quantity
            )
        }
        // Countable native — `quantity` is the count of one named unit (1 bar / 2 slice).
        let divisor = quantity > 0 ? quantity : 1
        let perUnitGrams: Double? = (countableGrams ?? 0) > 0 ? countableGrams : nil
        return Identity(
            nativeUnit: unit,
            nativeUnitGrams: perUnitGrams,
            nativeUnitMilliliters: nil,
            calsPerNative: cals / divisor,
            proteinPerNative: protein / divisor,
            carbsPerNative: carbs / divisor,
            fatPerNative: fat / divisor,
            initialSelectedUnit: unit,
            initialSelectedQuantity: quantity
        )
    }
}
