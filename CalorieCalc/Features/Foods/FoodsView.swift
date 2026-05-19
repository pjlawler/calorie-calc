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
    @Environment(AIConsentService.self) private var aiConsent
    @Query(sort: \CachedFood.lastUsed, order: .reverse)
    private var cachedFoods: [CachedFood]
    @Query(sort: \FoodTag.name) private var allTags: [FoodTag]
    @State private var selectedTagIds: Set<UUID> = []

    @State private var portionTarget: FoodSearchResult?
    /// Distinct from `portionTarget` so the create-flow can flag the result as
    /// `addToMyFoods: true`. Tapping an existing row uses `portionTarget` (no flag).
    @State private var newFoodTarget: FoodSearchResult?
    @State private var editingFood: CachedFood?
    @State private var showSettings = false

    /// Persisted between launches so the user's filter preference sticks. When `true`, the list
    /// shows only favorites; when `false`, the full My Foods catalog.
    @AppStorage("foodsView.showFavoritesOnly") private var showFavoritesOnly: Bool = false

    @State private var searchText: String = ""

    // Add-to-My-Foods flow state.
    @State private var showAddOptions = false
    @State private var showScanner = false
    @State private var showPhotoAnalyzer = false
    @State private var showDescribe = false
    @State private var showQuickAdd = false
    @State private var showRecipeBuilder = false
    @State private var quickAddBarcode: String?
    @State private var addLookupViewModel: FoodSearchViewModel?

    // First-use consent gate. When the user picks an AI-powered Add option without
    // prior consent, we stash the action and show the disclosure sheet first; on
    // Allow, the pending action fires. See AIConsentSheet + AIConsentService.
    @State private var showAIConsent = false
    @State private var pendingAIAction: (() -> Void)?

    var body: some View {
        NavigationStack {
            List {
                filterBar
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
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
                                CachedFoodRow(cached: cached, showServingSize: true) {
                                    CachedFood.toggleFavorite(cached, in: modelContext)
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
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
                .searchable(text: $searchText, prompt: "Search foods")
                .navigationTitle("My Foods")
                .navigationBarTitleDisplayMode(.large)
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
                    Button("Photo") { requestAI { showPhotoAnalyzer = true } }
                    Button("Describe with AI") { requestAI { showDescribe = true } }
                    Button("Recipe Analyzer") { requestAI { showRecipeBuilder = true } }
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
                .sheet(isPresented: $showAIConsent, onDismiss: { pendingAIAction = nil }) {
                    AIConsentSheet(onAllow: {
                        let action = pendingAIAction
                        pendingAIAction = nil
                        action?()
                    })
                }
            .task {
                if addLookupViewModel == nil {
                    addLookupViewModel = FoodSearchViewModel(dataSource: dataSourceEnv.dataSource)
                }
            }
        }
    }

    /// Filter bar — favorite star + every existing tag chip on a horizontal scroll
    /// row directly under the nav bar. The star is the leading element so the whole
    /// "show me a subset of My Foods" UI lives in one place, instead of splitting
    /// favorites into a title-adjacent button and tags into a separate strip.
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
                .accessibilityLabel(showFavoritesOnly ? "Show all foods" : "Show only Quick Add")

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

    private var myFoods: [CachedFood] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cachedFoods
            .filter { $0.isInMyFoods && (!showFavoritesOnly || $0.isFavorite) }
            .filter { matchesTagFilter($0) }
            .filter { query.isEmpty || $0.name.lowercased().contains(query) || ($0.brand?.lowercased().contains(query) ?? false) }
            .sorted(by: CachedFood.myFoodsSort)
    }

    /// AND semantics: a food passes only if it carries every selected tag id.
    /// An empty selection lets every food through.
    private func matchesTagFilter(_ food: CachedFood) -> Bool {
        guard !selectedTagIds.isEmpty else { return true }
        let foodTagIds = Set(food.tagsList.map(\.id))
        return selectedTagIds.isSubset(of: foodTagIds)
    }

    private var emptyStateText: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No foods match \"\(searchText)\"."
        }
        if !selectedTagIds.isEmpty {
            return "No foods match the selected tags. Try removing one."
        }
        if showFavoritesOnly {
            return "Nothing in Quick Add yet. Tap the bolt on a food to add it."
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

    /// Runs `action` only after the user has granted AI consent. Pre-grant, the
    /// disclosure sheet is shown and the action is held until they tap Allow.
    private func requestAI(_ action: @escaping () -> Void) {
        if aiConsent.isGranted {
            action()
        } else {
            pendingAIAction = action
            showAIConsent = true
        }
    }
}
