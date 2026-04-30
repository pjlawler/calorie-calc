import SwiftUI
import SwiftData

struct FoodPortionSheet: View {

    let result: FoodSearchResult
    let mealType: MealType
    let date: Date
    /// Set when the sheet is opened to edit an existing entry. `nil` on the create flow.
    let editingEntry: FoodEntry?
    let onLogged: () -> Void

    init(result: FoodSearchResult, mealType: MealType, date: Date, editingEntry: FoodEntry? = nil, onLogged: @escaping () -> Void) {
        self.result = result
        self.mealType = mealType
        self.date = date
        self.editingEntry = editingEntry
        self.onLogged = onLogged
    }

    /// Convenience for opening the sheet on an existing `FoodEntry` — reconstructs a
    /// `FoodSearchResult` from the stored per-native fields so the UI can edit amounts.
    init(editing entry: FoodEntry, onCompleted: @escaping () -> Void) {
        self.init(
            result: entry.toSearchResult(),
            mealType: entry.mealType,
            date: entry.timestamp,
            editingEntry: entry,
            onLogged: onCompleted
        )
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var dayLogs: [DayLog]
    @Query private var cachedFoods: [CachedFood]

    @State private var selectedUnit: String = ""
    @State private var amountText: String = "1"
    @State private var isNutritionFactsExpanded: Bool = true
    @State private var notesText: String = ""
    @State private var nameText: String = ""
    @State private var brandText: String = ""

    private var trimmedName: String { nameText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedBrand: String? {
        let v = brandText.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
    private var effectiveName: String { trimmedName.isEmpty ? result.name : trimmedName }

    private var servingOptions: [ServingOption] {
        ServingMath.options(
            nativeUnit: result.nativeUnit,
            nativeUnitGrams: result.nativeUnitGrams,
            nativeUnitMilliliters: result.nativeUnitMilliliters
        )
    }

    private var amount: Double { parse(amountText) }

    /// Native units consumed at the current selection — the multiplier applied to per-native
    /// nutrient values to compute totals.
    private var nativeUnitsConsumed: Double {
        ServingMath.nativeUnitsConsumed(
            selectedUnit: selectedUnit,
            quantity: amount,
            nativeUnit: result.nativeUnit,
            nativeUnitGrams: result.nativeUnitGrams,
            nativeUnitMilliliters: result.nativeUnitMilliliters
        )
    }

    private var isValid: Bool { amount > 0 }

    private var cachedFood: CachedFood? {
        cachedFoods.first { $0.externalId == result.id }
    }

    private var isFavorite: Bool { cachedFood?.isFavorite ?? false }

    private func toggleFavorite() {
        if let existing = cachedFood {
            existing.isFavorite.toggle()
            existing.name = effectiveName
            existing.brand = trimmedBrand
            if existing.isFavorite && existing.favoriteSelectedUnit == nil {
                existing.favoriteSelectedUnit = selectedUnit
                existing.favoriteSelectedQuantity = amount
            }
            if !existing.isFavorite && existing.useCount == 0 {
                modelContext.delete(existing)
            }
        } else {
            // Favorite a food the user hasn't logged yet — upsert so it appears on the Favorites
            // tab even if they never hit Save on this sheet.
            let trimmedNotes = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
            let cached = CachedFood(
                externalId: result.id,
                name: effectiveName,
                brand: trimmedBrand,
                nativeUnit: result.nativeUnit,
                nativeUnitGrams: result.nativeUnitGrams,
                nativeUnitMilliliters: result.nativeUnitMilliliters,
                lastSelectedUnit: nil,
                lastSelectedQuantity: nil,
                caloriesPerServing: result.caloriesPerServing,
                proteinPerServing: result.proteinPerServing,
                carbsPerServing: result.carbsPerServing,
                fatPerServing: result.fatPerServing,
                saturatedFatPerServing: result.saturatedFatPerServing,
                transFatPerServing: result.transFatPerServing,
                monounsaturatedFatPerServing: result.monounsaturatedFatPerServing,
                polyunsaturatedFatPerServing: result.polyunsaturatedFatPerServing,
                cholesterolPerServing: result.cholesterolPerServing,
                sodiumPerServing: result.sodiumPerServing,
                fiberPerServing: result.fiberPerServing,
                sugarsPerServing: result.sugarsPerServing,
                addedSugarsPerServing: result.addedSugarsPerServing,
                source: result.source,
                isFavorite: true,
                lastUsed: .now,
                useCount: 0,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                favoriteSelectedUnit: selectedUnit,
                favoriteSelectedQuantity: amount
            )
            modelContext.insert(cached)
        }
        try? modelContext.save()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if editingEntry == nil {
                        TextField("Name", text: $nameText)
                            .textInputAutocapitalization(.words)
                            .font(.headline)
                        TextField("Brand (optional)", text: $brandText)
                            .textInputAutocapitalization(.words)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(result.name).font(.headline)
                        if let brand = result.brand, !brand.isEmpty {
                            Text(brand).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    LabeledContent("Amt") {
                        HStack(spacing: 8) {
                            TextField("Count", text: $amountText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .frame(minWidth: 60)
                            Picker("Unit", selection: $selectedUnit) {
                                ForEach(servingOptions) { option in
                                    Text(option.label).tag(option.unit)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }
                }

                Section {
                    MacroBreakdownView(
                        calories: result.caloriesPerServing * nativeUnitsConsumed,
                        carbs: result.carbsPerServing * nativeUnitsConsumed,
                        fat: result.fatPerServing * nativeUnitsConsumed,
                        protein: result.proteinPerServing * nativeUnitsConsumed
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }

                Section {
                    DisclosureGroup(isExpanded: $isNutritionFactsExpanded) {
                        NutritionFactsContent(result: result, factor: nativeUnitsConsumed)
                    } label: {
                        Text("Nutrition Facts").font(.subheadline.weight(.semibold))
                    }
                }

                Section("Notes") {
                    TextField("Add notes — prep, source, tweaks…", text: $notesText, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section {
                    Button { save() } label: {
                        Text(saveButtonLabel)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!isValid)
                }
            }
            .navigationTitle(editingEntry == nil ? "Add Food" : "Edit Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { toggleFavorite() } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .foregroundStyle(isFavorite ? Color.yellow : Color.accentColor)
                    }
                    .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
                }
            }
            .onAppear { configureInitialState() }
        }
    }

    private var saveButtonLabel: String {
        editingEntry == nil ? "Add to \(mealType.displayName)" : "Save"
    }

    private func configureInitialState() {
        let options = servingOptions

        // Editing an existing entry: open with whatever was saved.
        if let entry = editingEntry {
            selectedUnit = options.first(where: { $0.unit == entry.selectedUnit })?.unit
                ?? options.first?.unit
                ?? entry.selectedUnit
            amountText = formatAmount(entry.quantity)
            notesText = entry.notes ?? cachedFood?.notes ?? ""
            nameText = entry.name
            brandText = entry.brand ?? ""
            return
        }

        // Creating a new entry: prefer the food's last-used preset (from CachedFood) so the user
        // sees their previous pick. Fall back to the FoodSearchResult's initial defaults.
        let cached = cachedFood
        if let cached, let unit = cached.lastSelectedUnit,
           options.contains(where: { $0.unit == unit }),
           let qty = cached.lastSelectedQuantity {
            selectedUnit = unit
            amountText = formatAmount(qty)
        } else {
            let initialUnit = options.contains(where: { $0.unit == result.initialSelectedUnit })
                ? result.initialSelectedUnit
                : (options.first?.unit ?? result.nativeUnit)
            selectedUnit = initialUnit
            amountText = formatAmount(result.initialSelectedQuantity)
        }
        notesText = result.notes ?? cached?.notes ?? ""
        nameText = result.name
        brandText = result.brand ?? ""
    }

    private func parse(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private func formatAmount(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func save() {
        let trimmedNotes = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedNotes: String? = trimmedNotes.isEmpty ? nil : trimmedNotes
        propagateNotesToCache(storedNotes)

        if let entry = editingEntry {
            entry.name = effectiveName
            entry.brand = trimmedBrand
            entry.nativeUnit = result.nativeUnit
            entry.nativeUnitGrams = result.nativeUnitGrams
            entry.nativeUnitMilliliters = result.nativeUnitMilliliters
            entry.selectedUnit = selectedUnit
            entry.quantity = amount
            entry.caloriesPerServing = result.caloriesPerServing
            entry.proteinPerServing = result.proteinPerServing
            entry.carbsPerServing = result.carbsPerServing
            entry.fatPerServing = result.fatPerServing
            entry.saturatedFatPerServing = result.saturatedFatPerServing
            entry.transFatPerServing = result.transFatPerServing
            entry.monounsaturatedFatPerServing = result.monounsaturatedFatPerServing
            entry.polyunsaturatedFatPerServing = result.polyunsaturatedFatPerServing
            entry.cholesterolPerServing = result.cholesterolPerServing
            entry.sodiumPerServing = result.sodiumPerServing
            entry.fiberPerServing = result.fiberPerServing
            entry.sugarsPerServing = result.sugarsPerServing
            entry.addedSugarsPerServing = result.addedSugarsPerServing
            entry.notes = storedNotes
            updateCachedSticky(unit: selectedUnit, quantity: amount, notes: storedNotes)
            try? modelContext.save()
        } else {
            let log = ensureDayLog(for: date)
            let entry = FoodEntry(
                name: effectiveName,
                brand: trimmedBrand,
                nativeUnit: result.nativeUnit,
                nativeUnitGrams: result.nativeUnitGrams,
                nativeUnitMilliliters: result.nativeUnitMilliliters,
                selectedUnit: selectedUnit,
                quantity: amount,
                caloriesPerServing: result.caloriesPerServing,
                proteinPerServing: result.proteinPerServing,
                carbsPerServing: result.carbsPerServing,
                fatPerServing: result.fatPerServing,
                saturatedFatPerServing: result.saturatedFatPerServing,
                transFatPerServing: result.transFatPerServing,
                monounsaturatedFatPerServing: result.monounsaturatedFatPerServing,
                polyunsaturatedFatPerServing: result.polyunsaturatedFatPerServing,
                cholesterolPerServing: result.cholesterolPerServing,
                sodiumPerServing: result.sodiumPerServing,
                fiberPerServing: result.fiberPerServing,
                sugarsPerServing: result.sugarsPerServing,
                addedSugarsPerServing: result.addedSugarsPerServing,
                mealType: mealType,
                source: result.source,
                externalId: result.id,
                notes: storedNotes,
                timestamp: Date(),
                dayLog: log
            )
            modelContext.insert(entry)
            upsertCached(name: effectiveName, brand: trimmedBrand, notes: storedNotes)
            try? modelContext.save()
        }
        dismiss()
        onLogged()
    }

    private func propagateNotesToCache(_ notes: String?) {
        guard let cached = cachedFood else { return }
        cached.notes = notes
    }

    private func updateCachedSticky(unit: String, quantity: Double, notes: String?) {
        guard let cached = cachedFood else { return }
        cached.lastSelectedUnit = unit
        cached.lastSelectedQuantity = quantity
        cached.notes = notes
    }

    private func ensureDayLog(for date: Date) -> DayLog {
        let day = Calendar.current.startOfDay(for: date)
        if let existing = DayLog.preferredForDay(dayLogs, on: day) {
            return existing
        }
        let new = DayLog(date: day)
        modelContext.insert(new)
        return new
    }

    private func upsertCached(name: String, brand: String?, notes: String?) {
        let id = result.id
        if let existing = cachedFoods.first(where: { $0.externalId == id }) {
            existing.lastUsed = .now
            existing.useCount += 1
            existing.notes = notes
            existing.name = name
            existing.brand = brand
            existing.lastSelectedUnit = selectedUnit
            existing.lastSelectedQuantity = amount
        } else {
            let cached = CachedFood(
                externalId: id,
                name: name,
                brand: brand,
                nativeUnit: result.nativeUnit,
                nativeUnitGrams: result.nativeUnitGrams,
                nativeUnitMilliliters: result.nativeUnitMilliliters,
                lastSelectedUnit: selectedUnit,
                lastSelectedQuantity: amount,
                caloriesPerServing: result.caloriesPerServing,
                proteinPerServing: result.proteinPerServing,
                carbsPerServing: result.carbsPerServing,
                fatPerServing: result.fatPerServing,
                saturatedFatPerServing: result.saturatedFatPerServing,
                transFatPerServing: result.transFatPerServing,
                monounsaturatedFatPerServing: result.monounsaturatedFatPerServing,
                polyunsaturatedFatPerServing: result.polyunsaturatedFatPerServing,
                cholesterolPerServing: result.cholesterolPerServing,
                sodiumPerServing: result.sodiumPerServing,
                fiberPerServing: result.fiberPerServing,
                sugarsPerServing: result.sugarsPerServing,
                addedSugarsPerServing: result.addedSugarsPerServing,
                source: result.source,
                lastUsed: .now,
                useCount: 1,
                notes: notes
            )
            modelContext.insert(cached)
        }
        trimRecents(limit: 100)
    }

    private func trimRecents(limit: Int) {
        let descriptor = FetchDescriptor<CachedFood>(
            predicate: #Predicate<CachedFood> { $0.isFavorite == false },
            sortBy: [SortDescriptor(\.lastUsed, order: .reverse)]
        )
        guard let recentNonFavorites = try? modelContext.fetch(descriptor),
              recentNonFavorites.count > limit else { return }

        for cached in recentNonFavorites.dropFirst(limit) {
            modelContext.delete(cached)
        }
    }
}

extension FoodEntry {
    /// Reconstruct a `FoodSearchResult` from a stored entry so the portion sheet can reopen it
    /// for editing. The entry's selectedUnit/quantity is carried as the initial picker preset.
    func toSearchResult() -> FoodSearchResult {
        FoodSearchResult(
            id: externalId ?? id.uuidString,
            name: name,
            brand: brand,
            nativeUnit: nativeUnit,
            nativeUnitGrams: nativeUnitGrams,
            nativeUnitMilliliters: nativeUnitMilliliters,
            initialSelectedUnit: selectedUnit,
            initialSelectedQuantity: quantity,
            caloriesPerServing: caloriesPerServing,
            proteinPerServing: proteinPerServing,
            carbsPerServing: carbsPerServing,
            fatPerServing: fatPerServing,
            saturatedFatPerServing: saturatedFatPerServing,
            transFatPerServing: transFatPerServing,
            monounsaturatedFatPerServing: monounsaturatedFatPerServing,
            polyunsaturatedFatPerServing: polyunsaturatedFatPerServing,
            cholesterolPerServing: cholesterolPerServing,
            sodiumPerServing: sodiumPerServing,
            fiberPerServing: fiberPerServing,
            sugarsPerServing: sugarsPerServing,
            addedSugarsPerServing: addedSugarsPerServing,
            notes: notes,
            source: source
        )
    }
}

// MARK: - Macro breakdown

private struct MacroBreakdownView: View {
    let calories: Double
    let carbs: Double
    let fat: Double
    let protein: Double

    private var totalCalFromMacros: Double {
        (carbs * 4) + (fat * 9) + (protein * 4)
    }

    private func percent(_ calsFromMacro: Double) -> Int {
        guard totalCalFromMacros > 0 else { return 0 }
        return Int((calsFromMacro / totalCalFromMacros * 100).rounded())
    }

    var body: some View {
        HStack(spacing: 0) {
            tile(label: "Calories", value: CalorieFormatter.whole(calories), unit: "cal", subtitle: nil, tint: .accentColor)
            Divider().frame(height: 44)
            tile(label: "Carbs", value: CalorieFormatter.macro(carbs), unit: "g", subtitle: "\(percent(carbs * 4))%", tint: .teal)
            Divider().frame(height: 44)
            tile(label: "Fat", value: CalorieFormatter.macro(fat), unit: "g", subtitle: "\(percent(fat * 9))%", tint: .purple)
            Divider().frame(height: 44)
            tile(label: "Protein", value: CalorieFormatter.macro(protein), unit: "g", subtitle: "\(percent(protein * 4))%", tint: .orange)
        }
    }

    private func tile(label: String, value: String, unit: String, subtitle: String?, tint: Color) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title3.weight(.bold).monospacedDigit())
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(subtitle ?? " ")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

// MARK: - Nutrition facts

private struct NutritionFactsContent: View {
    let result: FoodSearchResult
    /// Native units consumed — multiplier applied to per-native nutrients to get totals.
    let factor: Double

    var body: some View {
        VStack(spacing: 6) {
            row("Calories", value: result.caloriesPerServing * factor, unit: "")
            row("Total Fat", value: result.fatPerServing * factor, unit: "g", bold: true)
            indentedRow("Saturated", value: result.saturatedFatPerServing.map { $0 * factor }, unit: "g")
            indentedRow("Trans", value: result.transFatPerServing.map { $0 * factor }, unit: "g")
            indentedRow("Polyunsaturated", value: result.polyunsaturatedFatPerServing.map { $0 * factor }, unit: "g")
            indentedRow("Monounsaturated", value: result.monounsaturatedFatPerServing.map { $0 * factor }, unit: "g")
            optionalRow("Cholesterol", value: result.cholesterolPerServing.map { $0 * factor }, unit: "mg")
            optionalRow("Sodium", value: result.sodiumPerServing.map { $0 * factor }, unit: "mg")
            row("Total Carbohydrate", value: result.carbsPerServing * factor, unit: "g", bold: true)
            indentedRow("Dietary Fiber", value: result.fiberPerServing.map { $0 * factor }, unit: "g")
            indentedRow("Total Sugars", value: result.sugarsPerServing.map { $0 * factor }, unit: "g")
            indentedRow("Added Sugars", value: result.addedSugarsPerServing.map { $0 * factor }, unit: "g")
            row("Protein", value: result.proteinPerServing * factor, unit: "g", bold: true)
        }
    }

    @ViewBuilder
    private func row(_ label: String, value: Double, unit: String, bold: Bool = false) -> some View {
        HStack {
            Text(label).font(bold ? .subheadline.weight(.semibold) : .subheadline)
            Spacer()
            Text(formatted(value, unit: unit))
                .font(.subheadline.monospacedDigit())
        }
    }

    @ViewBuilder
    private func indentedRow(_ label: String, value: Double?, unit: String) -> some View {
        if let value {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
                Spacer()
                Text(formatted(value, unit: unit))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func optionalRow(_ label: String, value: Double?, unit: String) -> some View {
        if let value {
            row(label, value: value, unit: unit)
        }
    }

    private func formatted(_ value: Double, unit: String) -> String {
        if unit.isEmpty {
            return CalorieFormatter.whole(value)
        }
        return "\(CalorieFormatter.macro(value)) \(unit)"
    }
}
