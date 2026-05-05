import SwiftUI
import SwiftData

/// Top-level "Foods" tab — shows the user's saved My Foods catalog. Tapping a row opens the
/// portion sheet so the food can be logged to today's current-meal slot. Trailing-swipe
/// surfaces Delete (removes from My Foods) and Edit (edit the food's name / brand / macros).
/// The Add toolbar button kicks off scan / photo / describe / manual flows that create
/// new foods directly into My Foods.
struct FoodsView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(FoodDataSourceEnvironment.self) private var dataSourceEnv
    @Query(sort: \CachedFood.lastUsed, order: .reverse)
    private var cachedFoods: [CachedFood]

    @State private var portionTarget: FoodSearchResult?
    /// Distinct from `portionTarget` so the create-flow can flag the result as
    /// `addToMyFoods: true`. Tapping an existing row uses `portionTarget` (no flag).
    @State private var newFoodTarget: FoodSearchResult?
    @State private var editingFood: CachedFood?
    @State private var showSettings = false

    /// Persisted between launches so the user's filter preference sticks. When `true`, the list
    /// shows only favorites; when `false`, the full My Foods catalog.
    @AppStorage("foodsView.showFavoritesOnly") private var showFavoritesOnly: Bool = false

    // Add-to-My-Foods flow state.
    @State private var showAddOptions = false
    @State private var showScanner = false
    @State private var showPhotoAnalyzer = false
    @State private var showDescribe = false
    @State private var showQuickAdd = false
    @State private var showRecipeBuilder = false
    @State private var quickAddBarcode: String?
    @State private var addLookupViewModel: FoodSearchViewModel?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Color.clear.frame(height: 0).id("top").listRowSeparator(.hidden)
                    titleRow
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16))
                    if myFoods.isEmpty {
                        Text(emptyStateText)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(myFoods, id: \.id) { cached in
                            Button {
                                portionTarget = cached.toSearchResult(forFavorites: cached.isFavorite)
                            } label: {
                                CachedFoodRow(cached: cached) {
                                    CachedFood.toggleFavorite(cached, in: modelContext)
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    // Removing from the unified list also clears the favorite —
                                    // there's no longer a separate Favorites list to live in.
                                    cached.isInMyFoods = false
                                    cached.isFavorite = false
                                    try? modelContext.save()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    editingFood = cached
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showAddOptions = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add food")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
                .alert("Add Food", isPresented: $showAddOptions) {
                    Button("Scan Barcode") { showScanner = true }
                    Button("Photo") { showPhotoAnalyzer = true }
                    Button("Describe with AI") { showDescribe = true }
                    Button("Recipe Analyzer") { showRecipeBuilder = true }
                    Button("Manual Entry") {
                        quickAddBarcode = nil
                        showQuickAdd = true
                    }
                    Button("Cancel", role: .cancel) { }
                }
                .sheet(item: $portionTarget) { target in
                    FoodPortionSheet(
                        result: target,
                        mealType: MealType.quickAddDefaultForCurrentTime(),
                        date: Calendar.current.startOfDay(for: .now),
                        pickMealAndDate: true
                    ) { }
                }
                .sheet(item: $newFoodTarget) { target in
                    FoodPortionSheet(
                        result: target,
                        mealType: MealType.quickAddDefaultForCurrentTime(),
                        date: Calendar.current.startOfDay(for: .now),
                        addToMyFoods: true
                    ) { }
                }
                .sheet(item: $editingFood) { food in
                    EditCachedFoodSheet(food: food)
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView()
                }
                .sheet(isPresented: $showScanner) {
                    BarcodeScannerView { code in
                        showScanner = false
                        Task { await handleScan(code: code) }
                    }
                }
                .sheet(isPresented: $showPhotoAnalyzer) {
                    FoodPhotoSheet(
                        mealType: MealType.quickAddDefaultForCurrentTime(),
                        date: Calendar.current.startOfDay(for: .now),
                        addToMyFoods: true
                    ) { }
                }
                .sheet(isPresented: $showDescribe) {
                    FoodDescribeSheet { result in
                        // Route to the create-target sheet so the save flags `addToMyFoods`.
                        newFoodTarget = result
                    }
                }
                .sheet(isPresented: $showQuickAdd) {
                    QuickAddSheet(
                        mealType: MealType.quickAddDefaultForCurrentTime(),
                        date: Calendar.current.startOfDay(for: .now),
                        scannedBarcode: quickAddBarcode,
                        addToMyFoods: true
                    ) {
                        showQuickAdd = false
                    }
                }
                .sheet(isPresented: $showRecipeBuilder) {
                    RecipeBuilderSheet { }
                }
                .onReceive(NotificationCenter.default.publisher(for: .scrollToTop)) { _ in
                    withAnimation { proxy.scrollTo("top", anchor: .top) }
                }
                .task {
                    if addLookupViewModel == nil {
                        addLookupViewModel = FoodSearchViewModel(dataSource: dataSourceEnv.dataSource)
                    }
                }
            }
        }
    }

    /// Custom title row replacing the default large-title navbar — gives the favorites-filter
    /// button a home alongside the "My Foods" headline instead of crowding the toolbar. The
    /// button sits 20pt to the right of the title; trailing `Spacer` keeps the pair left-aligned
    /// instead of stretching across the row. `.contentTransition(.identity)` disables the
    /// symbol-morph animation so the star.fill ↔ star swap is a clean cut, not a brief
    /// blue-flash through an intermediate accent-tinted frame.
    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text("My Foods")
                .font(.largeTitle.weight(.bold))
            Button {
                showFavoritesOnly.toggle()
            } label: {
                Image(systemName: showFavoritesOnly ? "star.fill" : "star")
                    .font(.title)
                    .foregroundStyle(showFavoritesOnly ? Color.yellow : Color.accentColor)
                    .contentTransition(.identity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showFavoritesOnly ? "Show all foods" : "Show only favorites")
            Spacer()
        }
    }

    private var myFoods: [CachedFood] {
        cachedFoods
            .filter { $0.isInMyFoods && (!showFavoritesOnly || $0.isFavorite) }
            .sorted(by: CachedFood.myFoodsSort)
    }

    private var emptyStateText: String {
        if showFavoritesOnly {
            return "No favorites yet. Tap the star on a food to favorite it."
        }
        return "No saved foods yet. Tap + to add one, or use the Save to My Foods button on a food you find via search."
    }

    private func handleScan(code: String) async {
        guard let vm = addLookupViewModel else { return }
        if let match = await vm.lookup(barcode: code) {
            newFoodTarget = match
        } else {
            // Not in any DB — open Quick Add manual entry pre-filled with the barcode.
            quickAddBarcode = code
            showQuickAdd = true
        }
    }
}
