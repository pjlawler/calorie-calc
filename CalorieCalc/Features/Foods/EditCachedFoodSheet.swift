import SwiftUI
import SwiftData

/// Edit a `CachedFood`'s identity, serving size, and per-serving macros directly. Used from the
/// Foods tab's My Foods list — lets users curate their saved catalog without re-logging
/// or re-saving from a search result. Edits update only the saved food; past log entries
/// are unchanged.
struct EditCachedFoodSheet: View {

    @Bindable var food: CachedFood
    /// Optional callback the parent fires after the modal saves. Used by the portion sheet
    /// to also dismiss itself so the user doesn't see stale macros from its frozen result.
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var nameText: String = ""
    @State private var brandText: String = ""
    @State private var quantityText: String = "1"
    @State private var unit: String = "g"
    @State private var gramsText: String = ""
    @State private var caloriesText: String = ""
    @State private var proteinText: String = ""
    @State private var carbsText: String = ""
    @State private var fatText: String = ""
    @State private var notesText: String = ""
    @State private var showTagPicker: Bool = false

    @Query(sort: \FoodTag.name) private var allTags: [FoodTag]

    /// Standard unit picker options. Mirrors the Manual Entry / Quick Add picker.
    private let standardUnitOptions: [String] = [
        "g", "oz", "lb", "kg",
        "ml", "fl oz", "cup", "tbsp", "tsp", "l",
        "ea", "bar", "slice", "piece", "bowl", "package", "batch",
    ]

