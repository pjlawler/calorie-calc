import SwiftUI
import SwiftData

/// Edit the serving + macros of a single logged `FoodEntry`. Only this entry is affected by
/// the Save button — the linked `CachedFood` (if any) and other historical entries are left
/// alone. A second CTA promotes the edited values into My Foods: either updating the existing
/// saved food, or creating a fresh My Foods entry if none is saved yet.
struct EditEntryFoodSheet: View {

    @Bindable var entry: FoodEntry
    /// Optional callback the parent fires after the modal saves. Used by the portion sheet
    /// to also dismiss itself so the user doesn't see stale macros from its frozen result.
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query private var cachedFoods: [CachedFood]

    @State private var quantityText: String = "1"
    @State private var unit: String = "g"
    @State private var gramsText: String = ""
    @State private var caloriesText: String = ""
    @State private var proteinText: String = ""
    @State private var carbsText: String = ""
    @State private var fatText: String = ""

    /// Standard unit picker options. Mirrors the Manual Entry / Quick Add picker.
    private let standardUnitOptions: [String] = [
        "g", "oz", "lb", "kg",
        "ml", "fl oz", "cup", "tbsp", "tsp", "l",
        "ea", "bar", "slice", "piece", "bowl", "package", "batch",
    ]

    /// Picker options for the unit menu. Always includes whatever unit the entry currently
    /// uses (e.g. "serving" from an AI-described food) so seeding the modal doesn't silently
    /// rewrite the entry to a different unit on save.
    private var unitOptions: [String] {
        var result = standardUnitOptions
        for candidate in [entry.selectedUnit, entry.nativeUnit] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !result.contains(trimmed) {
                result.insert(trimmed, at: 0)
            }
        }
        return result
    }

    private var isCountableUnit: Bool {
        !ServingMath.isMeasurementUnit(unit)
    }

    /// The linked saved food, matched the same way the portion sheet matches: by externalId
    /// when present, else by the food's UUID string fallback. `nil` for entries that don't have
    /// a corresponding cached row (rare; usually means the user logged then deleted from My Foods).
    private var linkedCachedFood: CachedFood? {
        guard let target = entry.externalId else { return nil }
        return cachedFoods.first { food in
            if let ext = food.externalId { return ext == target }
            return food.id.uuidString == target
        }
    }

    /// Promotion CTA label flips based on whether a saved version already exists. "Update" when
    /// the food is in My Foods (overwrite the stored values); "Save" otherwise (upsert with
    /// `isInMyFoods=true`).
    private var promoteButtonLabel: String {
        if let cached = linkedCachedFood, cached.isInMyFoods {
            return "Update Stored Food"
        }
        return "Save as My Food"
    }

    private var canSave: Bool {
        guard let qty = Double(quantityText.replacingOccurrences(of: ",", with: ".")), qty > 0 else { return false }
        guard let cals = Double(caloriesText), cals >= 0 else { return false }
        _ = cals
        return true
    }

    private var quantityFooter: String {
        if ServingMath.isMassUnit(unit) {
            return "Enter what you actually ate (e.g., 200 g) and the macros for that amount."
        }
        if ServingMath.isVolumeUnit(unit) {
            return "Enter what you actually drank (e.g., 240 ml) and the macros for that amount."
        }
        return "Enter the count and macros for what you ate. Optional grams lets the picker offer g / oz / lb / kg later."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
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
                    if isCountableUnit {
                        macroField(label: "1 \(unit) weighs", text: $gramsText, suffix: "g")
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

                Section {
                    Button {
                        save(promote: false)
                    } label: {
                        Text("Save")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canSave)

                    Button {
                        save(promote: true)
                    } label: {
                        Text(promoteButtonLabel)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!canSave)
                } footer: {
                    Text("Save updates only this log entry. \(promoteButtonLabel) also writes these values to your saved foods.")
                }
            }
            .navigationTitle("Edit Nutrition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { seedFields() }
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

    private func seedFields() {
        // Seed with the entry's currently-displayed serving so the macros line up with what
        // the user sees in the day log. e.g. "2 bars / 400 kcal" reads back exactly that way.
        // Use the entry's own unit verbatim — `unitOptions` injects non-standard tokens like
        // "serving" so the picker can keep them rather than silently converting to "ea".
        let candidate = entry.selectedUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        unit = candidate.isEmpty ? entry.nativeUnit : candidate
        quantityText = formatNumber(entry.quantity)

        let factor = ServingMath.nativeUnitsConsumed(
            selectedUnit: unit,
            quantity: entry.quantity,
            nativeUnit: entry.nativeUnit,
            nativeUnitGrams: entry.nativeUnitGrams,
            nativeUnitMilliliters: entry.nativeUnitMilliliters
        )
        caloriesText = trimmed(entry.caloriesPerServing * factor)
        proteinText = trimmed(entry.proteinPerServing * factor)
        carbsText = trimmed(entry.carbsPerServing * factor)
        fatText = trimmed(entry.fatPerServing * factor)

        if let g = entry.nativeUnitGrams, g > 0, !ServingMath.isMeasurementUnit(entry.nativeUnit) {
            gramsText = trimmed(g)
        } else {
            gramsText = ""
        }
    }

    private func save(promote: Bool) {
        guard let amount = Double(quantityText.replacingOccurrences(of: ",", with: ".")), amount > 0 else { return }
        let cals = Double(caloriesText) ?? 0
        let protein = Double(proteinText) ?? 0
        let carbs = Double(carbsText) ?? 0
        let fat = Double(fatText) ?? 0

        let identity = FoodNutritionMath.deriveIdentity(
            unit: unit,
            quantity: amount,
            countableGrams: Double(gramsText),
            cals: cals,
            protein: protein,
            carbs: carbs,
            fat: fat
        )

        // Rebuild the entry around the new identity. selectedUnit + quantity become what the
        // user typed, so the day log row now reads exactly that way.
        entry.nativeUnit = identity.nativeUnit
        entry.nativeUnitGrams = identity.nativeUnitGrams
        entry.nativeUnitMilliliters = identity.nativeUnitMilliliters
        entry.selectedUnit = identity.initialSelectedUnit
        entry.quantity = identity.initialSelectedQuantity
        entry.caloriesPerServing = identity.calsPerNative
        entry.proteinPerServing = identity.proteinPerNative
        entry.carbsPerServing = identity.carbsPerNative
        entry.fatPerServing = identity.fatPerNative

        if promote {
            promoteToMyFoods(identity: identity)
        }

        try? modelContext.save()
        dismiss()
        onSaved()
    }

    /// Either update the existing CachedFood (matched by externalId) with the edited identity
    /// or create a fresh one flagged into My Foods. Mirrors the upsert in `FoodPortionSheet`
    /// closely so the result is indistinguishable from a normal save-to-my-foods.
    private func promoteToMyFoods(identity: FoodNutritionMath.Identity) {
        if let cached = linkedCachedFood {
            cached.name = entry.name
            cached.brand = entry.brand
            cached.nativeUnit = identity.nativeUnit
            cached.nativeUnitGrams = identity.nativeUnitGrams
            cached.nativeUnitMilliliters = identity.nativeUnitMilliliters
            cached.caloriesPerServing = identity.calsPerNative
            cached.proteinPerServing = identity.proteinPerNative
            cached.carbsPerServing = identity.carbsPerNative
            cached.fatPerServing = identity.fatPerNative
            cached.lastSelectedUnit = identity.initialSelectedUnit
            cached.lastSelectedQuantity = identity.initialSelectedQuantity
            cached.lastUsed = .now
            cached.isInMyFoods = true
            // Stale favorite preset would re-introduce the old macros next time the user
            // opens via Quick Add — clear it so the new identity sticks.
            cached.favoriteSelectedUnit = nil
            cached.favoriteSelectedQuantity = nil
            return
        }
        let externalId = entry.externalId ?? "edited:\(UUID().uuidString)"
        let cached = CachedFood(
            externalId: externalId,
            name: entry.name,
            brand: entry.brand,
            nativeUnit: identity.nativeUnit,
            nativeUnitGrams: identity.nativeUnitGrams,
            nativeUnitMilliliters: identity.nativeUnitMilliliters,
            lastSelectedUnit: identity.initialSelectedUnit,
            lastSelectedQuantity: identity.initialSelectedQuantity,
            caloriesPerServing: identity.calsPerNative,
            proteinPerServing: identity.proteinPerNative,
            carbsPerServing: identity.carbsPerNative,
            fatPerServing: identity.fatPerNative,
            source: entry.source,
            isInMyFoods: true,
            lastUsed: .now,
            useCount: 0,
            notes: entry.notes
        )
        modelContext.insert(cached)
        // Stitch the entry back to the new cached food so future edits find it.
        if entry.externalId == nil { entry.externalId = externalId }
    }

    private func trimmed(_ value: Double) -> String {
        if value.isNaN || value.isInfinite { return "0" }
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }
}
