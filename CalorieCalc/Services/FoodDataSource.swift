import Foundation

/// A food returned from a search, barcode lookup, or AI estimate. Carries the food's identity
/// (`nativeUnit` + per-native nutrients) plus an *initial* picker preset (`initialSelectedUnit`,
/// `initialSelectedQuantity`) the portion sheet uses on first open.
nonisolated struct FoodSearchResult: Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let brand: String?

    let nativeUnit: String
    /// Mass of one native unit, in grams. nil for volume-native or pure-each foods.
    let nativeUnitGrams: Double?
    /// Volume of one native unit, in milliliters. nil for solids and pure-each foods.
    let nativeUnitMilliliters: Double?

    /// Picker preset on first open. Usually equal to `nativeUnit` with quantity = 1; for loose
    /// foods (`nativeUnit == "g"`/"ml"), can be a sensible default like 100. Per-food sources
    /// can override this when a Cached/Favorite food has a sticky preference.
    let initialSelectedUnit: String
    let initialSelectedQuantity: Double

    let caloriesPerServing: Double
    let proteinPerServing: Double
    let carbsPerServing: Double
    let fatPerServing: Double
    let saturatedFatPerServing: Double?
    let transFatPerServing: Double?
    let monounsaturatedFatPerServing: Double?
    let polyunsaturatedFatPerServing: Double?
    /// Milligrams.
    let cholesterolPerServing: Double?
    /// Milligrams.
    let sodiumPerServing: Double?
    let fiberPerServing: Double?
    let sugarsPerServing: Double?
    let addedSugarsPerServing: Double?
    let notes: String?
    let source: FoodSource

    init(
        id: String,
        name: String,
        brand: String? = nil,
        nativeUnit: String,
        nativeUnitGrams: Double? = nil,
        nativeUnitMilliliters: Double? = nil,
        initialSelectedUnit: String? = nil,
        initialSelectedQuantity: Double? = nil,
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
        notes: String? = nil,
        source: FoodSource
    ) {
        self.id = id
        self.name = name
        self.brand = brand
        self.nativeUnit = nativeUnit
        self.nativeUnitGrams = nativeUnitGrams
        self.nativeUnitMilliliters = nativeUnitMilliliters
        // Default the initial unit/quantity to "1 native" — works for countable natives. Loose
        // foods that want a smarter default (100 g) override these in the source-specific shim.
        self.initialSelectedUnit = initialSelectedUnit ?? nativeUnit
        self.initialSelectedQuantity = initialSelectedQuantity ?? 1
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
        self.notes = notes
        self.source = source
    }
}

extension FoodSearchResult {
    /// Search-row caption: "1 bar (57g)" / "100 g" / "1 ea". For countable natives we surface the
    /// implicit count of 1 to match labels users see in the wild ("1 bar"). For loose foods we
    /// show the initial-selected default so the row reads naturally ("100 g").
    var rowCaption: String {
        let nativeIsMeasurement = ServingMath.isMeasurementUnit(nativeUnit)
        if !nativeIsMeasurement {
            if let g = nativeUnitGrams, g > 0 {
                return "1 \(nativeUnit) (\(formatNumber(g))g)"
            }
            if let ml = nativeUnitMilliliters, ml > 0 {
                return "1 \(nativeUnit) (\(formatNumber(ml))ml)"
            }
            return "1 \(nativeUnit)"
        }
        return ServingMath.displayConsumed(quantity: initialSelectedQuantity, unit: initialSelectedUnit)
    }
}

protocol FoodDataSource: Sendable {
    func search(query: String) async throws -> [FoodSearchResult]
    func details(for id: String) async throws -> FoodSearchResult
    func lookup(barcode: String) async throws -> FoodSearchResult?
}

nonisolated enum FoodDataSourceError: LocalizedError, Sendable {
    case missingAPIKey
    case invalidResponse
    case networkFailure(String)
    case notFound

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "No USDA API key found. Copy Secrets.xcconfig.example to Secrets.xcconfig and set USDA_API_KEY, then set that file as the target's base configuration."
        case .invalidResponse:
            "The food database returned an unexpected response."
        case .networkFailure(let message):
            "Network error: \(message)"
        case .notFound:
            "No matching food was found."
        }
    }
}
