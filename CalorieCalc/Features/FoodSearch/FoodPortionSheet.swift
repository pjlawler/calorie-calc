import SwiftUI
import SwiftData

struct FoodPortionSheet: View {

    /// Snapshot of the food as it was when the sheet was opened. Read it once; everything in
    /// the view reads `result` (the computed property below) so user-applied overrides flow in
    /// automatically.
    let originalResult: FoodSearchResult
    let mealType: MealType
    let date: Date
    /// Set when the sheet is opened to edit an existing entry. `nil` on the create flow.
    let editingEntry: FoodEntry?
    /// When `true`, the post-save upsert sets `isInMyFoods` on the cached food. Used by the
    /// Foods tab's Add flow so anything created lands in My Foods automatically.
    let addToMyFoods: Bool
    /// When `true`, surfaces in-sheet meal + date pickers so the user can retarget the log
    /// (the `mealType` / `date` params seed the "best guess"). The toolbar Cancel becomes a
    /// Done that persists field edits without logging. Used by the My Foods tap flow.
    let pickMealAndDate: Bool
    let onLogged: () -> Void

    init(result: FoodSearchResult, mealType: MealType, date: Date, editingEntry: FoodEntry? = nil, addToMyFoods: Bool = false, pickMealAndDate: Bool = false, onLogged: @escaping () -> Void) {
        self.originalResult = result
        self.mealType = mealType
        self.date = date
        self.editingEntry = editingEntry
        self.addToMyFoods = addToMyFoods
        self.pickMealAndDate = pickMealAndDate
        self.onLogged = onLogged
        _selectedMealType = State(initialValue: mealType)
        _selectedDate = State(initialValue: date)
    }

    /// User-applied edits to a fresh barcode/search result, before the entry is committed.
    /// `nil` means "use originalResult as-is." Populated by `EditFreshNutritionSheet` so the
    /// rest of the portion sheet (display + save) doesn't need to know whether the macros
    /// came from the lookup or the user.
    @State private var resultOverride: FoodSearchResult? = nil

    /// The active result the rest of the view should read from. Pre-edit, this is just the
    /// passed-in lookup; post-edit, it carries the user's overrides.
    private var result: FoodSearchResult { resultOverride ?? originalResult }

    @State private var showEditFreshNutrition: Bool = false

    /// Convenience for opening the sheet on an existing `FoodEntry` — reconstructs a
    /// `FoodSearchResult` from the stored per-native fields so the UI can edit amounts.
    init(editing entry: FoodEntry, onCompleted: @escaping () -> Void) {
        self.init(
            result: entry.toSearchResult(),
            mealType: entry.mealType,
            date: entry.timestamp,
            editingEntry: entry,
            addToMyFoods: false,
            onLogged: onCompleted
        )
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var dayLogs: [DayLog]
    @Query private var cachedFoods: [CachedFood]

    @State private var selectedUnit: String = ""
    @State private var amountText: String = "1"
    @State private var notesText: String = ""
    @State private var nameText: String = ""
    @State private var brandText: String = ""
    @State private var selectedMealType: MealType
    @State private var selectedDate: Date
    @State private var showTagPicker: Bool = false
    @State private var showEditEntryNutrition: Bool = false
    @State private var showEditCachedFoodNutrition: Bool = false
    // Per-native-unit nutrition values, editable via the "Per serving" section.
    // Initialised from `result.*PerServing` in `resolveDefaults`.
    /// Staged tag selections — populated from the existing CachedFood (if any) on
    /// open, then mutated freely while the user picks. On save these get attached
    /// to the resulting CachedFood (whether updated or freshly created).
    @State private var stagedTagIds: Set<UUID> = []

    @Query(sort: \FoodTag.name) private var allTags: [FoodTag]

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
        // Match on externalId when set, otherwise fall back to the UUID string —
        // that's the same key `cached.toSearchResult()` produces for legacy rows
        // (e.g. CSV-imported foods) whose externalId is nil. Without the fallback,
        // saving a unit change against such a row would silently create a duplicate
        // CachedFood instead of updating the original in place.
        cachedFoods.first { matches(food: $0, resultId: result.id) }
    }

