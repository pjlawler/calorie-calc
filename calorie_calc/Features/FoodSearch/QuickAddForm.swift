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
    @State private var servingAmountText: String = "100"
    @State private var servingUnit: ServingBaseUnit = .grams
    @State private var notesText: String = ""

    private var calories: Double? { Double(caloriesText) }
    private var servingAmount: Double? {
        Double(servingAmountText.replacingOccurrences(of: ",", with: "."))
    }
    private var canSave: Bool {
        guard let cals = calories, cals > 0 else { return false }
        guard let amount = servingAmount, amount > 0 else { return false }
        return true
    }

    enum ServingBaseUnit: String, CaseIterable, Identifiable {
        case grams, milliliters
        var id: String { rawValue }
        var label: String {
            switch self { case .grams: "g"; case .milliliters: "ml" }
        }
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
                            Text("Not found — add manually")
                                .font(.subheadline.weight(.semibold))
                            Text("Barcode \(scannedBarcode) will be saved with this entry.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                LabeledContent("Serving Size") {
                    HStack(spacing: 8) {
                        TextField("Amount", text: $servingAmountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(minWidth: 60)
                        Picker("Unit", selection: $servingUnit) {
                            ForEach(ServingBaseUnit.allCases) { unit in
                                Text(unit.label).tag(unit)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
            } footer: {
                Text("Enter the nutrition values for one \(servingAmountText.isEmpty ? "0" : servingAmountText) \(servingUnit.label) serving. You can log partial or multiple servings later and convert to ounces, cups, tbsp, etc.")
            }

            Section("Nutrition") {
                macroField(label: "Calories", text: $caloriesText, suffix: "kcal")
                macroField(label: "Protein", text: $proteinText, suffix: "g")
                macroField(label: "Carbs", text: $carbsText, suffix: "g")
                macroField(label: "Fat", text: $fatText, suffix: "g")
            }

            Section("Notes") {
                TextField("Add notes — prep, source, tweaks…", text: $notesText, axis: .vertical)
                    .lineLimit(2...6)
            }

            Section {
                Button {
                    save()
                } label: {
                    Text("Add to \(mealType.displayName)")
                        .fontWeight(.semibold)
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
        guard let amount = servingAmount, amount > 0 else { return }
        let log = ensureDayLog()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? "Quick entry" : trimmedName
        let trimmedNotes = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedNotes: String? = trimmedNotes.isEmpty ? nil : trimmedNotes

        // Stable ID for the underlying "food" so Recents / Favorites / future edits all refer
        // back to the same CachedFood regardless of how many times the user logs it.
        let externalId: String = scannedBarcode ?? "manual:\(UUID().uuidString)"
        let servingGrams: Double? = servingUnit == .grams ? amount : nil
        let servingMilliliters: Double? = servingUnit == .milliliters ? amount : nil
        let servingDescription = "\(formatAmount(amount)) \(servingUnit.label)"

        let entry = FoodEntry(
            name: resolvedName,
            brand: nil,
            servingDescription: servingDescription,
            servingSizeGrams: servingGrams,
            servingSizeMilliliters: servingMilliliters,
            quantity: 1,
            caloriesPerServing: cals,
            proteinPerServing: Double(proteinText) ?? 0,
            carbsPerServing: Double(carbsText) ?? 0,
            fatPerServing: Double(fatText) ?? 0,
            mealType: mealType,
            source: scannedBarcode != nil ? .barcode : .manual,
            externalId: externalId,
            notes: storedNotes,
            timestamp: Date(),
            dayLog: log
        )
        modelContext.insert(entry)
        upsertCached(
            externalId: externalId,
            name: resolvedName,
            servingDescription: servingDescription,
            servingSizeGrams: servingGrams,
            servingSizeMilliliters: servingMilliliters,
            calories: cals,
            protein: Double(proteinText) ?? 0,
            carbs: Double(carbsText) ?? 0,
            fat: Double(fatText) ?? 0,
            notes: storedNotes,
            source: entry.source
        )
        try? modelContext.save()
        onSaved()
    }

    @Query private var cachedFoods: [CachedFood]

    private func upsertCached(
        externalId: String,
        name: String,
        servingDescription: String,
        servingSizeGrams: Double?,
        servingSizeMilliliters: Double?,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double,
        notes: String?,
        source: FoodSource
    ) {
        if let existing = cachedFoods.first(where: { $0.externalId == externalId }) {
            existing.lastUsed = .now
            existing.useCount += 1
            existing.notes = notes
            return
        }
        let cached = CachedFood(
            externalId: externalId,
            name: name,
            brand: nil,
            defaultServingDescription: servingDescription,
            defaultServingSizeGrams: servingSizeGrams,
            defaultServingSizeMilliliters: servingSizeMilliliters,
            caloriesPerServing: calories,
            proteinPerServing: protein,
            carbsPerServing: carbs,
            fatPerServing: fat,
            source: source,
            lastUsed: .now,
            useCount: 1,
            notes: notes
        )
        modelContext.insert(cached)
    }

    private func formatAmount(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : value.formatted(.number.precision(.fractionLength(0...2)))
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
