import SwiftUI
import SwiftData

/// Standalone sheet wrapper around `QuickAddForm` — wraps it in a nav stack with Cancel /
/// contextual title so it presents cleanly from the Add-to-meal sheet's toolbar.
struct QuickAddSheet: View {
    let mealType: MealType
    let date: Date
    var scannedBarcode: String? = nil
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QuickAddForm(
                mealType: mealType,
                date: date,
                scannedBarcode: scannedBarcode,
                onSaved: onSaved
            )
            .navigationTitle("Quick Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct QuickAddForm: View {

    let mealType: MealType
    let date: Date
    var scannedBarcode: String? = nil
    let onSaved: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query private var dayLogs: [DayLog]

    @State private var name: String = ""
    @State private var caloriesText: String = ""
    @State private var proteinText: String = ""
    @State private var carbsText: String = ""
    @State private var fatText: String = ""
    @State private var servingText: String = ""

    private var calories: Double? { Double(caloriesText) }
    private var canSave: Bool {
        guard let cals = calories else { return false }
        return cals > 0
    }

    var body: some View {
        Form {
            if let scannedBarcode {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "barcode.viewfinder")
                            .foregroundStyle(.tint)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Not in USDA — add manually")
                                .font(.subheadline.weight(.semibold))
                            Text("Barcode \(scannedBarcode) will be saved with this entry.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                TextField("Name (optional)", text: $name)
                    .textInputAutocapitalization(.words)
                TextField("Serving (e.g., 1 cup, 1 slice)", text: $servingText)
            } footer: {
                Text("Use this to log a food without searching — handy for restaurants, homemade meals, or label scans.")
            }

            Section("Nutrition") {
                macroField(label: "Calories", text: $caloriesText, suffix: "kcal")
                macroField(label: "Protein", text: $proteinText, suffix: "g")
                macroField(label: "Carbs", text: $carbsText, suffix: "g")
                macroField(label: "Fat", text: $fatText, suffix: "g")
            }

            Section {
                Button {
                    save()
                } label: {
                    Label("Add to \(mealType.displayName)", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSave)
            }
        }
    }

    private func macroField(label: String, text: Binding<String>, suffix: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(maxWidth: 100)
            Text(suffix)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
        }
    }

    private func save() {
        guard let cals = calories, cals > 0 else { return }
        let log = ensureDayLog()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedServing = servingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = FoodEntry(
            name: trimmedName.isEmpty ? "Quick entry" : trimmedName,
            brand: nil,
            servingDescription: trimmedServing.isEmpty ? "1 serving" : trimmedServing,
            servingSizeGrams: nil,
            quantity: 1,
            caloriesPerServing: cals,
            proteinPerServing: Double(proteinText) ?? 0,
            carbsPerServing: Double(carbsText) ?? 0,
            fatPerServing: Double(fatText) ?? 0,
            mealType: mealType,
            source: scannedBarcode != nil ? .barcode : .manual,
            externalId: scannedBarcode,
            timestamp: Date(),
            dayLog: log
        )
        modelContext.insert(entry)
        try? modelContext.save()
        onSaved()
    }

    private func ensureDayLog() -> DayLog {
        let day = Calendar.current.startOfDay(for: date)
        if let existing = dayLogs.first(where: { Calendar.current.isDate($0.date, inSameDayAs: day) }) {
            return existing
        }
        let new = DayLog(date: day)
        modelContext.insert(new)
        return new
    }
}