    private func matches(food: CachedFood, resultId: String) -> Bool {
        if let ext = food.externalId { return ext == resultId }
        return food.id.uuidString == resultId
    }

    private var isFavorite: Bool { cachedFood?.isFavorite ?? false }
    private var isInMyFoods: Bool { cachedFood?.isInMyFoods ?? false }

    private func toggleMyFoods() {
        if let existing = cachedFood {
            existing.isInMyFoods.toggle()
            existing.name = effectiveName
            existing.brand = trimmedBrand
            // Promoting back into My Foods — refresh the saved food's identity from whatever
            // source is most live. When editing an entry, the entry is the canonical state
            // (its `result` snapshot can be stale if Edit Nutrition just ran); otherwise the
            // `result` snapshot is the only thing we have.
            if existing.isInMyFoods {
                if let entry = editingEntry {
                    existing.nativeUnit = entry.nativeUnit
                    existing.nativeUnitGrams = entry.nativeUnitGrams
                    existing.nativeUnitMilliliters = entry.nativeUnitMilliliters
                    existing.caloriesPerServing = entry.caloriesPerServing
                    existing.proteinPerServing = entry.proteinPerServing
                    existing.carbsPerServing = entry.carbsPerServing
                    existing.fatPerServing = entry.fatPerServing
                    existing.saturatedFatPerServing = entry.saturatedFatPerServing
                    existing.transFatPerServing = entry.transFatPerServing
                    existing.monounsaturatedFatPerServing = entry.monounsaturatedFatPerServing
                    existing.polyunsaturatedFatPerServing = entry.polyunsaturatedFatPerServing
                    existing.cholesterolPerServing = entry.cholesterolPerServing
                    existing.sodiumPerServing = entry.sodiumPerServing
                    existing.fiberPerServing = entry.fiberPerServing
                    existing.sugarsPerServing = entry.sugarsPerServing
                    existing.addedSugarsPerServing = entry.addedSugarsPerServing
                    existing.lastSelectedUnit = entry.selectedUnit
                    existing.lastSelectedQuantity = entry.quantity
                } else {
                    existing.nativeUnit = result.nativeUnit
                    existing.nativeUnitGrams = result.nativeUnitGrams
                    existing.nativeUnitMilliliters = result.nativeUnitMilliliters
                    existing.caloriesPerServing = result.caloriesPerServing
                    existing.proteinPerServing = result.proteinPerServing
                    existing.carbsPerServing = result.carbsPerServing
                    existing.fatPerServing = result.fatPerServing
                    existing.saturatedFatPerServing = result.saturatedFatPerServing
                    existing.transFatPerServing = result.transFatPerServing
                    existing.monounsaturatedFatPerServing = result.monounsaturatedFatPerServing
                    existing.polyunsaturatedFatPerServing = result.polyunsaturatedFatPerServing
                    existing.cholesterolPerServing = result.cholesterolPerServing
                    existing.sodiumPerServing = result.sodiumPerServing
                    existing.fiberPerServing = result.fiberPerServing
                    existing.sugarsPerServing = result.sugarsPerServing
                    existing.addedSugarsPerServing = result.addedSugarsPerServing
                    existing.lastSelectedUnit = selectedUnit
                    existing.lastSelectedQuantity = amount
                }
                // The favorite preset captures macros at favorite-time — clearing it lets
                // the next "open from Quick Add" scale from the fresh per-native values.
                existing.favoriteSelectedUnit = nil
                existing.favoriteSelectedQuantity = nil
            }
            if !existing.isInMyFoods && !existing.isFavorite && existing.useCount == 0 {
                modelContext.delete(existing)
            }
        } else {
            // No matching CachedFood — create one. When editing an entry, prefer the entry's
            // live fields over the (possibly stale) result snapshot so a just-edited entry
            // saves the right values to My Foods.
            let trimmedNotes = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = editingEntry
            let cached = CachedFood(
                externalId: result.id,
                name: effectiveName,
                brand: trimmedBrand,
                nativeUnit: entry?.nativeUnit ?? result.nativeUnit,
                nativeUnitGrams: entry?.nativeUnitGrams ?? result.nativeUnitGrams,
                nativeUnitMilliliters: entry?.nativeUnitMilliliters ?? result.nativeUnitMilliliters,
                lastSelectedUnit: entry?.selectedUnit,
                lastSelectedQuantity: entry?.quantity,
                caloriesPerServing: entry?.caloriesPerServing ?? result.caloriesPerServing,
                proteinPerServing: entry?.proteinPerServing ?? result.proteinPerServing,
                carbsPerServing: entry?.carbsPerServing ?? result.carbsPerServing,
                fatPerServing: entry?.fatPerServing ?? result.fatPerServing,
                saturatedFatPerServing: entry?.saturatedFatPerServing ?? result.saturatedFatPerServing,
                transFatPerServing: entry?.transFatPerServing ?? result.transFatPerServing,
                monounsaturatedFatPerServing: entry?.monounsaturatedFatPerServing ?? result.monounsaturatedFatPerServing,
                polyunsaturatedFatPerServing: entry?.polyunsaturatedFatPerServing ?? result.polyunsaturatedFatPerServing,
                cholesterolPerServing: entry?.cholesterolPerServing ?? result.cholesterolPerServing,
                sodiumPerServing: entry?.sodiumPerServing ?? result.sodiumPerServing,
                fiberPerServing: entry?.fiberPerServing ?? result.fiberPerServing,
                sugarsPerServing: entry?.sugarsPerServing ?? result.sugarsPerServing,
                addedSugarsPerServing: entry?.addedSugarsPerServing ?? result.addedSugarsPerServing,
                source: result.source,
                isFavorite: false,
                isInMyFoods: true,
                lastUsed: .now,
                useCount: 0,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes
            )
            modelContext.insert(cached)
        }
        try? modelContext.save()
    }

