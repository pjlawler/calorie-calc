import Foundation

nonisolated struct RecognizedMeal: Sendable, Hashable {
    let name: String
    /// AI-supplied portion description like "1 bar", "1 burger", "1 medium bowl with chicken".
    /// Used by the bridge layer to extract a `nativeUnit` and surface the verbose portion text
    /// in Notes when it's recipe-like.
    let portionDescription: String
    /// Estimated grams of one *whole portion* — i.e. the mass of one "1 bar" / "1 burger". `nil`
    /// for items where a gram weight doesn't make sense (e.g. "1 small coffee") or when Claude
    /// can't estimate it confidently.
    let servingGrams: Double?
    /// Calories for the *whole portion* (e.g. for a 1-bar portion, this is total calories of
    /// that bar). The bridge divides by the parsed portion count to get per-native values.
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

extension RecognizedMeal {
    /// True when the AI's portion text reads as a recipe explanation (commas, multiple clauses,
    /// long phrasing) rather than a clean unit label like "1 bar" or "0.67 cup". Used to push
    /// the description into the entry's Notes field and use a generic "1 serving" label instead.
    static func looksLikeRecipeExplanation(_ portionDescription: String) -> Bool {
        let trimmed = portionDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.contains(",") { return true }
        let wordCount = trimmed.split(separator: " ").count
        return wordCount > 4
    }

    /// Heuristic for default serving behavior in the portion UI:
    /// - Composite or non-specific meal-like descriptions default to `.each`.
    /// - Clear single-item foods can keep weight/volume serving data.
    static func shouldUseEachServing(name: String, portionDescription: String, userText: String?) -> Bool {
        let combined = [name, portionDescription, userText ?? ""]
            .joined(separator: " ")
            .lowercased()

        let multiItemSignals = [
            " and ",
            " & ",
            " + ",
            " plus ",
            " with side",
            " side of "
        ]
        if multiItemSignals.contains(where: { combined.contains($0) }) {
            return true
        }

        let nonSpecificSignals = [
            "combo",
            "meal",
            "plate",
            "platter",
            "sampler",
            "assorted",
            "variety",
            "mixed"
        ]
        return nonSpecificSignals.contains(where: { combined.contains($0) })
    }
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
