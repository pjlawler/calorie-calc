import SwiftUI
import SwiftData

struct FoodSearchView: View {

    let mealType: MealType
    let date: Date

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(FoodDataSourceEnvironment.self) private var dataSourceEnv

    @Query(sort: \CachedFood.lastUsed, order: .reverse)
    private var cachedFoods: [CachedFood]

    @State private var viewModel: FoodSearchViewModel?
    @State private var tab: Tab = .search
    @State private var showScanner = false
    @State private var showQuickAdd = false
    @State private var showPhotoAnalyzer = false
    @State private var showDescribe = false
    @State private var quickAddBarcode: String?
    @State private var portionTarget: FoodSearchResult?

    /// Shared with the Foods tab via the same `@AppStorage` key — toggling in one place is
    /// reflected in the other so the user's "show only favorites" preference is global.
    @AppStorage("foodsView.showFavoritesOnly") private var showFavoritesOnly: Bool = false

    enum Tab: String, CaseIterable, Hashable {
        case search = "Search"
        case recents = "Recents"
        case myFoods = "My Foods"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { t in Text(t.rawValue).tag(t) }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])

                tabContent
            }
            .navigationTitle("Add to \(mealType.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                if tab == .recents || tab == .myFoods {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showFavoritesOnly.toggle()
                        } label: {
                            Image(systemName: showFavoritesOnly ? "star.fill" : "star")
                                .foregroundStyle(showFavoritesOnly ? Color.yellow : Color.accentColor)
                        }
                        .accessibilityLabel(showFavoritesOnly ? "Show all" : "Show only favorites")
                    }
                }
            }
            .task {
                if viewModel == nil {
                    viewModel = FoodSearchViewModel(dataSource: dataSourceEnv.dataSource)
                }
            }
            .sheet(item: $portionTarget) { target in
                FoodPortionSheet(result: target, mealType: mealType, date: date) { }
            }
            .sheet(isPresented: $showScanner) {
                BarcodeScannerView { code in
                    showScanner = false
                    Task { await handleScan(code: code) }
                }
            }
            .sheet(isPresented: $showQuickAdd) {
                QuickAddSheet(
                    mealType: mealType,
                    date: date,
                    scannedBarcode: quickAddBarcode
                ) {
                    showQuickAdd = false
                }
            }
            .sheet(isPresented: $showPhotoAnalyzer) {
                FoodPhotoSheet(mealType: mealType, date: date) { }
            }
            .sheet(isPresented: $showDescribe) {
                FoodDescribeSheet { result in
                    portionTarget = result
                }
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .search: searchTab
        case .recents: recentsTab
        case .myFoods: myFoodsTab
        }
    }

    private var searchTab: some View {
        let binding = Binding<String>(
            get: { viewModel?.query ?? "" },
            set: { newValue in
                viewModel?.query = newValue
                viewModel?.queryChanged(newValue)
            }
        )
        let query = viewModel?.query.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cachedMatches = matchingCachedFoods(for: query)
        let cachedIds = Set(cachedMatches.compactMap(\.externalId))
        let apiResults = (viewModel?.results ?? []).filter { !cachedIds.contains($0.id) }

        return List {
            if query.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        quickActionTile(title: "Scan", systemImage: "barcode.viewfinder") {
                            showScanner = true
                        }
                        quickActionTile(title: "Photo", systemImage: "camera.fill") {
                            showPhotoAnalyzer = true
                        }
                        quickActionTile(title: "Describe", systemImage: "sparkles") {
                            showDescribe = true
                        }
                        quickActionTile(title: "Manual", systemImage: "square.and.pencil") {
                            quickAddBarcode = nil
                            showQuickAdd = true
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
                }
            }
            if let vm = viewModel, vm.isSearching {
                HStack { ProgressView(); Text("Searching foods…") }
                    .foregroundStyle(.secondary)
            }
            if let error = viewModel?.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if !cachedMatches.isEmpty {
                Section("Your foods") {
                    ForEach(cachedMatches, id: \.id) { cached in
                        cachedRow(cached)
                    }
                }
            }
            if !apiResults.isEmpty {
                Section(cachedMatches.isEmpty ? "" : "Food database") {
                    ForEach(apiResults) { result in
                        Button {
                            portionTarget = result
                        } label: {
                            FoodResultRow(result: result)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .searchable(text: binding, prompt: "Search foods")
    }

    private func quickActionTile(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Cached foods (recents + favorites) whose name or brand contains the query string.
    /// Favorites sort first, then by recency. Empty query returns `[]` so the recents/favorites
    /// tabs remain the home for uncontextualized browsing.
    private func matchingCachedFoods(for query: String) -> [CachedFood] {
        guard !query.isEmpty else { return [] }
        let lower = query.lowercased()
        return cachedFoods
            .filter { cached in
                cached.name.lowercased().contains(lower)
                    || (cached.brand?.lowercased().contains(lower) ?? false)
            }
            .sorted { lhs, rhs in
                if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
                return lhs.lastUsed > rhs.lastUsed
            }
            .prefix(20)
            .map { $0 }
    }

    private var recentsTab: some View {
        List {
            ForEach(recentFoods, id: \.id) { cached in
                cachedRow(cached, forFavorites: false)
            }
            .onDelete(perform: deleteRecentFoods)
        }
    }

    /// Unified My Foods catalog. Favorites sort first, then alphabetical. The star icon on each
    /// row toggles `isFavorite`; a row in this list always has `isInMyFoods == true` already, so
    /// starring/unstarring just adjusts the highlight + sort position.
    private var myFoodsTab: some View {
        List {
            ForEach(myFoods, id: \.id) { cached in
                cachedRow(cached, forFavorites: cached.isFavorite)
            }
        }
    }

    private var myFoods: [CachedFood] {
        cachedFoods
            .filter { $0.isInMyFoods && (!showFavoritesOnly || $0.isFavorite) }
            .sorted(by: CachedFood.myFoodsSort)
    }

    private func cachedRow(_ cached: CachedFood, forFavorites: Bool = false) -> some View {
        Button {
            portionTarget = cached.toSearchResult(forFavorites: forFavorites)
        } label: {
            CachedFoodRow(cached: cached) {
                CachedFood.toggleFavorite(cached, in: modelContext)
            }
        }
        .buttonStyle(.plain)
    }

    private var recentFoods: [CachedFood] {
        cachedFoods
            .filter { $0.useCount > 0 && (!showFavoritesOnly || $0.isFavorite) }
            .sorted(by: { $0.lastUsed > $1.lastUsed })
            .prefix(100)
            .map { $0 }
    }

    private func deleteRecentFoods(at offsets: IndexSet) {
        for index in offsets {
            let cached = recentFoods[index]
            if cached.isFavorite || cached.isInMyFoods {
                // Keep persistent items (favorites + My Foods) accessible in their tabs while
                // removing them from Recents.
                cached.useCount = 0
            } else {
                modelContext.delete(cached)
            }
        }
        try? modelContext.save()
    }

    private func handleScan(code: String) async {
        guard let vm = viewModel else { return }
        if let match = await vm.lookup(barcode: code) {
            portionTarget = match
        } else {
            // Not in USDA or Open Food Facts — open Quick Add pre-filled with the barcode.
            quickAddBarcode = code
            showQuickAdd = true
        }
    }
}

private struct FoodResultRow: View {
    let result: FoodSearchResult

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name).lineLimit(1)
                HStack(spacing: 6) {
                    if let brand = result.brand { Text(brand).lineLimit(1) }
                    Text(result.rowCaption).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(CalorieFormatter.whole(rowCalories)) kcal")
                .font(.subheadline.monospacedDigit())
        }
        .padding(.vertical, 2)
    }

    /// kcal shown on the search row — corresponds to the row caption (one native unit, or the
    /// loose-food default like "100 g").
    private var rowCalories: Double {
        let nativeIsMeasurement = ServingMath.isMeasurementUnit(result.nativeUnit)
        if !nativeIsMeasurement {
            return result.caloriesPerServing
        }
        return result.caloriesPerServing * result.initialSelectedQuantity
    }
}

struct CachedFoodRow: View {
    let cached: CachedFood
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggleFavorite) {
                Image(systemName: cached.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(cached.isFavorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(cached.isFavorite ? "Remove from favorites" : "Add to favorites")

            VStack(alignment: .leading, spacing: 2) {
                Text(cached.name).lineLimit(1)
                HStack(spacing: 6) {
                    if let brand = cached.brand { Text(brand).lineLimit(1) }
                    Text(cached.rowCaption).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(CalorieFormatter.whole(rowCalories)) kcal")
                .font(.subheadline.monospacedDigit())
        }
    }

    private var rowCalories: Double {
        // For sticky-preset cached foods, show the calories at the user's last-picked serving so
        // the row matches what reopening will load. Falls back to per-native otherwise.
        if let unit = cached.lastSelectedUnit, let qty = cached.lastSelectedQuantity {
            let factor = ServingMath.nativeUnitsConsumed(
                selectedUnit: unit,
                quantity: qty,
                nativeUnit: cached.nativeUnit,
                nativeUnitGrams: cached.nativeUnitGrams,
                nativeUnitMilliliters: cached.nativeUnitMilliliters
            )
            return cached.caloriesPerServing * factor
        }
        return cached.caloriesPerServing
    }
}

extension CachedFood {
    /// Search-row caption mirrors `FoodSearchResult.rowCaption`. Prefers the user's sticky preset
    /// when present so Recents reads as "2 bar" / "57 g" matching their last log.
    var rowCaption: String {
        if let unit = lastSelectedUnit, let qty = lastSelectedQuantity {
            return ServingMath.displayConsumed(quantity: qty, unit: unit)
        }
        let nativeIsMeasurement = ServingMath.isMeasurementUnit(nativeUnit)
        if !nativeIsMeasurement {
            if let g = nativeUnitGrams, g > 0 { return "1 \(nativeUnit) (\(formatNumber(g))g)" }
            if let ml = nativeUnitMilliliters, ml > 0 { return "1 \(nativeUnit) (\(formatNumber(ml))ml)" }
            return "1 \(nativeUnit)"
        }
        return "1 \(nativeUnit)"
    }

    /// `forFavorites: true` uses the locked favorite preset (the unit + quantity captured at
    /// favorite time) instead of the user's most-recent pick, so the Favorites tab opens the food
    /// with the serving they originally favorited even if later logs changed it.
    func toSearchResult(forFavorites: Bool = false) -> FoodSearchResult {
        let initialUnit: String
        let initialQty: Double
        if forFavorites, let unit = favoriteSelectedUnit, let qty = favoriteSelectedQuantity {
            initialUnit = unit
            initialQty = qty
        } else if let unit = lastSelectedUnit, let qty = lastSelectedQuantity {
            initialUnit = unit
            initialQty = qty
        } else {
            initialUnit = nativeUnit
            initialQty = 1
        }
        return FoodSearchResult(
            id: externalId ?? id.uuidString,
            name: name,
            brand: brand,
            nativeUnit: nativeUnit,
            nativeUnitGrams: nativeUnitGrams,
            nativeUnitMilliliters: nativeUnitMilliliters,
            initialSelectedUnit: initialUnit,
            initialSelectedQuantity: initialQty,
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
