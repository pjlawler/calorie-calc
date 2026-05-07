import Foundation

nonisolated struct RecognizedMeal: Sendable, Hashable {
    let name: String
    /// Brand / manufacturer for packaged foods (e.g. "Skippy"). nil for generic, restaurant,
    /// or home-cooked items where a brand doesn't apply.
    let brand: String?
    /// AI-supplied portion description. Three shapes:
    /// - Multi-item meals: exactly "1 meal" (with the breakdown of items in `notes`).
    /// - Single packaged item with a labeled serving: "2 Tbsp (32g)", "1 bar (52g)".
    /// - Single non-packaged item: "1 burger", "1 slice", "1 bowl".
    /// Used by the bridge layer to extract a `nativeUnit` and surface the verbose portion text
    /// in Notes when it's recipe-like.
    let portionDescription: String
    /// The actual quantity being logged when it's clearly known — from a user-typed quantity
    /// ("100g of peanut butter" → "100g"; "two bars" → "2 bars") or from a photo where a
    /// specific amount is visible. Format: "<number> <unit>". nil when the user didn't specify
    /// a quantity, in which case the bridge opens the picker at the canonical label serving.
    let intakeAmount: String?
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
    /// Estimate total nutrition + suggested yield options for a multi-ingredient recipe.
    /// Ingredients with `known*` macros (e.g. from a barcode scan) are scaled by their
    /// amount and used as hard data; ingredients without are estimated by the AI from
    /// name + amount + unit. Returned totals are for the WHOLE recipe; the caller picks
    /// one of the yield options to derive per-serving nutrition.
    func analyzeRecipe(_ input: RecipeAnalysisInput) async throws -> AnalyzedRecipe
}

/// Input to `FoodRecognitionService.analyzeRecipe` — recipe identity and ingredient list
/// (with optional pre-known nutrition for ingredients that came from a barcode lookup or
/// other authoritative source). The AI determines yield, so no servings count is supplied.
nonisolated struct RecipeAnalysisInput: Sendable {
    nonisolated struct Ingredient: Sendable {
        let name: String
        /// User-entered count of `unit`. e.g. amount=200, unit="g" → 200 g.
        let amount: Double
        let unit: String
        let brand: String?
        /// Known total nutrition for `amount` × `unit` of this ingredient (already scaled —
        /// the caller multiplied per-serving by amount for known foods). nil = AI estimates.
        let knownCalories: Double?
        let knownProtein: Double?
        let knownCarbs: Double?
        let knownFat: Double?
    }

    let recipeName: String
    let ingredients: [Ingredient]
}

/// One way to slice the recipe into servings — e.g. (amount=100, unit="g", servingsInRecipe=10)
/// describes 10 servings of 100 g each, totalling 1000 g of food. The caller multiplies
/// `amount × servingsInRecipe` to get the recipe's total quantity in `unit`s.
nonisolated struct RecipeYieldOption: Sendable, Hashable, Identifiable {
    var id: String { "\(amount)_\(unit)_\(servingsInRecipe)" }
    let amount: Double
    let unit: String
    let servingsInRecipe: Double
}

/// AI's analysis of a recipe — TOTAL nutrition (whole recipe) plus suggested yield options.
/// Per-serving nutrition is derived by the caller: total / chosen-option.servingsInRecipe.
nonisolated struct AnalyzedRecipe: Sendable, Hashable {
    let name: String
    let totalCalories: Double
    let totalProtein: Double
    let totalCarbs: Double
    let totalFat: Double
    let yieldOptions: [RecipeYieldOption]
    let confidence: String?
    let notes: String?
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