    /// Picker options. Always includes whatever unit the food currently uses (e.g. "serving"
    /// from an AI-described food) so seeding the modal doesn't silently rewrite the food to
    /// a different unit on save.
    private var unitOptions: [String] {
        var result = standardUnitOptions
        for candidate in [food.lastSelectedUnit ?? "", food.nativeUnit] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !result.contains(trimmed) {
                result.insert(trimmed, at: 0)
            }
        }
        return result
    }

    /// Countable nouns expose the optional "1 unit weighs ___ g" field. Mass / volume units
    /// already have their gram weight implied by the unit itself.
    private var isCountableUnit: Bool {
        !ServingMath.isMeasurementUnit(unit)
    }

    /// Bidirectional bridge between the picker's `Set<UUID>` API and the food's
    /// `tags: [FoodTag]?` relationship. Reads project the current attachment;
    /// writes resolve ids → `FoodTag` instances and reassign the relationship.
    private var tagSelectionBinding: Binding<Set<UUID>> {
        Binding(
            get: { Set(food.tagsList.map(\.id)) },
            set: { newIds in
                food.tags = allTags.filter { newIds.contains($0.id) }
                try? modelContext.save()
            }
        )
    }

    private var canSave: Bool {
        guard !nameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let qty = Double(quantityText.replacingOccurrences(of: ",", with: ".")), qty > 0 else { return false }
        guard let cals = Double(caloriesText), cals >= 0 else { return false }
        _ = cals
        return true
    }

    private var quantityFooter: String {
        if ServingMath.isMassUnit(unit) {
            return "Enter the nutrition values for one \(quantityText.isEmpty ? "0" : quantityText) \(unit) serving. The picker will offer g / oz / lb / kg when logging."
        }
        if ServingMath.isVolumeUnit(unit) {
            return "Enter the nutrition values for one \(quantityText.isEmpty ? "0" : quantityText) \(unit) serving. The picker will offer ml / fl oz / cup / tbsp / tsp / L when logging."
        }
        return "Enter the nutrition values for one \(unit). Optionally specify the gram weight so the picker can also offer g / oz / lb / kg when logging."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Food") {
                    TextField("Name", text: $nameText)
                        .textInputAutocapitalization(.words)
                    TextField("Brand (optional)", text: $brandText)
                        .textInputAutocapitalization(.words)
                }

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

                Section("Tags") {
                    if food.tagsList.isEmpty {
                        Button {
                            showTagPicker = true
                        } label: {
                            Label("Add tags", systemImage: "tag")
                        }
                    } else {
                        // Wrap to multiple lines when the user has lots of tags. Each chip is
                        // tappable to remove without entering the picker.
                        FlowLayout(spacing: 8) {
                            ForEach(food.tagsList) { tag in
                                Button {
                                    food.tags = food.tagsList.filter { $0.id != tag.id }
                                    try? modelContext.save()
                                } label: {
                                    HStack(spacing: 4) {
                                        TagChipView(name: tag.name, color: tag.color)
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            Button {
                                showTagPicker = true
                            } label: {
                                Image(systemName: "plus.circle")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Notes") {
                    TextField("Notes — prep, source, tweaks…", text: $notesText, axis: .vertical)
                        .lineLimit(2...6)
                }
            }
            .sheet(isPresented: $showTagPicker) {
                TagPickerSheet(selectedIds: tagSelectionBinding)
            }
            .navigationTitle("Edit Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(!canSave)
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

    /// Seeds the form with a representative serving + macros derived from the stored food.
    /// For countable foods, defaults to "1 [unit]" with the stored per-native macros.
    /// For mass / volume foods, prefers the user's last-logged preset (so a "42 g protein bar"
    /// reads back as "42 g"); falls back to 100 of the native unit.
    private func seedFields() {
        nameText = food.name
        brandText = food.brand ?? ""
        notesText = food.notes ?? ""

        // Prefer the user's last-logged preset so a "42 g protein bar" reads back as "42 g"
        // rather than the awkward "1 g, 4.76 kcal" you'd get from displaying per-native values.
        // For mass / volume natives with no logged history, "100 of native" is the convention
        // used on nutrition labels. Countable natives display as "1 [unit]".
        let seedUnit: String
        let seedQty: Double
        if let lastUnit = food.lastSelectedUnit, let lastQty = food.lastSelectedQuantity, lastQty > 0 {
            seedUnit = lastUnit
            seedQty = lastQty
        } else if ServingMath.isMeasurementUnit(food.nativeUnit) {
            seedUnit = food.nativeUnit
            seedQty = 100
        } else {
            seedUnit = food.nativeUnit
            seedQty = 1
        }

        unit = seedUnit
        quantityText = formatNumber(seedQty)

        let factor = ServingMath.nativeUnitsConsumed(
            selectedUnit: unit,
            quantity: seedQty,
            nativeUnit: food.nativeUnit,
            nativeUnitGrams: food.nativeUnitGrams,
            nativeUnitMilliliters: food.nativeUnitMilliliters
        )
        caloriesText = trimmed(food.caloriesPerServing * factor)
        proteinText = trimmed(food.proteinPerServing * factor)
        carbsText = trimmed(food.carbsPerServing * factor)
        fatText = trimmed(food.fatPerServing * factor)

        if let g = food.nativeUnitGrams, g > 0, !ServingMath.isMeasurementUnit(food.nativeUnit) {
            gramsText = trimmed(g)
        } else {
            gramsText = ""
        }
    }

    private func save() {
        let trimmedName = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
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

        food.name = trimmedName
        let trimmedBrand = brandText.trimmingCharacters(in: .whitespacesAndNewlines)
        food.brand = trimmedBrand.isEmpty ? nil : trimmedBrand
        food.nativeUnit = identity.nativeUnit
        food.nativeUnitGrams = identity.nativeUnitGrams
        food.nativeUnitMilliliters = identity.nativeUnitMilliliters
        food.caloriesPerServing = identity.calsPerNative
        food.proteinPerServing = identity.proteinPerNative
        food.carbsPerServing = identity.carbsPerNative
        food.fatPerServing = identity.fatPerNative
        food.lastSelectedUnit = identity.initialSelectedUnit
        food.lastSelectedQuantity = identity.initialSelectedQuantity
        // Macros no longer match the previously-favorited preset — clear it so the next
        // "open from Quick Add" uses the fresh values rather than scaling stale ones.
        food.favoriteSelectedUnit = nil
        food.favoriteSelectedQuantity = nil

        let trimmedNotes = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
        food.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        try? modelContext.save()
        dismiss()
        onSaved()
    }

    private func trimmed(_ value: Double) -> String {
        if value.isNaN || value.isInfinite { return "0" }
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }
}
