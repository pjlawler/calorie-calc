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
    /// `FoodSearchResult` from the stored per-serving fields so the UI can edit amounts.
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

    @State private var servingSizeAmountText: String = "1"
    @State private var servingSizeUnit: PortionUnit = .each
    @State private var servingsCountText: String = "1"
    @State private var isNutritionFactsExpanded: Bool = true
    @State private var notesText: String = ""

    private var availableUnits: [PortionUnit] { PortionUnit.available(for: result) }
    private var servingSizeAmount: Double { parse(servingSizeAmountText) }
    private var servingsCount: Double { parse(servingsCountText) }

    /// Maps the user's custom "serving size" (amount + unit) to a multiple of the food's native
    /// serving. `PortionUnit.servingFraction` handles the math and unit-family routing.
    private var servingFraction: Double {
        servingSizeUnit.servingFraction(amount: servingSizeAmount, for: result)
    }

    /// The scalar stored on FoodEntry.quantity — multiplied by every per-serving nutrient to get
    /// totals. Combines "1 custom serving fraction" × "number of servings eaten".
    private var quantity: Double { servingFraction * servingsCount }

    private var isValid: Bool { servingSizeAmount > 0 && servingsCount > 0 }

    private var cachedFood: CachedFood? {
        cachedFoods.first { $0.externalId == result.id }
    }

    private var isFavorite: Bool { cachedFood?.isFavorite ?? false }

    private func toggleFavorite() {
        if let existing = cachedFood {
            existing.isFavorite.toggle()
            if !existing.isFavorite && existing.useCount == 0 {
                modelContext.delete(existing)
            }
        } else {
            // Favorite a food the user hasn't logged yet — upsert so it appears on the Favorites
            // tab even if they never hit Save on this sheet.
            let trimmedNotes = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
            let cached = CachedFood(
                externalId: result.id,
                name: result.name,
                brand: result.brand,
                defaultServingDescription: result.servingDescription,
                defaultServingSizeGrams: result.servingSizeGrams,
                defaultServingSizeMilliliters: result.servingSizeMilliliters,
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
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes
            )
            modelContext.insert(cached)
        }
        try? modelContext.save()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(result.name).font(.headline)
                    if let brand = result.brand, !brand.isEmpty {
                        Text(brand).font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                Section {
                    LabeledContent("Serving Size") {
                        HStack(spacing: 8) {
                            TextField("Amount", text: $servingSizeAmountText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .frame(minWidth: 60)
                            Picker("Unit", selection: $servingSizeUnit) {
                                ForEach(availableUnits) { unit in
                                    Text(unit.displayName(quantity: servingSizeAmount)).tag(unit)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }
                    LabeledContent("Number of Servings") {
                        TextField("Servings", text: $servingsCountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    }
                }

                Section {
                    MacroBreakdownView(
                        calories: result.caloriesPerServing * quantity,
                        carbs: result.carbsPerServing * quantity,
                        fat: result.fatPerServing * quantity,
                        protein: result.proteinPerServing * quantity
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }

                Section {
                    DisclosureGroup(isExpanded: $isNutritionFactsExpanded) {
                        NutritionFactsContent(result: result, quantity: quantity)
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
        // Prefer the unit the user originally typed if it matches the food's family — so
        // "2 lb" reopens as "2 lb" instead of "907.18 g".
        let inferred = PortionUnit.inferred(from: result.servingDescription)

        if let g = result.servingSizeGrams, g > 0 {
            if let inferred, inferred.family == .mass {
                servingSizeUnit = inferred
                servingSizeAmountText = formatAmount(g / inferred.baseMultiplier)
            } else {
                servingSizeUnit = .grams
                servingSizeAmountText = formatAmount(g)
            }
        } else if let ml = result.servingSizeMilliliters, ml > 0 {
            if let inferred, inferred.family == .volume {
                servingSizeUnit = inferred
                servingSizeAmountText = formatAmount(ml / inferred.baseMultiplier)
            } else {
                servingSizeUnit = .milliliters
                servingSizeAmountText = formatAmount(ml)
            }
        } else {
            servingSizeUnit = .each
            servingSizeAmountText = "1"
        }
        if !availableUnits.contains(servingSizeUnit) {
            servingSizeUnit = availableUnits.first ?? .each
        }
        // When editing, the stored quantity is a scalar multiple of the native serving — seed the
        // "Number of Servings" row with it so "1 × 100 g" reopens as "1 × 100 g" rather than
        // resetting to 1. The user's original unit choice isn't stored, so we always display in
        // the food's native unit (grams / ml) which is equivalent math-wise.
        if let entry = editingEntry {
            servingsCountText = formatAmount(entry.quantity)
            // Prefer entry-level notes (user might've added per-log detail); fall back to the
            // cached food's notes so templates carry forward to new logs.
            notesText = entry.notes ?? cachedFood?.notes ?? ""
        } else {
            servingsCountText = "1"
            notesText = result.notes ?? cachedFood?.notes ?? ""
        }
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

        // Persist notes on the cached food regardless of create vs edit — that's the shared
        // "food template" users see across Recents/Favorites and all future log entries.
        propagateNotesToCache(storedNotes)

        if let entry = editingEntry {
            entry.quantity = quantity
            entry.notes = storedNotes
            try? modelContext.save()
        } else {
            let log = ensureDayLog(for: date)
            let entry = FoodEntry(
                name: result.name,
                brand: result.brand,
                servingDescription: result.servingDescription,
                servingSizeGrams: result.servingSizeGrams,
                servingSizeMilliliters: result.servingSizeMilliliters,
                quantity: quantity,
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
            upsertCached(from: result, notes: storedNotes)
            try? modelContext.save()
        }
        dismiss()
        onLogged()
    }

    /// Writes the sheet's current notes back to the matching CachedFood so the same notes
    /// surface the next time the user opens this food from Recents / Favorites / a new log.
    private func propagateNotesToCache(_ notes: String?) {
        guard let cached = cachedFood else { return }
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

    private func upsertCached(from result: FoodSearchResult, notes: String?) {
        let id = result.id
        if let existing = cachedFoods.first(where: { $0.externalId == id }) {
            existing.lastUsed = .now
            existing.useCount += 1
            existing.notes = notes
        } else {
            let cached = CachedFood(
                externalId: id,
                name: result.name,
                brand: result.brand,
                defaultServingDescription: result.servingDescription,
                defaultServingSizeGrams: result.servingSizeGrams,
                defaultServingSizeMilliliters: result.servingSizeMilliliters,
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
    /// for editing. The `quantity` scalar isn't carried through the search-result shape — the
    /// portion sheet reads it directly from `editingEntry` to seed the "Number of Servings" row.
    func toSearchResult() -> FoodSearchResult {
        FoodSearchResult(
            id: externalId ?? id.uuidString,
            name: name,
            brand: brand,
            servingDescription: servingDescription,
            servingSizeGrams: servingSizeGrams,
            servingSizeMilliliters: servingSizeMilliliters,
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
    let quantity: Double

    var body: some View {
        VStack(spacing: 6) {
            row("Calories", value: result.caloriesPerServing * quantity, unit: "")
            row("Total Fat", value: result.fatPerServing * quantity, unit: "g", bold: true)
            indentedRow("Saturated", value: result.saturatedFatPerServing.map { $0 * quantity }, unit: "g")
            indentedRow("Trans", value: result.transFatPerServing.map { $0 * quantity }, unit: "g")
            indentedRow("Polyunsaturated", value: result.polyunsaturatedFatPerServing.map { $0 * quantity }, unit: "g")
            indentedRow("Monounsaturated", value: result.monounsaturatedFatPerServing.map { $0 * quantity }, unit: "g")
            optionalRow("Cholesterol", value: result.cholesterolPerServing.map { $0 * quantity }, unit: "mg")
            optionalRow("Sodium", value: result.sodiumPerServing.map { $0 * quantity }, unit: "mg")
            row("Total Carbohydrate", value: result.carbsPerServing * quantity, unit: "g", bold: true)
            indentedRow("Dietary Fiber", value: result.fiberPerServing.map { $0 * quantity }, unit: "g")
            indentedRow("Total Sugars", value: result.sugarsPerServing.map { $0 * quantity }, unit: "g")
            indentedRow("Added Sugars", value: result.addedSugarsPerServing.map { $0 * quantity }, unit: "g")
            row("Protein", value: result.proteinPerServing * quantity, unit: "g", bold: true)
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

// MARK: - Portion unit

enum PortionUnit: String, CaseIterable, Identifiable {
    case each
    case grams, kilograms, ounces, pounds
    case milliliters, liters, fluidOunces, cups, tablespoons, teaspoons

    var id: String { rawValue }

    enum Family { case each, mass, volume }

    var family: Family {
        switch self {
        case .each: .each
        case .grams, .kilograms, .ounces, .pounds: .mass
        case .milliliters, .liters, .fluidOunces, .cups, .tablespoons, .teaspoons: .volume
        }
    }

    /// US-customary conversions to the family's base unit (grams for mass, milliliters for
    /// volume). `.each` has no conversion — it represents countable items like "1 burger".
    var baseMultiplier: Double {
        switch self {
        case .each: 1
        case .grams: 1
        case .kilograms: 1_000
        case .ounces: 28.3495
        case .pounds: 453.592
        case .milliliters: 1
        case .liters: 1_000
        case .fluidOunces: 29.5735
        case .cups: 236.588
        case .tablespoons: 14.7868
        case .teaspoons: 4.92892
        }
    }

    func displayName(quantity: Double) -> String {
        let plural = abs(quantity - 1) > 0.0001
        switch self {
        case .each: return "ea"
        case .grams: return "g"
        case .kilograms: return "kg"
        case .ounces: return "oz"
        case .pounds: return "lb"
        case .milliliters: return "ml"
        case .liters: return "L"
        case .fluidOunces: return "fl oz"
        case .cups: return plural ? "cups" : "cup"
        case .tablespoons: return "tbsp"
        case .teaspoons: return "tsp"
        }
    }

    /// Converts an (amount + this unit) pair into a multiple of the food's native serving —
    /// the scalar that, multiplied by `caloriesPerServing` etc., gives the user-consumed totals.
    func servingFraction(amount: Double, for food: FoodSearchResult) -> Double {
        switch family {
        case .each:
            return amount
        case .mass:
            guard let grams = food.servingSizeGrams, grams > 0 else { return amount }
            return (amount * baseMultiplier) / grams
        case .volume:
            guard let ml = food.servingSizeMilliliters, ml > 0 else { return amount }
            return (amount * baseMultiplier) / ml
        }
    }

    /// Picker options strictly scoped to the food's native family. A mass food only shows
    /// mass units, volume only volume, each-only shows just `.each` (no cross-family math
    /// is possible without density data).
    static func available(for food: FoodSearchResult) -> [PortionUnit] {
        if let g = food.servingSizeGrams, g > 0 {
            return [.grams, .kilograms, .ounces, .pounds]
        }
        if let ml = food.servingSizeMilliliters, ml > 0 {
            return [.milliliters, .liters, .fluidOunces, .cups, .tablespoons, .teaspoons]
        }
        return [.each]
    }

    /// Best-guess unit token match for a free-text serving description like "2 lb" → `.pounds`.
    /// Used to seed the picker with the user's original unit when reopening a food.
    static func inferred(from description: String) -> PortionUnit? {
        let lower = description.lowercased()
        // Order matters — match longer/more-specific tokens first.
        if lower.range(of: #"\bfl\s*oz\b"#, options: .regularExpression) != nil { return .fluidOunces }
        if lower.range(of: #"\btbsp\b|\btablespoons?\b"#, options: .regularExpression) != nil { return .tablespoons }
        if lower.range(of: #"\btsp\b|\bteaspoons?\b"#, options: .regularExpression) != nil { return .teaspoons }
        if lower.range(of: #"\bcups?\b"#, options: .regularExpression) != nil { return .cups }
        if lower.range(of: #"\bml\b|\bmilliliters?\b"#, options: .regularExpression) != nil { return .milliliters }
        if lower.range(of: #"\bl\b|\bliters?\b"#, options: .regularExpression) != nil { return .liters }
        if lower.range(of: #"\bkg\b|\bkilograms?\b"#, options: .regularExpression) != nil { return .kilograms }
        if lower.range(of: #"\blb\b|\bpounds?\b"#, options: .regularExpression) != nil { return .pounds }
        if lower.range(of: #"\boz\b|\bounces?\b"#, options: .regularExpression) != nil { return .ounces }
        if lower.range(of: #"\bg\b|\bgrams?\b"#, options: .regularExpression) != nil { return .grams }
        if lower.range(of: #"\bea\b|\beach\b"#, options: .regularExpression) != nil { return .each }
        return nil
    }
}
