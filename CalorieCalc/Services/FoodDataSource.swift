import Foundation

nonisolated struct FoodSearchResult: Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let brand: String?
    let servingDescription: String
    /// Mass of one serving (for solid foods). Mutually exclusive with `servingSizeMilliliters`
    /// — a serving is either native-mass or native-volume, not both, since we don't know density.
    let servingSizeGrams: Double?
    /// Volume of one serving (for liquids). `nil` for solid foods.
    let servingSizeMilliliters: Double?
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
        servingDescription: String,
        servingSizeGrams: Double? = nil,
        servingSizeMilliliters: Double? = nil,
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
        self.servingDescription = servingDescription
        self.servingSizeGrams = servingSizeGrams
        self.servingSizeMilliliters = servingSizeMilliliters
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
