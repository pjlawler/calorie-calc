import Foundation

nonisolated struct FoodSearchResult: Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let brand: String?
    let servingDescription: String
    let servingSizeGrams: Double?
    let caloriesPerServing: Double
    let proteinPerServing: Double
    let carbsPerServing: Double
    let fatPerServing: Double
    let source: FoodSource
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
