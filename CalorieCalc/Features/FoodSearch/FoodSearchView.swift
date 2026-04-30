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

    enum Tab: String, CaseIterable, Hashable {
        case search = "Search"
        case recents = "Recents"
        case favorites = "Favorites"
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
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                if viewModel == nil {
                    viewModel = FoodSearchViewModel(dataSource: dataSourceEnv.dataSource)
                }
            }
            .sheet(item: $portionTarget) { target in
                FoodPortionSheet(result: target, mealType: mealType, date: date) {
                    dismiss()
                }
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
                    dismiss()
                }
            }
            .sheet(isPresented: $showPhotoAnalyzer) {
                FoodPhotoSheet(mealType: mealType, date: date) {
                    dismiss()
                }
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
        case .favorites: favoritesTab
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

    private var favoritesTab: some View {
        List {
            ForEach(cachedFoods.filter { $0.isFavorite }, id: \.id) { cached in
                cachedRow(cached, forFavorites: true)
            }
        }
    }

    private func cachedRow(_ cached: CachedFood, forFavorites: Bool = false) -> some View {
        Button {
            portionTarget = cached.toSearchResult(forFavorites: forFavorites)
        } label: {
            CachedFoodRow(cached: cached) {
                cached.isFavorite.toggle()
                if !cached.isFavorite && cached.useCount == 0 {
                    modelContext.delete(cached)
                }
                try? modelContext.save()
            }
        }
        .buttonStyle(.plain)
    }

    private var recentFoods: [CachedFood] {
        cachedFoods
            .filter { $0.useCount > 0 }
            .sorted(by: { $0.lastUsed > $1.lastUsed })
            .prefix(100)
            .map { $0 }
    }

    private func deleteRecentFoods(at offsets: IndexSet) {
        for index in offsets {
            let cached = recentFoods[index]
            if cached.isFavorite {
                // Keep favorites available in the Favorites tab while removing from Recents.
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
                    Text(result.servingDescription).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(CalorieFormatter.whole(result.caloriesPerServing)) kcal")
                .font(.subheadline.monospacedDigit())
        }
        .padding(.vertical, 2)
    }
}

private struct CachedFoodRow: View {
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
                    Text(cached.defaultServingDescription).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(CalorieFormatter.whole(cached.caloriesPerServing)) kcal")
                .font(.subheadline.monospacedDigit())
        }
    }
}

extension CachedFood {
    /// `forFavorites: true` substitutes the locked favorite snapshot for the live default fields
    /// so the Favorites tab opens the food with the serving the user originally favorited, even
    /// if their last log used a different size. Falls back to the live fields when no snapshot
    /// has been captured yet.
    func toSearchResult(forFavorites: Bool = false) -> FoodSearchResult {
        let useFav = forFavorites && favoriteServingDescription != nil
        return FoodSearchResult(
            id: externalId ?? id.uuidString,
            name: name,
            brand: brand,
            servingDescription: useFav ? (favoriteServingDescription ?? defaultServingDescription) : defaultServingDescription,
            servingSizeGrams: useFav ? favoriteServingSizeGrams : defaultServingSizeGrams,
            servingSizeMilliliters: useFav ? favoriteServingSizeMilliliters : defaultServingSizeMilliliters,
            caloriesPerServing: useFav ? (favoriteCaloriesPerServing ?? caloriesPerServing) : caloriesPerServing,
            proteinPerServing: useFav ? (favoriteProteinPerServing ?? proteinPerServing) : proteinPerServing,
            carbsPerServing: useFav ? (favoriteCarbsPerServing ?? carbsPerServing) : carbsPerServing,
            fatPerServing: useFav ? (favoriteFatPerServing ?? fatPerServing) : fatPerServing,
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
