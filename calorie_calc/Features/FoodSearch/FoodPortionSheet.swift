import SwiftUI
import SwiftData

struct FoodPortionSheet: View {

    let result: FoodSearchResult
    let mealType: MealType
    let date: Date
    let onLogged: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var dayLogs: [DayLog]
    @Query private var cachedFoods: [CachedFood]

    @State private var quantity: Double = 1

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(result.name).font(.headline)
                    if let brand = result.brand { Text(brand).font(.subheadline).foregroundStyle(.secondary) }
                    Text(result.servingDescription).font(.subheadline).foregroundStyle(.secondary)
                }

                Section("Quantity") {
                    Stepper(value: $quantity, in: 0.25...20, step: 0.25) {
                        HStack {
                            Text("Servings")
                            Spacer()
                            Text(quantity.formatted(.number.precision(.fractionLength(0...2))))
                                .monospacedDigit()
                        }
                    }
                }

                Section("Totals") {
                    LabeledContent("Calories") { Text("\(CalorieFormatter.whole(result.caloriesPerServing * quantity)) kcal").monospacedDigit() }
                    LabeledContent("Protein") { Text("\(CalorieFormatter.macro(result.proteinPerServing * quantity)) g").monospacedDigit() }
                    LabeledContent("Carbs") { Text("\(CalorieFormatter.macro(result.carbsPerServing * quantity)) g").monospacedDigit() }
                    LabeledContent("Fat") { Text("\(CalorieFormatter.macro(result.fatPerServing * quantity)) g").monospacedDigit() }
                }

                Section {
                    Button {
                        logEntry()
                    } label: {
                        Label("Add to \(mealType.displayName)", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .navigationTitle("Portion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func logEntry() {
        let log = ensureDayLog(for: date)
        let entry = FoodEntry(
            name: result.name,
            brand: result.brand,
            servingDescription: result.servingDescription,
            servingSizeGrams: result.servingSizeGrams,
            quantity: quantity,
            caloriesPerServing: result.caloriesPerServing,
            proteinPerServing: result.proteinPerServing,
            carbsPerServing: result.carbsPerServing,
            fatPerServing: result.fatPerServing,
            mealType: mealType,
            source: result.source,
            externalId: result.id,
            timestamp: Date(),
            dayLog: log
        )
        modelContext.insert(entry)
        upsertCached(from: result)
        try? modelContext.save()
        dismiss()
        onLogged()
    }

    private func ensureDayLog(for date: Date) -> DayLog {
        let day = Calendar.current.startOfDay(for: date)
        if let existing = dayLogs.first(where: { Calendar.current.isDate($0.date, inSameDayAs: day) }) {
            return existing
        }
        let new = DayLog(date: day)
        modelContext.insert(new)
        return new
    }

    private func upsertCached(from result: FoodSearchResult) {
        let id = result.id
        if let existing = cachedFoods.first(where: { $0.externalId == id }) {
            existing.lastUsed = .now
            existing.useCount += 1
        } else {
            let cached = CachedFood(
                externalId: id,
                name: result.name,
                brand: result.brand,
                defaultServingDescription: result.servingDescription,
                defaultServingSizeGrams: result.servingSizeGrams,
                caloriesPerServing: result.caloriesPerServing,
                proteinPerServing: result.proteinPerServing,
                carbsPerServing: result.carbsPerServing,
                fatPerServing: result.fatPerServing,
                source: result.source,
                lastUsed: .now,
                useCount: 1
            )
            modelContext.insert(cached)
        }
    }
}
