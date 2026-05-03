import SwiftUI
import SwiftData

/// Standalone sheet wrapper around `QuickAddForm` — wraps it in a nav stack with Cancel /
/// contextual title so it presents cleanly from the Add-to-meal sheet's toolbar.
struct QuickAddSheet: View {
    let mealType: MealType
    let date: Date
    var scannedBarcode: String? = nil
    var addToMyFoods: Bool = false
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QuickAddForm(
                mealType: mealType,
                date: date,
                scannedBarcode: scannedBarcode,
                addToMyFoods: addToMyFoods,
                onSaved: onSaved
            )
            .navigationTitle("Manual Entry")
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
    var addToMyFoods: Bool = false
    let onSaved: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query private var dayLogs: [DayLog]

    @State private var name: String = ""
    @State private var brandText: String = ""
    @State private var caloriesText: String = ""
    @State private var proteinText: String = ""
    @State private var carbsText: String = ""
    @State private var fatText: String = ""
    @State private var quantityText: String = "100"
    @State private var unit: String = "g"
    @State private var notesText: String = ""

    /// Units offered on the Quick Add picker. Mirrors the portion-sheet picker so a food the
    /// user creates as "g" later gives g/oz/lb conversions, "ml" gives the volume ladder, and
    /// custom names ("bar", "bowl") become countable natives with no conversion.
    private let unitOptions: [String] = [
        "g", "oz", "lb", "kg",
        "ml", "fl oz", "cup", "tbsp", "tsp", "l",
        "ea", "bar", "slice", "piece", "bowl", "package", "batch",
    ]

    private var calories: Double? { Double(caloriesText) }
    private var quantity: Double? {
        Double(quantityText.replacingOccurrences(of: ",", with: "."))
    }
    private var canSave: Bool {
        guard let cals = calories, cals > 0 else { return false }
        guard let amount = quantity, amount > 0 else { return false }
        return true
    }

