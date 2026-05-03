import SwiftUI
import SwiftData

/// Build a recipe from ingredients (manual entry or barcode scan), then ask Claude to estimate
/// total recipe nutrition + suggested serving sizes. The user picks a serving size on the
/// review screen; per-serving nutrition is derived from the totals and the picked size. Saved
/// as a `CachedFood` in My Foods with the picked unit's family as the native unit.
struct RecipeBuilderSheet: View {

    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(FoodRecognitionEnvironment.self) private var recognitionEnv
    @Environment(FoodDataSourceEnvironment.self) private var dataSourceEnv

    @State private var recipeName: String = ""
    @State private var ingredients: [RecipeIngredient] = []

    @State private var stage: Stage = .build
    @State private var errorMessage: String?

    @State private var showAddOptions = false
    @State private var showManualEntry = false
    @State private var showScanner = false
    @State private var manualPrefillBarcode: String?

    // Result-stage editable fields (populated from AI estimate). Totals are editable; the
    // serving-size picker + amount field derive per-serving values live.
    @State private var resultName: String = ""
    @State private var totalCaloriesText: String = ""
    @State private var totalProteinText: String = ""
    @State private var totalCarbsText: String = ""
    @State private var totalFatText: String = ""
    @State private var resultConfidence: String?
    @State private var resultNotes: String?
    @State private var yieldOptions: [RecipeYieldOption] = []
    @State private var selectedYieldOptionId: String?
    @State private var servingAmountText: String = ""

    @State private var lookupViewModel: FoodSearchViewModel?

    enum Stage: Equatable {
        case build
        case analyzing
        case result
    }

