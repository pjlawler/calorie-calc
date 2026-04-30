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
        var recipeNote: String? = nil

        if useEach || isRecipe {
            recipeNote = isRecipe ? portionRaw : nil
        } else if let parsed = ServingMath.parseServingDescription(portionRaw),
                  parsed.count > 0,
                  !parsed.unit.isEmpty {
            let token = ServingMath.normalizeUnitToken(parsed.unit)
            if !token.isEmpty && !ServingMath.isMeasurementUnit(token) {
                nativeUnit = token
                if let grams = meal.servingGrams { nativeUnitGrams = grams / parsed.count }
            }
        }

        // For loose-mass fallback when AI gives grams but no countable unit, still expose mass
        // siblings so the picker isn't just "ea".
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

        // For loose-mass nativization, scale per-serving nutrients to per-gram.
        let factor: Double = (nativeUnit == "g" && nativeUnitGrams == 1)
            ? max(meal.servingGrams ?? 1, 1)
            : 1
        return FoodSearchResult(
            id: "ai:\(UUID().uuidString)",
            name: meal.name,
            brand: nil,
            nativeUnit: nativeUnit,
            nativeUnitGrams: nativeUnitGrams,
            nativeUnitMilliliters: nil,
            initialSelectedUnit: nativeUnit == "g" ? "g" : nativeUnit,
            initialSelectedQuantity: nativeUnit == "g" ? (meal.servingGrams ?? 1) : 1,
            caloriesPerServing: meal.caloriesPerServing / factor,
            proteinPerServing: meal.proteinPerServing / factor,
            carbsPerServing: meal.carbsPerServing / factor,
            fatPerServing: meal.fatPerServing / factor,
            notes: notes.isEmpty ? nil : notes,
            source: .manual
        )
    }
}
