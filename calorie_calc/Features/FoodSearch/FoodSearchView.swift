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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showScanner = true
                    } label: {
                        Image(systemName: "barcode.viewfinder")
                    }
                    .accessibilityLabel("Scan barcode")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        quickAddBarcode = nil
                        showQuickAdd = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("Quick add")
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
        return List {
            if let vm = viewModel, vm.isSearching {
                HStack { ProgressView(); Text("Searching USDA…") }
                    .foregroundStyle(.secondary)
            }
            if let error = viewModel?.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            ForEach(viewModel?.results ?? []) { result in
                Button {
                    portionTarget = result
                } label: {
                    FoodResultRow(result: result)
                }
                .buttonStyle(.plain)
            }
        }
        .searchable(text: binding, prompt: "Search USDA foods")
    }

    private var recentsTab: some View {
        List {
            ForEach(cachedFoods.sorted(by: { $0.lastUsed > $1.lastUsed }).prefix(50), id: \.id) { cached in
                Button {
                    portionTarget = cached.toSearchResult()
                } label: {
                    CachedFoodRow(cached: cached)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var favoritesTab: some View {
        List {
            ForEach(cachedFoods.filter { $0.isFavorite }, id: \.id) { cached in
                Button {
                    portionTarget = cached.toSearchResult()
                } label: {
                    CachedFoodRow(cached: cached)
                }
                .buttonStyle(.plain)
            }
        }
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

    var body: some View {
        HStack {
            if cached.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
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
    func toSearchResult() -> FoodSearchResult {
        FoodSearchResult(
            id: externalId ?? id.uuidString,
            name: name,
            brand: brand,
            servingDescription: defaultServingDescription,
            servingSizeGrams: defaultServingSizeGrams,
            caloriesPerServing: caloriesPerServing,
            proteinPerServing: proteinPerServing,
            carbsPerServing: carbsPerServing,
            fatPerServing: fatPerServing,
            source: source
        )
    }
}
