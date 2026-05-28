import SwiftUI
import SwiftData

struct FoodSearchView: View {

    let date: Date

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(FoodDataSourceEnvironment.self) private var dataSourceEnv
    @Environment(AIConsentService.self) private var aiConsent

    @Query(sort: \CachedFood.lastUsed, order: .reverse)
    private var cachedFoods: [CachedFood]
    @Query(sort: \FoodTag.name) private var allTags: [FoodTag]
    @State private var selectedTagIds: Set<UUID> = []

    @State private var mealType: MealType
    @State private var viewModel: FoodSearchViewModel?
    @State private var tab: Tab = .recents
    @State private var showScanner = false
    @State private var showQuickAdd = false
    @State private var showPhotoAnalyzer = false
    @State private var showDescribe = false
    @State private var quickAddBarcode: String?
    @State private var portionTarget: FoodSearchResult?

    // First-use consent gate for the Photo and Describe quick-action tiles. Mirrors
    // the same pattern in FoodsView — see AIConsentSheet + AIConsentService.
    @State private var showAIConsent = false
    @State private var pendingAIAction: (() -> Void)?

    /// Defaults the meal picker to the time-of-day-appropriate slot (breakfast / lunch /
    /// dinner / snack). Callers can override when they need a specific meal.
    init(date: Date, initialMealType: MealType = .quickAddDefaultForCurrentTime()) {
        self.date = date
        _mealType = State(initialValue: initialMealType)
    }

    /// Shared with the Foods tab via the same `@AppStorage` key — toggling in one place is
    /// reflected in the other so the user's "show only favorites" preference is global.
    @AppStorage("foodsView.showFavoritesOnly") private var showFavoritesOnly: Bool = false

    /// Persistent user preference for Recents tab sort order. Defaults to most-recently-used
    /// since that's what the tab is primarily for; alphabetical is the alternative for users who
    /// scan by name.
    @AppStorage("foodSearch.recentsSort") private var recentsSortRaw: String = RecentsSort.lastUsed.rawValue

    enum Tab: String, CaseIterable, Hashable {
        case recents = "Recents"
        case myFoods = "My Foods"
    }

    enum RecentsSort: String, CaseIterable, Hashable {
        case lastUsed
        case alphabetical

        var displayName: String {
            switch self {
            case .lastUsed: return "Most Recent"
            case .alphabetical: return "A–Z"
            }
        }

        var symbolName: String {
            switch self {
            case .lastUsed: return "clock"
            case .alphabetical: return "textformat"
            }
        }
    }

    private var recentsSort: RecentsSort {
        RecentsSort(rawValue: recentsSortRaw) ?? .lastUsed
    }

    /// Drives the search bar (always pinned in the nav-bar drawer). Mutating this also notifies
    /// the view model so the API debounce kicks off.
    private var searchBinding: Binding<String> {
        Binding(
            get: { viewModel?.query ?? "" },
            set: { newValue in
                viewModel?.query = newValue
                viewModel?.queryChanged(newValue)
            }
        )
    }