    private var quantityFooter: String {
        if ServingMath.isMassUnit(unit) {
            return "Enter the nutrition values for one \(quantityText.isEmpty ? "0" : quantityText) \(unit) serving. You'll be able to convert between g / oz / lb / kg later."
        }
        if ServingMath.isVolumeUnit(unit) {
            return "Enter the nutrition values for one \(quantityText.isEmpty ? "0" : quantityText) \(unit) serving. You'll be able to convert between ml / fl oz / cup / tbsp / tsp / L later."
        }
        return "Enter the nutrition values for one \(unit). You can log multiple or partial \(unit)s later."
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
                TextField("Brand (optional)", text: $brandText)
                    .textInputAutocapitalization(.words)
                LabeledContent("Serving") {
                    HStack(spacing: 8) {
                        TextField("Amount", text: $quantityText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(minWidth: 60)
                        Picker("Unit", selection: $unit) {
                            ForEach(unitOptions, id: \.self) { option in
                                Text(option).tag(option)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
            } footer: {
                Text(quantityFooter)
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
                    Text(addToMyFoods ? "Save to My Foods" : "Add to \(mealType.displayName)")
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
        guard let amount = quantity, amount > 0 else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? "Quick entry" : trimmedName
        let trimmedBrand = brandText.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedBrand: String? = trimmedBrand.isEmpty ? nil : trimmedBrand
        let trimmedNotes = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedNotes: String? = trimmedNotes.isEmpty ? nil : trimmedNotes

        let externalId: String = scannedBarcode ?? "manual:\(UUID().uuidString)"
        let protein = Double(proteinText) ?? 0
        let carbs = Double(carbsText) ?? 0
        let fat = Double(fatText) ?? 0

        // Map the user's (amount + unit) into the food's identity.
        // - Mass unit (g/oz/...): native = "g", per-native = per-gram. amount is in those mass
        //   units; we convert to grams for the per-native scale factor.
        // - Volume unit: native = "ml", per-native = per-ml.
        // - Countable (bar/slice/ea): native = unit, per-native = per-bar; amount stays.
        let nativeUnit: String
        let nativeUnitGrams: Double?
        let nativeUnitMilliliters: Double?
        let calsPerNative: Double
        let proteinPerNative: Double
        let carbsPerNative: Double
        let fatPerNative: Double
        let initialSelectedUnit: String
        let initialSelectedQuantity: Double

        if ServingMath.isMassUnit(unit) {
            let totalGrams = (ServingMath.grams(forSelectedUnit: unit, quantity: amount)) ?? amount
            nativeUnit = "g"
            nativeUnitGrams = 1
            nativeUnitMilliliters = nil
            calsPerNative = cals / totalGrams
            proteinPerNative = protein / totalGrams
            carbsPerNative = carbs / totalGrams
            fatPerNative = fat / totalGrams
            initialSelectedUnit = unit
            initialSelectedQuantity = amount
        } else if ServingMath.isVolumeUnit(unit) {
            let totalMl = (ServingMath.milliliters(forSelectedUnit: unit, quantity: amount)) ?? amount
            nativeUnit = "ml"
            nativeUnitGrams = nil
            nativeUnitMilliliters = 1
            calsPerNative = cals / totalMl
            proteinPerNative = protein / totalMl
            carbsPerNative = carbs / totalMl
            fatPerNative = fat / totalMl
            initialSelectedUnit = unit
            initialSelectedQuantity = amount
        } else {
            // Countable native — amount is the count of one named unit (1 bar / 2 slice).
            nativeUnit = unit
            nativeUnitGrams = nil
            nativeUnitMilliliters = nil
            calsPerNative = cals / amount
            proteinPerNative = protein / amount
            carbsPerNative = carbs / amount
            fatPerNative = fat / amount
            initialSelectedUnit = unit
            initialSelectedQuantity = amount
        }

        let entrySource: FoodSource = scannedBarcode != nil ? .barcode : .manual
        if !addToMyFoods {
            let log = ensureDayLog()
            let entry = FoodEntry(
                name: resolvedName,
                brand: storedBrand,
                nativeUnit: nativeUnit,
                nativeUnitGrams: nativeUnitGrams,
                nativeUnitMilliliters: nativeUnitMilliliters,
                selectedUnit: initialSelectedUnit,
                quantity: initialSelectedQuantity,
                caloriesPerServing: calsPerNative,
                proteinPerServing: proteinPerNative,
                carbsPerServing: carbsPerNative,
                fatPerServing: fatPerNative,
                mealType: mealType,
                source: entrySource,
                externalId: externalId,
                notes: storedNotes,
                timestamp: Date(),
                dayLog: log
            )
            modelContext.insert(entry)
        }
        upsertCached(
            externalId: externalId,
            name: resolvedName,
            brand: storedBrand,
            nativeUnit: nativeUnit,
            nativeUnitGrams: nativeUnitGrams,
            nativeUnitMilliliters: nativeUnitMilliliters,
            initialSelectedUnit: initialSelectedUnit,
            initialSelectedQuantity: initialSelectedQuantity,
            calsPerNative: calsPerNative,
            proteinPerNative: proteinPerNative,
            carbsPerNative: carbsPerNative,
            fatPerNative: fatPerNative,
            notes: storedNotes,
            source: entrySource
        )
        try? modelContext.save()
        onSaved()
    }

    @Query private var cachedFoods: [CachedFood]

    private func upsertCached(
        externalId: String,
        name: String,
        brand: String?,
        nativeUnit: String,
        nativeUnitGrams: Double?,
        nativeUnitMilliliters: Double?,
        initialSelectedUnit: String,
        initialSelectedQuantity: Double,
        calsPerNative: Double,
        proteinPerNative: Double,
        carbsPerNative: Double,
        fatPerNative: Double,
        notes: String?,
        source: FoodSource
    ) {
        if let existing = cachedFoods.first(where: { $0.externalId == externalId }) {
            existing.lastUsed = .now
            if !addToMyFoods { existing.useCount += 1 }
            existing.notes = notes
            existing.brand = brand
            existing.lastSelectedUnit = initialSelectedUnit
            existing.lastSelectedQuantity = initialSelectedQuantity
            if addToMyFoods { existing.isInMyFoods = true }
            trimRecents(limit: 100)
            return
        }
        let cached = CachedFood(
            externalId: externalId,
            name: name,
            brand: brand,
            nativeUnit: nativeUnit,
            nativeUnitGrams: nativeUnitGrams,
            nativeUnitMilliliters: nativeUnitMilliliters,
            lastSelectedUnit: initialSelectedUnit,
            lastSelectedQuantity: initialSelectedQuantity,
            caloriesPerServing: calsPerNative,
            proteinPerServing: proteinPerNative,
            carbsPerServing: carbsPerNative,
            fatPerServing: fatPerNative,
            source: source,
            isInMyFoods: addToMyFoods,
            lastUsed: .now,
            useCount: addToMyFoods ? 0 : 1,
            notes: notes
        )
        modelContext.insert(cached)
        trimRecents(limit: 100)
    }

    private func trimRecents(limit: Int) {
        let descriptor = FetchDescriptor<CachedFood>(
            predicate: #Predicate<CachedFood> { $0.isFavorite == false && $0.isInMyFoods == false },
            sortBy: [SortDescriptor(\.lastUsed, order: .reverse)]
        )
        guard let recentNonFavorites = try? modelContext.fetch(descriptor),
              recentNonFavorites.count > limit else { return }

        for cached in recentNonFavorites.dropFirst(limit) {
            modelContext.delete(cached)
        }
    }

    private func ensureDayLog() -> DayLog {
        let day = Calendar.current.startOfDay(for: date)
        if let existing = DayLog.preferredForDay(dayLogs, on: day) {
            return existing
        }
        let new = DayLog(date: day)
        modelContext.insert(new)
        return new
    }
}