    private var canAnalyze: Bool {
        !ingredients.isEmpty && stage == .build
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                            .disabled(stage == .analyzing)
                    }
                }
                .alert("Add Ingredient", isPresented: $showAddOptions) {
                    Button("Manual Entry") {
                        manualPrefillBarcode = nil
                        showManualEntry = true
                    }
                    Button("Scan Barcode") { showScanner = true }
                    Button("Cancel", role: .cancel) { }
                }
                .sheet(isPresented: $showManualEntry) {
                    RecipeIngredientEntrySheet(prefillBarcode: manualPrefillBarcode) { ingredient in
                        ingredients.append(ingredient)
                    }
                }
                #if os(iOS)
                .sheet(isPresented: $showScanner) {
                    BarcodeScannerView { code in
                        showScanner = false
                        Task { await handleBarcode(code) }
                    }
                }
                #endif
                .task {
                    if lookupViewModel == nil {
                        lookupViewModel = FoodSearchViewModel(dataSource: dataSourceEnv.dataSource)
                    }
                }
        }
    }

    private var navigationTitle: String {
        switch stage {
        case .build: return "Recipe Analyzer"
        case .analyzing: return "Analyzing…"
        case .result: return "Review Recipe"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .build: buildView
        case .analyzing: analyzingView
        case .result: resultView
        }
    }

    // MARK: - Stage: build

    private var buildView: some View {
        Form {
            Section {
                TextField("Name (e.g. Banana Oat Muffins)", text: $recipeName)
                    .textInputAutocapitalization(.words)
            } header: {
                Text("Recipe")
            } footer: {
                Text("Add ingredients below. Claude will estimate the total recipe yield and suggest serving sizes you can pick from on the review screen.")
            }

            Section {
                if ingredients.isEmpty {
                    Text("No ingredients yet. Tap + to add one.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ForEach(ingredients) { ingredient in
                        ingredientRow(ingredient)
                    }
                    .onDelete { offsets in
                        ingredients.remove(atOffsets: offsets)
                    }
                }
            } header: {
                HStack {
                    Text("Ingredients")
                    Spacer()
                    Button {
                        showAddOptions = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.tint)
                    }
                    .accessibilityLabel("Add ingredient")
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            Section {
                Button {
                    Task { await analyze() }
                } label: {
                    Label("Analyze with AI", systemImage: "sparkles")
                        .labelStyle(TitleAndIconLabelStyle())
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canAnalyze)
            } footer: {
                Text("Claude will estimate per-serving nutrition based on the ingredients above. Scanned ingredients use their exact macros; typed ones are estimated.")
            }
        }
    }

    private func ingredientRow(_ ingredient: RecipeIngredient) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ingredient.name)
                .font(.subheadline.weight(.medium))
            HStack(spacing: 6) {
                Text("\(formatAmount(ingredient.amount)) \(ingredient.unit)")
                    .monospacedDigit()
                if let brand = ingredient.brand, !brand.isEmpty {
                    Text("· \(brand)").lineLimit(1)
                }
                if ingredient.knownCaloriesPerUnit != nil {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Nutrition known")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Stage: analyzing

    private var analyzingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Claude is analyzing your recipe…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Stage: result

    private var resultView: some View {
        Form {
            if resultConfidence != nil || resultNotes != nil {
                Section {
                    if let resultConfidence {
                        HStack {
                            Image(systemName: "info.circle").foregroundStyle(.tint)
                            Text("Claude's confidence: \(resultConfidence)")
                                .font(.footnote)
                        }
                    }
                    if let resultNotes, !resultNotes.isEmpty {
                        Text(resultNotes)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                TextField("Name", text: $resultName)
                    .textInputAutocapitalization(.words)
            } header: {
                Text("Recipe")
            }

            Section {
                macroField(label: "Calories", text: $totalCaloriesText, suffix: "kcal")
                macroField(label: "Protein", text: $totalProteinText, suffix: "g")
                macroField(label: "Carbs", text: $totalCarbsText, suffix: "g")
                macroField(label: "Fat", text: $totalFatText, suffix: "g")
            } header: {
                Text("Total recipe nutrition")
            } footer: {
                Text("Estimated totals for the whole recipe. Edit anything that looks off.")
            }

            if !yieldOptions.isEmpty {
                Section {
                    Picker("Size", selection: $selectedYieldOptionId) {
                        ForEach(yieldOptions) { option in
                            Text(yieldOptionLabel(option)).tag(Optional(option.id))
                        }
                    }
                    .onChange(of: selectedYieldOptionId) { _, _ in
                        if let opt = currentYieldOption {
                            servingAmountText = formatAmount(opt.amount)
                        }
                    }

                    LabeledContent("Amount") {
                        HStack(spacing: 8) {
                            TextField("0", text: $servingAmountText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .frame(minWidth: 60)
                            Text(currentYieldOption?.unit ?? "")
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 50, alignment: .leading)
                        }
                    }

                    if let summary = servingsSummary {
                        HStack {
                            Image(systemName: "scalemass")
                                .foregroundStyle(.tint)
                            Text(summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Serving size")
                } footer: {
                    Text("Pick how you want to portion the recipe. Per-serving nutrition is computed from the totals above.")
                }

                Section {
                    perServingMacroRow(label: "Calories", value: perServing(.calories), suffix: "kcal")
                    perServingMacroRow(label: "Protein", value: perServing(.protein), suffix: "g")
                    perServingMacroRow(label: "Carbs", value: perServing(.carbs), suffix: "g")
                    perServingMacroRow(label: "Fat", value: perServing(.fat), suffix: "g")
                } header: {
                    Text("Per serving")
                }
            }

            Section {
                Button { saveToMyFoods() } label: {
                    Label("Save to My Foods", systemImage: "checkmark.circle.fill")
                        .labelStyle(TitleAndIconLabelStyle())
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSaveResult)

                Button("Back to ingredients") { stage = .build }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private enum Macro { case calories, protein, carbs, fat }

    private var totalCalories: Double { Double(totalCaloriesText) ?? 0 }
    private var totalProtein: Double { Double(totalProteinText) ?? 0 }
    private var totalCarbs: Double { Double(totalCarbsText) ?? 0 }
    private var totalFat: Double { Double(totalFatText) ?? 0 }
    private var servingAmount: Double {
        Double(servingAmountText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var currentYieldOption: RecipeYieldOption? {
        yieldOptions.first(where: { $0.id == selectedYieldOptionId })
    }

    /// Total recipe quantity expressed in the picked option's unit (e.g. 1000 g, 4 cup, 6 muffin).
    private var totalRecipeInPickedUnit: Double? {
        guard let opt = currentYieldOption else { return nil }
        return opt.amount * opt.servingsInRecipe
    }

    private var servingsCount: Double? {
        guard let total = totalRecipeInPickedUnit, servingAmount > 0 else { return nil }
        return total / servingAmount
    }

    private var servingsSummary: String? {
        guard let opt = currentYieldOption,
              let total = totalRecipeInPickedUnit,
              let count = servingsCount, count > 0 else { return nil }
        let totalDisplay = "\(formatAmount(total)) \(opt.unit)"
        let countDisplay = formatServingsCount(count)
        let amountDisplay = "\(formatAmount(servingAmount)) \(opt.unit)"
        return "Recipe yields \(totalDisplay) — \(countDisplay) servings of \(amountDisplay)."
    }

    private func perServing(_ macro: Macro) -> Double? {
        guard let count = servingsCount, count > 0 else { return nil }
        switch macro {
        case .calories: return totalCalories / count
        case .protein: return totalProtein / count
        case .carbs: return totalCarbs / count
        case .fat: return totalFat / count
        }
    }

    private func yieldOptionLabel(_ option: RecipeYieldOption) -> String {
        let amountStr = formatAmount(option.amount)
        let count = formatServingsCount(option.servingsInRecipe)
        return "\(amountStr) \(option.unit) (\(count) servings)"
    }

    @ViewBuilder
    private func perServingMacroRow(label: String, value: Double?, suffix: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value.map { formatPerServing($0, suffix: suffix) } ?? "—")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(value == nil ? .secondary : .primary)
        }
    }

    private func formatPerServing(_ value: Double, suffix: String) -> String {
        let rounded = suffix == "kcal"
            ? String(Int(value.rounded()))
            : String(format: value < 10 ? "%.1f" : "%.0f", value)
        return "\(rounded) \(suffix)"
    }

    private func formatServingsCount(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private var canSaveResult: Bool {
        !resultName.trimmingCharacters(in: .whitespaces).isEmpty
            && totalCalories >= 0
            && currentYieldOption != nil
            && servingAmount > 0
            && (servingsCount ?? 0) > 0
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

    // MARK: - Actions

    private func handleBarcode(_ code: String) async {
        guard let vm = lookupViewModel else { return }
        if let match = await vm.lookup(barcode: code) {
            // Default amount = one native unit (matches the portion sheet's first-open default).
            let ingredient = RecipeIngredient(
                name: match.name,
                amount: 1,
                unit: match.nativeUnit,
                brand: match.brand,
                knownCaloriesPerUnit: match.caloriesPerServing,
                knownProteinPerUnit: match.proteinPerServing,
                knownCarbsPerUnit: match.carbsPerServing,
                knownFatPerUnit: match.fatPerServing
            )
            ingredients.append(ingredient)
        } else {
            // Not in any DB — open manual entry pre-filled with the barcode in notes.
            manualPrefillBarcode = code
            showManualEntry = true
        }
    }

    private func analyze() async {
        errorMessage = nil
        stage = .analyzing
        let trimmedName = recipeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let serviceInput = RecipeAnalysisInput(
            recipeName: trimmedName,
            ingredients: ingredients.map(\.serviceIngredient)
        )
        do {
            let analyzed = try await recognitionEnv.service.analyzeRecipe(serviceInput)
            prefillResult(from: analyzed, fallbackName: trimmedName)
            stage = .result
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            stage = .build
        }
    }

    private func prefillResult(from analyzed: AnalyzedRecipe, fallbackName: String) {
        let trimmedAIName = analyzed.name.trimmingCharacters(in: .whitespacesAndNewlines)
        resultName = !trimmedAIName.isEmpty ? trimmedAIName
            : (!fallbackName.isEmpty ? fallbackName : "Recipe")
        totalCaloriesText = String(Int(analyzed.totalCalories.rounded()))
        totalProteinText = String(format: "%.1f", analyzed.totalProtein)
        totalCarbsText = String(format: "%.1f", analyzed.totalCarbs)
        totalFatText = String(format: "%.1f", analyzed.totalFat)
        resultConfidence = analyzed.confidence.flatMap { $0.isEmpty ? nil : $0 }
        resultNotes = analyzed.notes.flatMap { $0.isEmpty ? nil : $0 }
        yieldOptions = analyzed.yieldOptions
        if let first = yieldOptions.first {
            selectedYieldOptionId = first.id
            servingAmountText = formatAmount(first.amount)
        } else {
            selectedYieldOptionId = nil
            servingAmountText = ""
        }
    }

    private func saveToMyFoods() {
        let trimmedName = resultName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        guard let opt = currentYieldOption else { return }
        guard servingAmount > 0 else { return }
        guard let count = servingsCount, count > 0 else { return }

        let unit = opt.unit
        // Total recipe quantity in the user's chosen unit family — drives per-native macros so
        // the saved CachedFood can be scaled later through the portion sheet's normal pickers.
        let totalQtyInUnit = opt.amount * opt.servingsInRecipe
        let totalCals = totalCalories
        let totalP = totalProtein
        let totalC = totalCarbs
        let totalF = totalFat

        let nativeUnit: String
        let nativeUnitGrams: Double?
        let nativeUnitMilliliters: Double?
        let calsPerNative: Double
        let proteinPerNative: Double
        let carbsPerNative: Double
        let fatPerNative: Double

        if ServingMath.isMassUnit(unit) {
            // Loose-mass recipe: native = "g", per-gram macros. Picker preset = chosen mass unit.
            let totalGrams = ServingMath.grams(forSelectedUnit: unit, quantity: totalQtyInUnit) ?? totalQtyInUnit
            nativeUnit = "g"
            nativeUnitGrams = 1
            nativeUnitMilliliters = nil
            calsPerNative = totalCals / max(totalGrams, 1)
            proteinPerNative = totalP / max(totalGrams, 1)
            carbsPerNative = totalC / max(totalGrams, 1)
            fatPerNative = totalF / max(totalGrams, 1)
        } else if ServingMath.isVolumeUnit(unit) {
            // Loose-volume recipe: native = "ml", per-ml macros.
            let totalMl = ServingMath.milliliters(forSelectedUnit: unit, quantity: totalQtyInUnit) ?? totalQtyInUnit
            nativeUnit = "ml"
            nativeUnitGrams = nil
            nativeUnitMilliliters = 1
            calsPerNative = totalCals / max(totalMl, 1)
            proteinPerNative = totalP / max(totalMl, 1)
            carbsPerNative = totalC / max(totalMl, 1)
            fatPerNative = totalF / max(totalMl, 1)
        } else {
            // Countable native (muffin / batch / patty / slice). Per-native = per one of those.
            let safeTotal = max(totalQtyInUnit, 0.0001)
            nativeUnit = unit
            nativeUnitGrams = nil
            nativeUnitMilliliters = nil
            calsPerNative = totalCals / safeTotal
            proteinPerNative = totalP / safeTotal
            carbsPerNative = totalC / safeTotal
            fatPerNative = totalF / safeTotal
        }

        let ingredientSummary = ingredients
            .map { "• \(formatAmount($0.amount)) \($0.unit) \($0.name)" }
            .joined(separator: "\n")
        let yieldLine = "Yields \(formatAmount(totalQtyInUnit)) \(opt.unit) total · default serving \(formatAmount(servingAmount)) \(opt.unit) (\(formatServingsCount(count)) servings)"
        let combinedNotes = [
            yieldLine,
            "Ingredients:",
            ingredientSummary,
            resultNotes
        ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        let cached = CachedFood(
            externalId: "recipe:\(UUID().uuidString)",
            name: trimmedName,
            brand: nil,
            nativeUnit: nativeUnit,
            nativeUnitGrams: nativeUnitGrams,
            nativeUnitMilliliters: nativeUnitMilliliters,
            lastSelectedUnit: unit,
            lastSelectedQuantity: servingAmount,
            caloriesPerServing: calsPerNative,
            proteinPerServing: proteinPerNative,
            carbsPerServing: carbsPerNative,
            fatPerServing: fatPerNative,
            source: .manual,
            isInMyFoods: true,
            lastUsed: .now,
            useCount: 0,
            notes: combinedNotes.isEmpty ? nil : combinedNotes
        )
        modelContext.insert(cached)
        try? modelContext.save()
        dismiss()
        onSaved()
    }

    private func formatAmount(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

// MARK: - In-memory ingredient model

/// UI-layer ingredient. `knownCaloriesPerUnit` (etc.) is set when the ingredient came from a
/// barcode lookup — values are *per one unit* of the food's native unit, the same shape as
/// `CachedFood.caloriesPerServing` / `FoodSearchResult.caloriesPerServing`. Manual ingredients
/// leave them nil so the AI estimates from name + amount.
struct RecipeIngredient: Identifiable, Hashable {
    let id: UUID
    var name: String
    var amount: Double
    var unit: String
    var brand: String?
    var knownCaloriesPerUnit: Double?
    var knownProteinPerUnit: Double?
    var knownCarbsPerUnit: Double?
    var knownFatPerUnit: Double?

    init(
        id: UUID = UUID(),
        name: String,
        amount: Double,
        unit: String,
        brand: String? = nil,
        knownCaloriesPerUnit: Double? = nil,
        knownProteinPerUnit: Double? = nil,
        knownCarbsPerUnit: Double? = nil,
        knownFatPerUnit: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.amount = amount
        self.unit = unit
        self.brand = brand
        self.knownCaloriesPerUnit = knownCaloriesPerUnit
        self.knownProteinPerUnit = knownProteinPerUnit
        self.knownCarbsPerUnit = knownCarbsPerUnit
        self.knownFatPerUnit = knownFatPerUnit
    }

    /// Convert to the service-layer ingredient. Per-unit known macros are scaled by `amount`
    /// here so the AI sees pre-multiplied totals (matching the protocol's contract).
    var serviceIngredient: RecipeAnalysisInput.Ingredient {
        RecipeAnalysisInput.Ingredient(
            name: name,
            amount: amount,
            unit: unit,
            brand: brand,
            knownCalories: knownCaloriesPerUnit.map { $0 * amount },
            knownProtein: knownProteinPerUnit.map { $0 * amount },
            knownCarbs: knownCarbsPerUnit.map { $0 * amount },
            knownFat: knownFatPerUnit.map { $0 * amount }
        )
    }
}

// MARK: - Manual ingredient entry sheet

/// Capture a single ingredient via name + amount + unit (no nutrition — the AI estimates).
/// Used by the Recipe Analyzer's "Manual Entry" path and as the fallback when a barcode scan
/// turns up no match.
struct RecipeIngredientEntrySheet: View {
    var prefillBarcode: String?
    let onAdd: (RecipeIngredient) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var brand: String = ""
    @State private var amountText: String = ""
    @State private var unit: String = "g"

    /// Mirrors QuickAddForm.unitOptions so units feel consistent across manual flows.
    private let unitOptions: [String] = [
        "g", "oz", "lb", "kg",
        "ml", "fl oz", "cup", "tbsp", "tsp", "l",
        "ea", "bar", "slice", "piece", "bowl", "package", "batch",
    ]

    private var amount: Double? {
        Double(amountText.replacingOccurrences(of: ",", with: "."))
    }

    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (amount ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                if let prefillBarcode {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "barcode.viewfinder").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Not found in database")
                                    .font(.subheadline.weight(.semibold))
                                Text("Barcode \(prefillBarcode) — add this ingredient manually.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    TextField("Name (e.g. rolled oats)", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Brand (optional)", text: $brand)
                        .textInputAutocapitalization(.words)
                    LabeledContent("Amount") {
                        HStack(spacing: 8) {
                            TextField("0", text: $amountText)
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
                } header: {
                    Text("Ingredient")
                } footer: {
                    Text("Claude will estimate this ingredient's nutrition from the name and amount.")
                }

                Section {
                    Button { add() } label: {
                        Text("Add Ingredient")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canAdd)
                }
            }
            .navigationTitle("Add Ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func add() {
        guard let amount, amount > 0 else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let trimmedBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let ingredient = RecipeIngredient(
            name: trimmedName,
            amount: amount,
            unit: unit,
            brand: trimmedBrand.isEmpty ? nil : trimmedBrand
        )
        onAdd(ingredient)
        dismiss()
    }
}