    private var searchQuery: String {
        viewModel?.query.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                actionTilesRow
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                // Picker + filter bar only matter when browsing — when a search query is
                // active the bottom area becomes a single combined results list that doesn't
                // belong to either tab, so we hide the chrome to keep the focus on results.
                if searchQuery.isEmpty {
                    Picker("Section", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { t in Text(t.rawValue).tag(t) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 8)

                    filterBar
                        .padding(.vertical, 12)
                }

                tabContent
            }
            .searchable(text: searchBinding, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Menu {
                        Picker("Meal", selection: $mealType) {
                            ForEach(MealType.allCases.sorted(by: { $0.order < $1.order }), id: \.self) { meal in
                                Label(meal.displayName, systemImage: meal.symbolName).tag(meal)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Add to \(mealType.displayName)")
                                .font(.headline)
                            Image(systemName: "chevron.down")
                                .font(.footnote)
                        }
                        .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("Change meal")
                }
                // Sort options only matter on Recents; My Foods has its own fixed
                // favourites-first-then-alphabetical sort that the user doesn't override.
                if tab == .recents && searchQuery.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("Sort", selection: Binding(
                                get: { recentsSort },
                                set: { recentsSortRaw = $0.rawValue }
                            )) {
                                ForEach(RecentsSort.allCases, id: \.self) { option in
                                    Label(option.displayName, systemImage: option.symbolName).tag(option)
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        .accessibilityLabel("Sort Recents")
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
            .sheet(isPresented: $showAIConsent, onDismiss: { pendingAIAction = nil }) {
                AIConsentSheet(onAllow: {
                    let action = pendingAIAction
                    pendingAIAction = nil
                    action?()
                })
            }
        }
    }

    /// Pre-grant: stash the action and show the disclosure sheet; on Allow it fires.
    /// Post-grant: runs immediately. See AIConsentService for the persisted state.
    private func requestAI(_ action: @escaping () -> Void) {
        if aiConsent.isGranted {
            action()
        } else {
            pendingAIAction = action
            showAIConsent = true
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        if !searchQuery.isEmpty {
            searchResultsContent(query: searchQuery)
        } else {
            switch tab {
            case .recents: recentsTab
            case .myFoods: myFoodsTab
            }
        }
    }

    /// Combined search results — matched recents above matched My Foods, then USDA/OFF API hits. A
    /// food that's both recently logged and saved appears in both sections (each section is its own
    /// category). Dedup happens *within* a section, so duplicate rows for the same food (same name +
    /// brand captured through different sources) collapse to one. Action tiles live in the
    /// always-pinned `actionTilesRow` above, so they're absent here.
    private func searchResultsContent(query: String) -> some View {
        let lower = query.lowercased()
        let matched = cachedFoods.filter { cached in
            cached.name.lowercased().contains(lower)
                || (cached.brand?.lowercased().contains(lower) ?? false)
        }

        let recentsMatches = dedupedByIdentity(matched.filter { $0.useCount > 0 })
            .sorted { $0.lastUsed > $1.lastUsed }
            .prefix(20)
            .map { $0 }

        let myFoodsMatches = dedupedByIdentity(matched.filter { $0.isInMyFoods })
            .sorted(by: CachedFood.myFoodsSort)
            .prefix(20)
            .map { $0 }

        let cachedExternalIds = Set((recentsMatches + myFoodsMatches).compactMap(\.externalId))
        let apiResults = (viewModel?.results ?? []).filter { !cachedExternalIds.contains($0.id) }

        return List {
            if let vm = viewModel, vm.isSearching {
                HStack { ProgressView(); Text("Searching foods…") }
                    .foregroundStyle(.secondary)
            }
            if let error = viewModel?.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if !recentsMatches.isEmpty {
                Section("Your Recents") {
                    ForEach(recentsMatches, id: \.id) { cached in
                        cachedRow(cached)
                    }
                }
            }
            if !myFoodsMatches.isEmpty {
                Section("Your Foods") {
                    ForEach(myFoodsMatches, id: \.id) { cached in
                        cachedRow(cached, forFavorites: cached.isFavorite)
                    }
                }
            }
            if !apiResults.isEmpty {
                Section((recentsMatches.isEmpty && myFoodsMatches.isEmpty) ? "" : "Food database") {
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
    }

    /// Always-pinned row of one-tap shortcuts. Lives above the Recents/My Foods picker so it's
    /// reachable regardless of which tab is showing or whether a search query is active.
    private var actionTilesRow: some View {
        HStack(spacing: 10) {
            quickActionTile(title: "Scan", systemImage: "barcode.viewfinder") {
                showScanner = true
            }
            quickActionTile(title: "Photo", systemImage: "camera.fill") {
                requestAI { showPhotoAnalyzer = true }
            }
            quickActionTile(title: "Describe", systemImage: "sparkles") {
                requestAI { showDescribe = true }
            }
            quickActionTile(title: "Manual", systemImage: "square.and.pencil") {
                quickAddBarcode = nil
                showQuickAdd = true
            }
        }
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

    /// Collapses CachedFood rows that represent the same food (same name + brand, case-insensitive)
    /// down to one best representative. The same physical food lands in multiple rows when it's
    /// captured through different sources — a barcode scan, an AI estimate, and a manual entry each
    /// get their own externalId, so id-based dedup can't merge them and the search list shows the
    /// food twice. Preference order: favorite, then in My Foods, then most-logged, then most-recent,
    /// so the curated row wins and its star state is preserved.
    private func dedupedByIdentity(_ foods: [CachedFood]) -> [CachedFood] {
        func key(_ f: CachedFood) -> String {
            let name = f.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let brand = (f.brand ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return name + "|" + brand
        }
        func isBetter(_ a: CachedFood, than b: CachedFood) -> Bool {
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            if a.isInMyFoods != b.isInMyFoods { return a.isInMyFoods }
            if a.useCount != b.useCount { return a.useCount > b.useCount }
            return a.lastUsed > b.lastUsed
        }
        var best: [String: CachedFood] = [:]
        for f in foods {
            let k = key(f)
            if let current = best[k] {
                if isBetter(f, than: current) { best[k] = f }
            } else {
                best[k] = f
            }
        }
        return Array(best.values)
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
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            .onDelete(perform: deleteRecentFoods)
        }
        .listStyle(.plain)
    }

    /// Unified My Foods catalog. Favorites sort first, then alphabetical. The star icon on each
    /// row toggles `isFavorite`; a row in this list always has `isInMyFoods == true` already, so
    /// starring/unstarring just adjusts the highlight + sort position. Plain-style list with
    /// matching row insets so the look mirrors the main Foods tab.
    private var myFoodsTab: some View {
        List {
            ForEach(myFoods, id: \.id) { cached in
                cachedRow(cached, forFavorites: cached.isFavorite)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
        }
        .listStyle(.plain)
    }

    private var myFoods: [CachedFood] {
        cachedFoods
            .filter { $0.isInMyFoods && (!showFavoritesOnly || $0.isFavorite) }
            .filter { matchesTagFilter($0) }
            .sorted(by: CachedFood.myFoodsSort)
    }

    /// AND semantics: a food passes only if it carries every selected tag id.
    /// Mirrors the filter logic in FoodsView so behaviour is consistent across tabs.
    private func matchesTagFilter(_ food: CachedFood) -> Bool {
        guard !selectedTagIds.isEmpty else { return true }
        let foodTagIds = Set(food.tagsList.map(\.id))
        return selectedTagIds.isSubset(of: foodTagIds)
    }

    /// Favorite-toggle star + every existing tag chip on a horizontal scroll row.
    /// Mirrors the `filterBar` used on the My Foods tab so the favourites-and-tags
    /// filter UI behaves identically across the two surfaces. Only rendered on the
    /// Recents and My Foods tabs (the Search tab queries the food database, which
    /// neither favourite nor tag filters apply to).
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { showFavoritesOnly.toggle() }
                } label: {
                    Image(systemName: showFavoritesOnly ? "bolt.fill" : "bolt")
                        .font(.title3)
                        .foregroundStyle(showFavoritesOnly ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                        .contentTransition(.identity)
                        .animation(nil, value: showFavoritesOnly)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showFavoritesOnly ? "Show all foods" : "Show only My Staples")

                ForEach(allTags) { tag in
                    Button {
                        if selectedTagIds.contains(tag.id) {
                            selectedTagIds.remove(tag.id)
                        } else {
                            selectedTagIds.insert(tag.id)
                        }
                    } label: {
                        TagChipView(name: tag.name, color: tag.color, isSelected: selectedTagIds.contains(tag.id))
                    }
                    .buttonStyle(.plain)
                }
                if !selectedTagIds.isEmpty {
                    Button { selectedTagIds.removeAll() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                            Text("Clear")
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func cachedRow(_ cached: CachedFood, forFavorites: Bool = false) -> some View {
        Button {
            portionTarget = cached.toSearchResult(forFavorites: forFavorites)
        } label: {
            CachedFoodRow(cached: cached, showServingSize: true) {
                CachedFood.toggleFavorite(cached, in: modelContext)
            }
        }
        .buttonStyle(.plain)
    }

    private var recentFoods: [CachedFood] {
        let filtered = cachedFoods
            .filter { $0.useCount > 0 && (!showFavoritesOnly || $0.isFavorite) }
            .filter { matchesTagFilter($0) }
        let sorted: [CachedFood]
        switch recentsSort {
        case .lastUsed:
            sorted = filtered.sorted { $0.lastUsed > $1.lastUsed }
        case .alphabetical:
            sorted = filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return Array(sorted.prefix(100))
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
    var showServingSize: Bool = false
    let onToggleFavorite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(cached.name)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack(spacing: 6) {
                if showServingSize {
                    Text(cached.rowCaption)
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if cached.brand != nil {
                        Rectangle()
                            .fill(.tertiary)
                            .frame(width: 1, height: 10)
                    }
                }
                if let brand = cached.brand {
                    Text(brand)
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                }
                Spacer(minLength: 8)
                if !cached.tagsList.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(cached.tagsList) { tag in
                            Circle()
                                .fill(tag.color.swiftUIColor)
                                .frame(width: 8, height: 8)
                                .accessibilityLabel(Text(tag.name))
                        }
                    }
                    .padding(.trailing, 4)
                }
                Button(action: onToggleFavorite) {
                    Image(systemName: cached.isFavorite ? "bolt.fill" : "bolt")
                        .foregroundStyle(cached.isFavorite ? Color.orange : Color.secondary)
                        .frame(width: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(cached.isFavorite ? "Remove from My Staples" : "Add to My Staples")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
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
