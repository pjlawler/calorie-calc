import Foundation

nonisolated struct RecognizedMeal: Sendable, Hashable {
    let name: String
    let portionDescription: String
    /// Estimated grams in one serving, when applicable (e.g. `200` for a cheeseburger). `nil` for
    /// items where a gram weight doesn't make sense (e.g. "1 small coffee") or when Claude can't
    /// estimate it confidently.
    let servingGrams: Double?
    let caloriesPerServing: Double
    let proteinPerServing: Double
    let carbsPerServing: Double
    let fatPerServing: Double
    let confidence: String?
    let notes: String?
}

protocol FoodRecognitionService: Sendable {
    func recognize(imageData: Data, hint: String?) async throws -> RecognizedMeal
    /// Estimate nutrition info from a free-text description like "Five Guys cheeseburger" or
    /// "medium Chipotle burrito bowl with chicken, rice, black beans".
    func estimate(description: String) async throws -> RecognizedMeal
}

nonisolated enum FoodRecognitionError: LocalizedError, Sendable {
    case missingAPIKey
    case invalidResponse
    case networkFailure(String)
    case noResult
    case overQuota(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "No Claude API key found. Add ANTHROPIC_API_KEY to Secrets.xcconfig."
        case .invalidResponse:
            "Claude returned an unexpected response."
        case .networkFailure(let message):
            "Network error: \(message)"
        case .noResult:
            "Claude couldn't identify a meal in this photo. Try a clearer shot or use Quick Add."
        case .overQuota(let message):
            "Claude rejected the request: \(message)"
        }
    }
}
