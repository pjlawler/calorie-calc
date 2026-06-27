import DeviceCheck
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
    /// What the user is logging. If they named a specific quantity in the description, this IS
    /// that quantity verbatim ("100g", "2 bars", "8 fl oz"). Otherwise it's the canonical
    /// label serving ("2 Tbsp (32g)", "1 bar (52g)") for the AI's identified food. Either way,
    /// the macros below are for exactly this portion — no separate "intake" scaling needed.
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
    /// Estimate total nutrition + suggested yield options for a multi-ingredient recipe.
    /// Ingredients with `known*` macros (e.g. from a barcode scan) are scaled by their
    /// amount and used as hard data; ingredients without are estimated by the AI from
    /// name + amount + unit. Returned totals are for the WHOLE recipe; the caller picks
    /// one of the yield options to derive per-serving nutrition.
    func analyzeRecipe(_ input: RecipeAnalysisInput) async throws -> AnalyzedRecipe
    /// Transcribe a recipe from one or more images (a photo, document scan, or rendered PDF
    /// pages) into its name + ingredient list + optional yield, to prefill the analyzer. This
    /// only reads the recipe — nutrition is estimated separately via `analyzeRecipe`.
    func importRecipe(images: [Data]) async throws -> ImportedRecipe
}

/// One ingredient transcribed from a recipe image by `importRecipe`.
nonisolated struct ImportedIngredient: Sendable, Hashable {
    let name: String
    let amount: Double
    let unit: String
    let brand: String?
}

/// A recipe transcribed from one or more images — the ingredient list plus identity / yield
/// info used to prefill the Recipe Analyzer's build stage for the user to review.
nonisolated struct ImportedRecipe: Sendable, Hashable {
    let name: String
    let ingredients: [ImportedIngredient]
    let servingAmount: Double?
    let servingUnit: String?
    let notes: String?
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

    /// Bridges a recognized meal (photo recognition or text estimate) into the search-result
    /// shape so the portion sheet can scale + log it like any USDA/OFF lookup. Centralizing
    /// this keeps the photo and describe flows identical — including resolving countable units
    /// with gram weights ("1 bar (52g)" → native "bar" @ 52g) and the loose-mass fallback.
    func toSearchResult(userText: String?, source: FoodSource = .manual) -> FoodSearchResult {
        let useEach = RecognizedMeal.shouldUseEachServing(
            name: name,
            portionDescription: portionDescription,
            userText: userText
        )
        let portionRaw = portionDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let isRecipe = RecognizedMeal.looksLikeRecipeExplanation(portionRaw)

        var nativeUnit = "ea"
        var nativeUnitGrams: Double? = nil
        var nativeUnitMilliliters: Double? = nil
        var recipeNote: String? = nil
        var nativesPerServing: Double = 1

        if useEach || isRecipe {
            recipeNote = isRecipe ? portionRaw : nil
        } else if let parsed = ServingMath.parseServingDescription(portionRaw),
                  parsed.count > 0,
                  !parsed.unit.isEmpty {
            let token = ServingMath.normalizeUnitToken(parsed.unit)
            if !token.isEmpty && !ServingMath.isMeasurementUnit(token) {
                // Countable noun like "1 bar", "1 burger".
                nativeUnit = token
                if let grams = servingGrams { nativeUnitGrams = grams / parsed.count }
            } else if ServingMath.isVolumeUnit(token),
                      let mlPerUnit = ServingMath.millilitersPerVolumeUnit[token] {
                // Volume-measurement portion ("2 Tbsp").
                nativeUnit = token
                nativeUnitMilliliters = mlPerUnit
                if let grams = servingGrams, grams > 0 {
                    nativeUnitGrams = grams / parsed.count
                }
                nativesPerServing = parsed.count
            }
        }

        // Loose-mass fallback when AI gives grams but no countable unit and no volume anchor.
        if nativeUnit == "ea", let grams = servingGrams, grams > 0 {
            nativeUnit = "g"
            nativeUnitGrams = 1
        }

        let noteParts: [String?] = [
            recipeNote,
            confidence.map { "AI estimate · \($0) confidence" },
            notes
        ]
        let resolvedNotes = noteParts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")

        let factor: Double = {
            if nativeUnit == "g" && nativeUnitGrams == 1 {
                return max(servingGrams ?? 1, 1)
            }
            return max(nativesPerServing, 1)
        }()

        let initialUnit: String = (nativeUnit == "g") ? "g" : nativeUnit
        let initialQty: Double = {
            if nativeUnit == "g" { return servingGrams ?? 1 }
            if nativesPerServing > 1 { return nativesPerServing }
            return 1
        }()

        let idPrefix = (source == .photo) ? "photo" : "ai"
        return FoodSearchResult(
            id: FoodSearchResult.localIdentityId(prefix: idPrefix, name: name, brand: brand),
            name: name,
            brand: brand,
            nativeUnit: nativeUnit,
            nativeUnitGrams: nativeUnitGrams,
            nativeUnitMilliliters: nativeUnitMilliliters,
            initialSelectedUnit: initialUnit,
            initialSelectedQuantity: initialQty,
            caloriesPerServing: caloriesPerServing / factor,
            proteinPerServing: proteinPerServing / factor,
            carbsPerServing: carbsPerServing / factor,
            fatPerServing: fatPerServing / factor,
            notes: resolvedNotes.isEmpty ? nil : resolvedNotes,
            source: source
        )
    }
}

nonisolated enum FoodRecognitionError: LocalizedError, Sendable {
    case missingAPIKey
    case invalidResponse
    case networkFailure(String)
    case noResult
    case overQuota(String)
    case outOfCredits
    case deviceVerificationFailed

    /// Maps a low-level thrown error to the right case. App Attest (`DCError`) failures get a
    /// friendly device-verification message instead of leaking Apple's raw
    /// "com.apple.devicecheck.error error 2" string into the UI. The assertion path already
    /// self-heals once (see AppAttestService.signedAssertion); this only surfaces when that
    /// retry also fails.
    static func from(_ error: Error) -> FoodRecognitionError {
        if error is DCError { return .deviceVerificationFailed }
        return .networkFailure(error.localizedDescription)
    }

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "AI features are unavailable on this device right now. Please try again later."
        case .invalidResponse:
            "Claude returned an unexpected response."
        case .networkFailure(let message):
            "Network error: \(message)"
        case .noResult:
            "Claude couldn't identify a meal in this photo. Try a clearer shot or use Manual Entry."
        case .overQuota(let message):
            "Claude rejected the request: \(message)"
        case .outOfCredits:
            "Out of AI credits. Watch a short ad to earn more, or upgrade for unlimited."
        case .deviceVerificationFailed:
            "Couldn't verify your device with Apple. Please try again in a moment."
        }
    }
}
