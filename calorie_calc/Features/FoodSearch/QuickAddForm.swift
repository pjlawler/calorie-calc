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
    @State private var servingUnit: PortionUnit = .grams
    @State private var notesText: String = ""

    /// Units offered on the Quick Add serving-size picker. Groups match the portion-sheet
    /// picker so a food the user creates in `lb` later shows up alongside `kg/g/oz` only.
    private let unitOptions: [PortionUnit] = [
        .each,
        .grams, .kilograms, .ounces, .pounds,
        .milliliters, .liters, .fluidOunces, .cups, .tablespoons, .teaspoons,
    ]

    private var calories: Double? { Double(caloriesText) }
    private var servingAmount: Double? {
        Double(servingAmountText.replacingOccurrences(of: ",", with: "."))
    }
    private var canSave: Bool {
        guard let cals = calories, cals > 0 else { return false }
        guard let amount = servingAmount, amount > 0 else { return false }
        return true
    }

    private var servingFooter: String {
        let amountText = servingAmountText.isEmpty ? "0" : servingAmountText
        let unitName = servingUnit.displayName(quantity: servingAmount ?? 1)
        switch servingUnit.family {
        case .mass:
            return "Enter the nutrition values for one \(amountText) \(unitName) serving. You can log partial or multiple servings later and convert to g / kg / oz / lb."
        case .volume:
            return "Enter the nutrition values for one \(amountText) \(unitName) serving. You can log partial or multiple servings later and convert to ml / L / fl oz / cups / tbsp / tsp."
        case .each:
            return "Enter the nutrition values for one \(unitName) of this item. Non-convertible — log in whole or partial units."
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
                            ForEach(unitOptions) { unit in
                                Text(unit.displayName(quantity: servingAmount ?? 1)).tag(unit)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
            } footer: {
                Text(servingFooter)
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
        let unitName = servingUnit.displayName(quantity: amount)
        let servingDescription = "\(formatAmount(amount)) \(unitName)"

        // Convert the user's (amount + unit) into the family's base unit so future logs can
        // be re-expressed in any compatible unit. `.each` has no base unit — both gram/ml
        // fields stay nil and the portion sheet will only show `.each` in the picker.
        let servingGrams: Double?
        let servingMilliliters: Double?
        switch servingUnit.family {
        case .mass:
            servingGrams = amount * servingUnit.baseMultiplier
            servingMilliliters = nil
        case .volume:
            servingGrams = nil
            servingMilliliters = amount * servingUnit.baseMultiplier
        case .each:
            servingGrams = nil
            servingMilliliters = nil
        }

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
