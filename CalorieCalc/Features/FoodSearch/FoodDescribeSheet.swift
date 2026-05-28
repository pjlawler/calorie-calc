import SwiftUI

/// Free-text food search powered by Claude. User types a description ("Five Guys cheeseburger"),
/// the AI estimates a nutrition profile, and the sheet hands that back as a `FoodSearchResult`
/// so the normal portion sheet handles portion tweaks and logging.
struct FoodDescribeSheet: View {

    let onEstimated: (FoodSearchResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(FoodRecognitionEnvironment.self) private var env

    @State private var description: String = ""
    @State private var isWorking: Bool = false
    @State private var errorMessage: String?
    @State private var showPaywall: Bool = false

    private var canEstimate: Bool {
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Describe a food or meal", text: $description, axis: .vertical)
                        .lineLimit(2...6)
                        .textInputAutocapitalization(.sentences)
                        .disabled(isWorking)
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").foregroundStyle(.tint)
                        Text("AI description")
                    }
                } footer: {
                    Text("Examples: \"Five Guys cheeseburger\", \"medium Chipotle burrito bowl with chicken, rice, black beans\", \"homemade lasagna, one generous square\". Results are estimates — review before adding.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section {
                    Button { estimate() } label: {
                        HStack {
                            if isWorking { ProgressView().controlSize(.small) }
                            Text(isWorking ? "Estimating…" : "Estimate")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canEstimate)
                }
            }
            .navigationTitle("Describe Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
            }
            .sheet(isPresented: $showPaywall) { PaywallSheet() }
        }
    }

    private func estimate() {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorMessage = nil
        isWorking = true

        Task {
            do {
                let meal = try await env.service.estimate(description: trimmed)
                await MainActor.run {
                    isWorking = false
                    let result = makeSearchResult(from: meal, userDescription: trimmed)
                    onEstimated(result)
                    dismiss()
                }
            } catch FoodRecognitionError.outOfCredits {
                await MainActor.run {
                    isWorking = false
                    showPaywall = true
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    /// Bridges Claude's estimate into the normal search-result shape so the portion sheet can
    /// scale it just like a USDA or OFF lookup.
    private func makeSearchResult(from meal: RecognizedMeal, userDescription: String) -> FoodSearchResult {
        let useEach = RecognizedMeal.shouldUseEachServing(
            name: meal.name,
            portionDescription: meal.portionDescription,
            userText: userDescription
        )
        let portionRaw = meal.portionDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let isRecipe = RecognizedMeal.looksLikeRecipeExplanation(portionRaw)

        // Resolve native unit from the AI's portion text. Composite/recipe-style portions
        // collapse to "ea" with the verbose text appended to notes.
        var nativeUnit = "ea"
        var nativeUnitGrams: Double? = nil
        var nativeUnitMilliliters: Double? = nil
        var recipeNote: String? = nil
        /// How many natives a "serving" (Claude's caloriesPerServing) represents. For a "2 Tbsp"
        /// portion with native = "tbsp", a serving is 2 natives, so we divide per-serving values
        /// by 2 to get per-tbsp. Defaults to 1 (per-serving == per-native).
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
                if let grams = meal.servingGrams { nativeUnitGrams = grams / parsed.count }
            } else if ServingMath.isVolumeUnit(token),
                      let mlPerUnit = ServingMath.millilitersPerVolumeUnit[token] {
                // Volume-measurement portion ("2 Tbsp") — use the measurement as native so the
                // picker can show "1 tbsp" / "2 tbsp" / g / oz etc. Per-native nutrients come
                // from dividing the AI's per-serving values by parsed.count.
                nativeUnit = token
                nativeUnitMilliliters = mlPerUnit
                if let grams = meal.servingGrams, grams > 0 {
                    nativeUnitGrams = grams / parsed.count
                }
                nativesPerServing = parsed.count
            }
        }

        // Loose-mass fallback when AI gives grams but no countable unit and no volume anchor —
        // still expose mass siblings so the picker isn't just "ea".
        if nativeUnit == "ea", let grams = meal.servingGrams, grams > 0 {
            nativeUnit = "g"
            nativeUnitGrams = 1
        }

        let noteParts: [String?] = [
            recipeNote,
            meal.confidence.map { "AI estimate · \($0) confidence" },
            meal.notes
        ]
        let notes = noteParts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")

        // Per-native divisor. For loose mass (native "g"), divide by the serving's gram weight
        // so each gram gets the right per-gram value. For volume-measurement natives ("tbsp"),
        // divide by the natives-per-serving count we resolved above. Countable natives stay 1.
        let factor: Double = {
            if nativeUnit == "g" && nativeUnitGrams == 1 {
                return max(meal.servingGrams ?? 1, 1)
            }
            return max(nativesPerServing, 1)
        }()

        // Default the picker to the AI's reported serving. For loose-mass natives that's the
        // serving's gram weight; for volume-measurement natives ("tbsp") that's the
        // nativesPerServing count (so "2 Tbsp" opens as "2 tbsp", matching the package label
        // the AI quoted in the notes); for countable natives ("bar") that's 1. Claude is now
        // instructed to put the user's named quantity directly into `portion`, so we never
        // need to do a separate "intake" overlay anymore.
        let initialUnit: String = (nativeUnit == "g") ? "g" : nativeUnit
        let initialQty: Double = {
            if nativeUnit == "g" { return meal.servingGrams ?? 1 }
            if nativesPerServing > 1 { return nativesPerServing }
            return 1
        }()

        return FoodSearchResult(
            id: FoodSearchResult.localIdentityId(prefix: "ai", name: meal.name, brand: meal.brand),
            name: meal.name,
            brand: meal.brand,
            nativeUnit: nativeUnit,
            nativeUnitGrams: nativeUnitGrams,
            nativeUnitMilliliters: nativeUnitMilliliters,
            initialSelectedUnit: initialUnit,
            initialSelectedQuantity: initialQty,
            caloriesPerServing: meal.caloriesPerServing / factor,
            proteinPerServing: meal.proteinPerServing / factor,
            carbsPerServing: meal.carbsPerServing / factor,
            fatPerServing: meal.fatPerServing / factor,
            notes: notes.isEmpty ? nil : notes,
            source: .manual
        )
    }
}
