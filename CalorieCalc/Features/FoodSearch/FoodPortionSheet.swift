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
    /// Called whenever the user changes the meal in the in-sheet picker, so the presenting
    /// food list can carry that choice forward to the next food opened in the same session
    /// (overriding the time-of-day default). `nil` for flows with no session to update.
    let onMealChange: ((MealType) -> Void)?

    init(result: FoodSearchResult, mealType: MealType, date: Date, editingEntry: FoodEntry? = nil, addToMyFoods: Bool = false, pickMealAndDate: Bool = false, onMealChange: ((MealType) -> Void)? = nil, onLogged: @escaping () -> Void) {
        self.originalResult = result
        self.mealType = mealType
        self.date = date
        self.editingEntry = editingEntry
        self.addToMyFoods = addToMyFoods
        self.pickMealAndDate = pickMealAndDate
        self.onMealChange = onMealChange
        self.onLogged = onLogged
        _selectedMealType = State(initialValue: mealType)
        _selectedDate = State(initialValue: date)
        // New-food (My Foods) flow has no CTA — the fork toggle is the save control and
        // starts lit since the intent is to add to My Foods. Committed on Close.
        _stagedNewInMyFoods = State(initialValue: addToMyFoods)
    }

    /// User-applied edits to a fresh barcode/search result, before the entry is committed.
    /// `nil` means "use originalResult as-is." Populated by inline macro edits in the
    /// EditableMacroBreakdownView so the rest of the portion sheet (display + save) doesn't
    /// need to know whether the macros came from the lookup or the user.
    @State private var resultOverride: FoodSearchResult? = nil

    /// The active result the rest of the view should read from. Pre-edit, this is just the
    /// passed-in lookup; post-edit, it carries the user's overrides.
    private var result: FoodSearchResult { resultOverride ?? originalResult }

    // Inline-editable macro fields for fresh search/barcode/AI results. Pre-fill from the
    // looked-up values; updates flow back into `resultOverride` so the displayed totals
    // (and the eventual saved entry) reflect what the user typed.
    @State private var caloriesEditText: String = ""
    @State private var proteinEditText: String = ""
    @State private var carbsEditText: String = ""
    @State private var fatEditText: String = ""
    /// Set once when the sheet first appears, then again whenever the picker (unit /
    /// quantity) changes, so the inline fields re-derive their displayed totals.
    @State private var lastSyncedMultiplier: Double = -1

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
    /// Off by default so accidental taps on the macro tiles don't replace looked-up values.
    /// Toggled by an Edit/Done pill in the macro section header.
    @State private var isEditingMacros: Bool = false
    // Per-native-unit nutrition values, editable via the "Per serving" section.
    // Initialised from `result.*PerServing` in `resolveDefaults`.
    /// Staged tag selections — populated from the existing CachedFood (if any) on
    /// open, then mutated freely while the user picks. On save these get attached
    /// to the resulting CachedFood (whether updated or freshly created).
    @State private var stagedTagIds: Set<UUID> = []
    /// Staged toggles for the new-food (My Foods) flow, where there's no CTA and the food
    /// doesn't exist yet. The toolbar fork/bolt drive these and `save()` (run on Close)
    /// applies them. The normal log flow uses the immediate `toggleMyFoods`/`toggleFavorite`.
    @State private var stagedNewInMyFoods: Bool = false
    @State private var stagedNewStaple: Bool = false

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
            } else {
                // A staple is by definition part of My Foods, so removing the food from
                // My Foods must also drop its staple status — otherwise we'd strand a
                // lit bolt on a food that's no longer saved.
                existing.isFavorite = false
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
                    TextField("Name", text: $nameText)
                        .textInputAutocapitalization(.words)
                        .font(.headline)
                    TextField("Brand (optional)", text: $brandText)
                        .textInputAutocapitalization(.words)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
                    EditableMacroBreakdownView(
                        calories: $caloriesEditText,
                        carbs: $carbsEditText,
                        fat: $fatEditText,
                        protein: $proteinEditText,
                        editable: isEditingMacros,
                        onCommit: { kind, raw in commitMacroEdit(kind: kind, raw: raw) }
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                } header: {
                    HStack {
                        Spacer()
                        Button {
                            isEditingMacros.toggle()
                        } label: {
                            if isEditingMacros {
                                Text("Save")
                                    .textCase(nil)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color.accentColor))
                            } else {
                                Text("Edit")
                                    .textCase(nil)
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    }
                } footer: {
                    Text(isEditingMacros
                        ? "Tap any value to override the looked-up numbers."
                        : "Tap Edit to override the looked-up calories or macros.")
                }

                Section("Notes") {
                    TextField("Add notes — prep, source, tweaks…", text: $notesText, axis: .vertical)
                        .lineLimit(2...6)
                }

                if pickMealAndDate {
                    Section("Add to") {
                        DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                        Picker("Meal", selection: $selectedMealType) {
                            ForEach(MealType.allCases.sorted(by: { $0.order < $1.order }), id: \.self) { meal in
                                Text(meal.displayName).tag(meal)
                            }
                        }
                    }
                } else if editingEntry == nil && !addToMyFoods {
                    // Standard log flow: let the user retarget the meal before logging. The
                    // selection is seeded from the time-of-day default (or the session's last
                    // pick) and written back via `onMealChange` so the next food inherits it.
                    Section("Add to") {
                        Picker("Meal", selection: $selectedMealType) {
                            ForEach(MealType.allCases.sorted(by: { $0.order < $1.order }), id: \.self) { meal in
                                Text(meal.displayName).tag(meal)
                            }
                        }
                    }
                }

                // The new-food (My Foods) flow has no logging CTA — the fork toggle saves and
                // Close commits. Every other flow keeps its explicit save/log button.
                if !addToMyFoods {
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
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if pickMealAndDate {
                        Button("Done") { saveEditsAndDismiss() }
                    } else if addToMyFoods {
                        Button("Close") { commitNewMyFoodAndDismiss() }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if addToMyFoods {
                        // Staged fork toggle — applied by save() on Close.
                        Button {
                            stagedNewInMyFoods.toggle()
                            if !stagedNewInMyFoods { stagedNewStaple = false }
                        } label: {
                            Image(systemName: "fork.knife")
                                .foregroundStyle(stagedNewInMyFoods ? Color.accentColor : Color.secondary)
                        }
                        .accessibilityLabel(stagedNewInMyFoods ? "Remove from My Foods" : "Save to My Foods")
                    } else {
                        // Log flows (tap a food / search a new one — pickMealAndDate) and the
                        // tap-existing flow share the immediate fork toggle. A fresh search
                        // result has no CachedFood, so isInMyFoods is false → defaults to
                        // off and the user opts in; toggleMyFoods() creates the cached row.
                        Button { toggleMyFoods() } label: {
                            Image(systemName: "fork.knife")
                                .foregroundStyle(isInMyFoods ? Color.accentColor : Color.secondary)
                        }
                        .accessibilityLabel(isInMyFoods ? "Remove from My Foods" : "Save to My Foods")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if addToMyFoods {
                        // Staged staple toggle — applied by save() on Close.
                        Button {
                            stagedNewStaple.toggle()
                            if stagedNewStaple { stagedNewInMyFoods = true }
                        } label: {
                            Image(systemName: stagedNewStaple ? "bolt.fill" : "bolt")
                                .foregroundStyle(stagedNewStaple ? Color.orange : Color.secondary)
                        }
                        .accessibilityLabel(stagedNewStaple ? "Remove from My Staples" : "Add to My Staples")
                    } else {
                        Button { toggleFavorite() } label: {
                            Image(systemName: isFavorite ? "bolt.fill" : "bolt")
                                .foregroundStyle(isFavorite ? Color.orange : Color.secondary)
                        }
                        .accessibilityLabel(isFavorite ? "Remove from My Staples" : "Add to My Staples")
                    }
                }
            }
            .onAppear { configureInitialState() }
            // Resync the inline macro text fields whenever the picker changes (so the totals
            // re-derive from per-native × new multiplier). The .task with two-tuple id ensures
            // both edits flow through one trigger.
            .onChange(of: selectedUnit, initial: true) { _, _ in syncMacroEditTextsToCurrentSelection() }
            .onChange(of: amountText) { _, _ in syncMacroEditTextsToCurrentSelection() }
            // Carry a manual meal change back to the presenting list so the next food
            // opened in this session defaults to it instead of the time-of-day meal.
            .onChange(of: selectedMealType) { _, newValue in onMealChange?(newValue) }
        }
    }

    private var saveButtonLabel: String {
        if editingEntry != nil { return "Save" }
        if addToMyFoods { return "Save to My Foods" }
        if pickMealAndDate { return "Log Food Item" }
        return "Log Item"
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

    /// Close action for the new-food (My Foods) flow: persist when valid and a toggle is on,
    /// otherwise dismiss without saving.
    private func commitNewMyFoodAndDismiss() {
        if isValid && (stagedNewInMyFoods || stagedNewStaple) {
            save()   // upserts the cached food, then dismisses
        } else {
            dismiss()
        }
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
            // Persist inline macro edits — `result` carries the user's overrides, so write the
            // full per-native nutrient set back to the saved food. Without this the edits are
            // dropped and the row reopens with the looked-up numbers.
            cached.nativeUnit = result.nativeUnit
            cached.nativeUnitGrams = result.nativeUnitGrams
            cached.nativeUnitMilliliters = result.nativeUnitMilliliters
            cached.caloriesPerServing = result.caloriesPerServing
            cached.proteinPerServing = result.proteinPerServing
            cached.carbsPerServing = result.carbsPerServing
            cached.fatPerServing = result.fatPerServing
            cached.saturatedFatPerServing = result.saturatedFatPerServing
            cached.transFatPerServing = result.transFatPerServing
            cached.monounsaturatedFatPerServing = result.monounsaturatedFatPerServing
            cached.polyunsaturatedFatPerServing = result.polyunsaturatedFatPerServing
            cached.cholesterolPerServing = result.cholesterolPerServing
            cached.sodiumPerServing = result.sodiumPerServing
            cached.fiberPerServing = result.fiberPerServing
            cached.sugarsPerServing = result.sugarsPerServing
            cached.addedSugarsPerServing = result.addedSugarsPerServing
            // Persist staged tag edits — without this, tags picked in the My Foods tap
            // flow are silently dropped on Done. Assigning the full set also propagates
            // removals; attaching a tag promotes the food into My Foods (monotonic).
            let resolvedTags = allTags.filter { stagedTagIds.contains($0.id) }
            cached.tags = resolvedTags
            if !resolvedTags.isEmpty { cached.isInMyFoods = true }
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
        // DatePicker(.date) presents and edits in the device's current time zone, so the
        // chosen day is whatever Calendar.current reports — the same calendar used to bucket
        // DayLogs at display time (and matching the manual-workout path). Reading Y/M/D in UTC
        // shifts a day east of GMT (e.g. picking 6/27 in Bangkok would log to 6/26).
        Calendar.current.startOfDay(for: pickerDate)
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
        // New-food flow: the staged toolbar toggles drive My Foods / staple. Other flows
        // leave these to the immediate toggleMyFoods/toggleFavorite (so resolve to false
        // here — upsertCached only ever sets the flags true, never clears them).
        let resolveStaple = addToMyFoods ? stagedNewStaple : false
        let resolveMyFoods = (addToMyFoods ? (stagedNewInMyFoods || stagedNewStaple) : false) || promoteForTags
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
            if resolveMyFoods { existing.isInMyFoods = true }
            if resolveStaple {
                existing.isFavorite = true
                if existing.favoriteSelectedUnit == nil {
                    existing.favoriteSelectedUnit = selectedUnit
                    existing.favoriteSelectedQuantity = amount
                }
            }
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
                isFavorite: resolveStaple,
                isInMyFoods: resolveMyFoods,
                lastUsed: .now,
                useCount: addToMyFoods ? 0 : 1,
                notes: notes,
                favoriteSelectedUnit: resolveStaple ? selectedUnit : nil,
                favoriteSelectedQuantity: resolveStaple ? amount : nil
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

    /// Refreshes the inline macro text fields with totals for the current picker selection.
    /// Called on first appearance and whenever the user changes the unit or amount; uses
    /// `result` (the override-applied result) so values the user typed earlier stay reflected
    /// after a picker change. Calories render as whole numbers; protein/carbs/fat round to
    /// the nearest 0.1 g.
    private func syncMacroEditTextsToCurrentSelection() {
        let mult = nativeUnitsConsumed
        guard mult > 0 else { return }
        caloriesEditText = formatCaloriesValue(result.caloriesPerServing * mult)
        proteinEditText = formatMacroValue(result.proteinPerServing * mult)
        carbsEditText = formatMacroValue(result.carbsPerServing * mult)
        fatEditText = formatMacroValue(result.fatPerServing * mult)
        lastSyncedMultiplier = mult
    }

    private func formatCaloriesValue(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    private func formatMacroValue(_ value: Double) -> String {
        // Round to 0.1; drop the trailing .0 so "10.0 g" reads as "10 g" but "10.5 g" stays.
        let rounded = (value * 10).rounded() / 10
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }

    enum MacroKind { case calories, protein, carbs, fat }

    /// Reads the user's typed value for one macro, converts back to per-native, and rebuilds
    /// `resultOverride` so display + save automatically reflect the edit. Other macros stay
    /// at whatever they were (either lookup or earlier override). Called on every keystroke;
    /// silently ignores partial/invalid text so the user can type "1." without trouble.
    private func commitMacroEdit(kind: MacroKind, raw: String) {
        guard let parsed = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        let mult = nativeUnitsConsumed
        guard mult > 0 else { return }
        let perNative = parsed / mult
        let base = result
        var newCal = base.caloriesPerServing
        var newProt = base.proteinPerServing
        var newCarb = base.carbsPerServing
        var newFat = base.fatPerServing
        switch kind {
        case .calories: newCal = perNative
        case .protein: newProt = perNative
        case .carbs: newCarb = perNative
        case .fat: newFat = perNative
        }
        // Skip writes that don't change anything — avoids feedback loops from the sync-on-
        // picker-change path that also retypes into the bound state.
        if newCal == base.caloriesPerServing
            && newProt == base.proteinPerServing
            && newCarb == base.carbsPerServing
            && newFat == base.fatPerServing {
            return
        }
        resultOverride = FoodSearchResult(
            id: base.id,
            name: base.name,
            brand: base.brand,
            nativeUnit: base.nativeUnit,
            nativeUnitGrams: base.nativeUnitGrams,
            nativeUnitMilliliters: base.nativeUnitMilliliters,
            initialSelectedUnit: base.initialSelectedUnit,
            initialSelectedQuantity: base.initialSelectedQuantity,
            caloriesPerServing: newCal,
            proteinPerServing: newProt,
            carbsPerServing: newCarb,
            fatPerServing: newFat,
            saturatedFatPerServing: base.saturatedFatPerServing,
            transFatPerServing: base.transFatPerServing,
            monounsaturatedFatPerServing: base.monounsaturatedFatPerServing,
            polyunsaturatedFatPerServing: base.polyunsaturatedFatPerServing,
            cholesterolPerServing: base.cholesterolPerServing,
            sodiumPerServing: base.sodiumPerServing,
            fiberPerServing: base.fiberPerServing,
            sugarsPerServing: base.sugarsPerServing,
            addedSugarsPerServing: base.addedSugarsPerServing,
            notes: base.notes,
            source: base.source
        )
    }
}

/// Inline-editable replacement for `MacroBreakdownView`. Each tile is a tap-to-edit
/// TextField styled to match the original's look (bold number + small unit + label +
/// percentage). Parent owns the text state; `onCommit` fires on every keystroke so the
/// portion sheet's MacroBreakdownView totals re-derive immediately.
private struct EditableMacroBreakdownView: View {
    @Binding var calories: String
    @Binding var carbs: String
    @Binding var fat: String
    @Binding var protein: String
    /// Off by default — the tiles render as plain Text so accidental taps don't trigger
    /// the keypad. The parent flips this on when the user taps Edit in the section header.
    let editable: Bool
    let onCommit: (FoodPortionSheet.MacroKind, String) -> Void

    /// Which field the user is actively typing in. Edits only commit for the focused field so
    /// the parent's programmatic re-sync (it rewrites these bound strings whenever the amount or
    /// unit changes) isn't mistaken for a user edit — that false commit would round-trip the
    /// looked-up totals back through per-native math and clobber or revert the user's override.
    @FocusState private var focusedField: FoodPortionSheet.MacroKind?

    private var caloriesValue: Double { Double(calories) ?? 0 }
    private var proteinValue: Double { Double(protein) ?? 0 }
    private var carbsValue: Double { Double(carbs) ?? 0 }
    private var fatValue: Double { Double(fat) ?? 0 }

    private var totalCalFromMacros: Double {
        (carbsValue * 4) + (fatValue * 9) + (proteinValue * 4)
    }

    private func percent(_ calsFromMacro: Double) -> Int {
        guard totalCalFromMacros > 0 else { return 0 }
        return Int((calsFromMacro / totalCalFromMacros * 100).rounded())
    }

    var body: some View {
        HStack(spacing: 0) {
            tile(label: "Calories", text: $calories, unit: "kcal", subtitle: nil, tint: .accentColor, kind: .calories)
            Divider().frame(height: 48)
            tile(label: "Carbs", text: $carbs, unit: "g", subtitle: "\(percent(carbsValue * 4))%", tint: .teal, kind: .carbs)
            Divider().frame(height: 48)
            tile(label: "Fat", text: $fat, unit: "g", subtitle: "\(percent(fatValue * 9))%", tint: .purple, kind: .fat)
            Divider().frame(height: 48)
            tile(label: "Protein", text: $protein, unit: "g", subtitle: "\(percent(proteinValue * 4))%", tint: .orange, kind: .protein)
        }
    }

    private func tile(label: String, text: Binding<String>, unit: String, subtitle: String?, tint: Color, kind: FoodPortionSheet.MacroKind) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                if editable {
                    // .fixedSize keeps the TextField width hugging its content so the unit
                    // suffix doesn't end up several characters away from the number.
                    TextField("0", text: text)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.title3.weight(.bold).monospacedDigit())
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                        )
                        .focused($focusedField, equals: kind)
                        .onChange(of: text.wrappedValue) { _, newValue in
                            // Only a change to the focused field is a real user edit. The parent
                            // re-syncs these bound strings on amount/unit changes; without this
                            // guard those programmatic rewrites would commit as fake edits and
                            // revert the user's override to the looked-up numbers.
                            guard focusedField == kind else { return }
                            onCommit(kind, newValue)
                        }
                } else {
                    Text(text.wrappedValue.isEmpty ? "0" : text.wrappedValue)
                        .font(.title3.weight(.bold).monospacedDigit())
                }
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