    private func toggleFavorite() {
        if let existing = cachedFood {
            existing.isFavorite.toggle()
            existing.name = effectiveName
            existing.brand = trimmedBrand
            if existing.isFavorite {
                // Favoriting auto-promotes to My Foods (the two lists are unified now).
                existing.isInMyFoods = true
                if existing.favoriteSelectedUnit == nil {
                    existing.favoriteSelectedUnit = selectedUnit
                    existing.favoriteSelectedQuantity = amount
                }
            }
            if !existing.isFavorite && !existing.isInMyFoods && existing.useCount == 0 {
                modelContext.delete(existing)
            }
        } else {
            // Favorite a food the user hasn't logged yet — upsert so it lands directly in My Foods.
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
                isInMyFoods: true,
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

                if editingEntry != nil {
                    Section {
                        Button {
                            showEditEntryNutrition = true
                        } label: {
                            Label("Edit Nutrition", systemImage: "pencil")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    } footer: {
                        Text("Adjust this log entry's serving and macros without changing other logs or your saved foods.")
                    }
                } else if pickMealAndDate && cachedFood != nil {
                    Section {
                        Button {
                            showEditCachedFoodNutrition = true
                        } label: {
                            Label("Edit Nutrition", systemImage: "pencil")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    } footer: {
                        Text("Adjust the saved food's serving and macros. Already-logged entries are unchanged.")
                    }
                } else if cachedFood == nil {
                    // Fresh barcode / search result, not yet saved. Surface an edit step so the
                    // user can refine macros + the grams-per-serving conversion before logging —
                    // useful when the API's data doesn't match the package label.
                    Section {
                        Button {
                            showEditFreshNutrition = true
                        } label: {
                            Label("Edit Nutrition", systemImage: "pencil")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    } footer: {
                        Text("Override the looked-up calories, macros, or grams-per-serving if they don't match the package label.")
                    }
                }

                Section("Notes") {
                    TextField("Add notes — prep, source, tweaks…", text: $notesText, axis: .vertical)
                        .lineLimit(2...6)
                }

                if pickMealAndDate {
                    Section("Add to") {
                        Picker("Meal", selection: $selectedMealType) {
                            ForEach(MealType.allCases.sorted(by: { $0.order < $1.order }), id: \.self) { meal in
                                Text(meal.displayName).tag(meal)
                            }
                        }
                        DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                    }
                }

                Section {
                    if !addToMyFoods && !pickMealAndDate {
                        Button { toggleMyFoods() } label: {
                            Label(
                                isInMyFoods ? "Saved to My Foods" : "Save to My Foods",
                                systemImage: isInMyFoods ? "checkmark" : "plus"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }

                    Button { save() } label: {
                        Text(saveButtonLabel)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!isValid)
                }

                // Tags work for both existing CachedFoods and fresh search results.
                // For search results, picks are staged in `stagedTagIds` and attached
                // to the new CachedFood when `upsertCached` runs in `save()`.
                Section("Tags") {
                    let stagedTags = allTags.filter { stagedTagIds.contains($0.id) }
                    if stagedTags.isEmpty {
                        Button {
                            showTagPicker = true
                        } label: {
                            Label("Add tags", systemImage: "tag")
                        }
                    } else {
                        FlowLayout(spacing: 8) {
                            ForEach(stagedTags) { tag in
                                Button {
                                    stagedTagIds.remove(tag.id)
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
            }
            .sheet(isPresented: $showTagPicker) {
                TagPickerSheet(selectedIds: $stagedTagIds)
            }
            .sheet(isPresented: $showEditEntryNutrition) {
                if let entry = editingEntry {
                    EditEntryFoodSheet(entry: entry) {
                        // Portion sheet's `result` is a frozen snapshot — close it after the
                        // modal saves so re-opening picks up the new identity rather than
                        // showing stale macros.
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showEditCachedFoodNutrition) {
                if let cached = cachedFood {
                    EditCachedFoodSheet(food: cached) {
                        // Same staleness rule as the entry-edit path.
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showEditFreshNutrition) {
                EditFreshNutritionSheet(result: result) { edited in
                    // Cache the user's overrides. The computed `result` accessor returns this
                    // instead of `originalResult` so display + save paths automatically pick up
                    // the edits without any further plumbing.
                    resultOverride = edited
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if pickMealAndDate {
                        Button("Done") { saveEditsAndDismiss() }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { toggleFavorite() } label: {
                        Image(systemName: isFavorite ? "bolt.fill" : "bolt")
                            .foregroundStyle(isFavorite ? Color.orange : Color.secondary)
                    }
                    .accessibilityLabel(isFavorite ? "Remove from My Staples" : "Add to My Staples")
                }
            }
            .onAppear { configureInitialState() }
        }
    }

    private var saveButtonLabel: String {
        if editingEntry != nil { return "Save" }
        if addToMyFoods { return "Save to My Foods" }
        if pickMealAndDate { return "Log Food Item" }
        return "Add to \(selectedMealType.displayName)"
    }

    private var navigationTitle: String {
        if addToMyFoods { return "New Food" }
        if editingEntry != nil { return "Edit Entry" }
        if pickMealAndDate { return "My Food Item" }
        return "Add Food"
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
        // Pre-populate staged tag ids from the existing CachedFood (if there is one)
        // so the picker/chip row reflects what's already attached. For fresh search
        // results without a CachedFood, this stays empty and the user can attach
        // tags that get applied on save.
        stagedTagIds = Set(cachedFood?.tagsList.map(\.id) ?? [])
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
        } else if addToMyFoods {
            // My Foods creation flow — only persist the cached food, no day-log entry.
            upsertCached(name: effectiveName, brand: trimmedBrand, notes: storedNotes)
            try? modelContext.save()
        } else {
            let logDay = pickMealAndDate ? normalizedSelectedDay(from: selectedDate) : date
            let log = ensureDayLog(for: logDay)
            let timestamp = pickMealAndDate ? defaultTimestamp(for: logDay) : Date()
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
                mealType: selectedMealType,
                source: result.source,
                externalId: result.id,
                notes: storedNotes,
                timestamp: timestamp,
                dayLog: log
            )
            modelContext.insert(entry)
            upsertCached(name: effectiveName, brand: trimmedBrand, notes: storedNotes)
            try? modelContext.save()
        }
        dismiss()
        onLogged()
    }

    /// Tap-from-My-Foods Done: persist field edits to the cached food without creating a
    /// log entry. Falls back to plain dismiss if no cached row exists (shouldn't happen on
    /// the My Foods flow, but keeps the bypass safe).
    private func saveEditsAndDismiss() {
        let trimmedNotes = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedNotes: String? = trimmedNotes.isEmpty ? nil : trimmedNotes
        if let cached = cachedFood {
            cached.name = effectiveName
            cached.brand = trimmedBrand
            cached.notes = storedNotes
            cached.lastSelectedUnit = selectedUnit
            cached.lastSelectedQuantity = amount
            try? modelContext.save()
        }
        dismiss()
    }

    private func defaultTimestamp(for day: Date) -> Date {
        if Calendar.current.isDateInToday(day) {
            return .now
        }
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }

    private func normalizedSelectedDay(from pickerDate: Date) -> Date {
        // DatePicker(.date) may round-trip through GMT and shift a day for some locales.
        // Read Y/M/D in UTC, then rebuild in local calendar to preserve the user's chosen date.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = utc.dateComponents([.year, .month, .day], from: pickerDate)
        let localDate = Calendar.current.date(from: components) ?? pickerDate
        return Calendar.current.startOfDay(for: localDate)
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
        // Apply staged tags from the edit-entry flow — without this, picking tags in
        // the sheet would be silently discarded on save. Tagging promotes to My Foods
        // (monotonic — un-tagging never un-saves).
        let resolvedTags = allTags.filter { stagedTagIds.contains($0.id) }
        cached.tags = resolvedTags
        if !resolvedTags.isEmpty { cached.isInMyFoods = true }
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
        let resolvedTags = allTags.filter { stagedTagIds.contains($0.id) }
        // Attaching a tag is treated as the user curating the food — promote into My Foods
        // so tagged foods stop disappearing into the auto-trimmed Recents bucket. Monotonic:
        // un-tagging never un-saves.
        let promoteForTags = !resolvedTags.isEmpty
        if let existing = cachedFoods.first(where: { matches(food: $0, resultId: id) }) {
            existing.lastUsed = .now
            if !addToMyFoods { existing.useCount += 1 }
            existing.notes = notes
            existing.name = name
            existing.brand = brand
            existing.lastSelectedUnit = selectedUnit
            existing.lastSelectedQuantity = amount
            // Sync staged tags onto the existing food — assigning replaces the full
            // set, so tag removals stage-side propagate to the CachedFood too.
            existing.tags = resolvedTags
            if addToMyFoods || promoteForTags { existing.isInMyFoods = true }
            // Backfill externalId on legacy rows so subsequent saves can match by
            // externalId directly without needing the UUID fallback. One-shot heal.
            if existing.externalId == nil { existing.externalId = id }
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
                isInMyFoods: addToMyFoods || promoteForTags,
                lastUsed: .now,
                useCount: addToMyFoods ? 0 : 1,
                notes: notes
            )
            modelContext.insert(cached)
            // Attach staged tags after insert so the inverse relationship lands cleanly.
            cached.tags = resolvedTags
        }
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
            tile(label: "Calories", value: CalorieFormatter.whole(calories), unit: "kcal", subtitle: nil, tint: .accentColor)
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

/// Lets the user refine an as-yet-unsaved barcode/search result before it's logged. Lives
/// here (rather than in EditCachedFoodSheet) because there's no CachedFood yet — the sheet
/// builds a new `FoodSearchResult` with the user's edits and hands it back via `onSave`.
///
/// Editable fields are intentionally minimal: per-native calories/protein/carbs/fat, plus
/// the grams-per-native conversion when the food has one. Native unit, name, brand stay
/// fixed — those changes belong in EditCachedFood once the food is saved.
private struct EditFreshNutritionSheet: View {
    let result: FoodSearchResult
    let onSave: (FoodSearchResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var caloriesText: String = ""
    @State private var proteinText: String = ""
    @State private var carbsText: String = ""
    @State private var fatText: String = ""
    @State private var gramsPerNativeText: String = ""

    private var nativeLabel: String {
        // "Per cup", "Per bar", "Per gram" — matches how the user thinks about the food.
        "Per \(result.nativeUnit)"
    }

    private var showsGramsField: Bool {
        // Loose-mass foods (native = "g") don't need a grams-per-gram field; the conversion is
        // trivial. Same for pure-each foods where grams are unknown by design.
        result.nativeUnit != "g" && result.nativeUnitGrams != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(result.name)
                        .font(.headline)
                    if let brand = result.brand, !brand.isEmpty {
                        Text(brand).font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                Section {
                    macroField("Calories", text: $caloriesText, suffix: "kcal")
                    macroField("Protein", text: $proteinText, suffix: "g")
                    macroField("Carbs", text: $carbsText, suffix: "g")
                    macroField("Fat", text: $fatText, suffix: "g")
                } header: {
                    Text(nativeLabel)
                } footer: {
                    Text("Edit these to match the package label if the lookup differs.")
                }

                if showsGramsField {
                    Section {
                        macroField("Grams per \(result.nativeUnit)", text: $gramsPerNativeText, suffix: "g")
                    } header: {
                        Text("Serving weight")
                    } footer: {
                        Text("How many grams a single \(result.nativeUnit) weighs. Changes how mass-unit conversions (g/oz/lb) work in the picker.")
                    }
                }

                Section {
                    Button {
                        save()
                    } label: {
                        Text("Save")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .navigationTitle("Edit Nutrition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                if caloriesText.isEmpty {
                    caloriesText = formatNumber(result.caloriesPerServing)
                    proteinText = formatNumber(result.proteinPerServing)
                    carbsText = formatNumber(result.carbsPerServing)
                    fatText = formatNumber(result.fatPerServing)
                    if let g = result.nativeUnitGrams {
                        gramsPerNativeText = formatNumber(g)
                    }
                }
            }
        }
    }

    private func macroField(_ label: String, text: Binding<String>, suffix: String) -> some View {
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
                .frame(width: 40, alignment: .leading)
        }
    }

    private func save() {
        let calories = Double(caloriesText) ?? result.caloriesPerServing
        let protein = Double(proteinText) ?? result.proteinPerServing
        let carbs = Double(carbsText) ?? result.carbsPerServing
        let fat = Double(fatText) ?? result.fatPerServing
        let gramsPerNative = showsGramsField ? Double(gramsPerNativeText) : nil

        let edited = FoodSearchResult(
            id: result.id,
            name: result.name,
            brand: result.brand,
            nativeUnit: result.nativeUnit,
            nativeUnitGrams: gramsPerNative ?? result.nativeUnitGrams,
            nativeUnitMilliliters: result.nativeUnitMilliliters,
            initialSelectedUnit: result.initialSelectedUnit,
            initialSelectedQuantity: result.initialSelectedQuantity,
            caloriesPerServing: calories,
            proteinPerServing: protein,
            carbsPerServing: carbs,
            fatPerServing: fat,
            // Preserve the optional micros from the original lookup — the user didn't edit them
            // here, and dropping them would silently hide sodium/fiber/etc. info in the day log.
            saturatedFatPerServing: result.saturatedFatPerServing,
            transFatPerServing: result.transFatPerServing,
            monounsaturatedFatPerServing: result.monounsaturatedFatPerServing,
            polyunsaturatedFatPerServing: result.polyunsaturatedFatPerServing,
            cholesterolPerServing: result.cholesterolPerServing,
            sodiumPerServing: result.sodiumPerServing,
            fiberPerServing: result.fiberPerServing,
            sugarsPerServing: result.sugarsPerServing,
            addedSugarsPerServing: result.addedSugarsPerServing,
            notes: result.notes,
            source: result.source
        )
        onSave(edited)
        dismiss()
    }
}
