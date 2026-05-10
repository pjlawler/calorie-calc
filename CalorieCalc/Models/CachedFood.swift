import Foundation
import SwiftData

@Model
final class CachedFood {
    // Defaults on every non-optional property are required so SwiftData lightweight migration
    // can populate values for rows from an older store schema. Without them, opening an existing
    // store fails with NSCocoaErrorDomain 134110.
    // No `@Attribute(.unique)` — CloudKit doesn't support unique constraints on synced entities.
    // De-duplication in this model is by `externalId` at the lookup sites, so the unique
    // constraint was always belt-and-suspenders.
    var id: UUID = UUID()

    var externalId: String?
    var name: String = ""
    var brand: String?

    /// Food's identity — the immutable picker label for "1 native unit". Mirrors `FoodEntry.nativeUnit`.
    var nativeUnit: String = "ea"
    var nativeUnitGrams: Double?
    var nativeUnitMilliliters: Double?

    /// Sticky picker preset: the unit + quantity the user picked the last time they logged this
    /// food. The portion sheet seeds its UI with these on next open. nil for foods that have
    /// never been logged (e.g. favorited but not consumed).
    var lastSelectedUnit: String?
    var lastSelectedQuantity: Double?

    /// Per-native-unit nutrients (1 bar's worth, 1 gram's worth, …).
    var caloriesPerServing: Double = 0
    var proteinPerServing: Double = 0
    var carbsPerServing: Double = 0
    var fatPerServing: Double = 0

    var saturatedFatPerServing: Double?
    var transFatPerServing: Double?
    var monounsaturatedFatPerServing: Double?
    var polyunsaturatedFatPerServing: Double?
    var cholesterolPerServing: Double?
    var sodiumPerServing: Double?
    var fiberPerServing: Double?
    var sugarsPerServing: Double?
    var addedSugarsPerServing: Double?

    var source: FoodSource = FoodSource.manual
    var isFavorite: Bool = false
    /// When `true`, surface in the "My Foods" tab and protect from recents-trim. A curated
    /// catalog the user maintains explicitly — distinct from the auto-tracked Recents list and
    /// the highlight-style Favorites list.
    var isInMyFoods: Bool = false
    var lastUsed: Date = Date()
    var useCount: Int = 0
    var notes: String?

    /// Locked favorite preset — captured the first time the user favorites this food and never
    /// overwritten by subsequent logs.
    var favoriteSelectedUnit: String?
    var favoriteSelectedQuantity: Double?

    /// User-defined labels (e.g. "Thai Food", "Vegan", "Low Calorie"). Many-to-many — the
    /// same `FoodTag` can be attached to many foods, and a food can carry many tags. The
    /// `inverse` declaration tells SwiftData this is the same relationship as
    /// `FoodTag.foods` — without it, edits from one side wouldn't reflect on the other.
    /// Optional per the same CloudKit-requires-to-many-optional rule that DayLog's
    /// relationships follow; `tagsList` below gives non-optional read access.
    @Relationship(inverse: \FoodTag.foods)
    var tags: [FoodTag]? = []

    /// Non-optional read accessor — use everywhere except direct mutation.
    var tagsList: [FoodTag] { tags ?? [] }

    // MARK: - Legacy fields (kept for one-shot migration)
    //
    // Pre-redesign schema fields. SwiftData's lightweight migration preserves them when they're
    // declared (as optional) in the new schema with the same names; `LegacyDataMigrator` reads
    // them on first launch after upgrade, parses into the new layout, then nothing touches them
    // again. Safe to drop in a future schema cleanup once every user has been migrated.
    var defaultServingDescription: String?
    var defaultServingSizeGrams: Double?
    var defaultServingSizeMilliliters: Double?
    var favoriteServingDescription: String?
    var favoriteServingSizeGrams: Double?
    var favoriteServingSizeMilliliters: Double?
    var favoriteCaloriesPerServing: Double?
    var favoriteProteinPerServing: Double?
    var favoriteCarbsPerServing: Double?
    var favoriteFatPerServing: Double?

    /// Pure alphabetical sort by name, brand as tie-breaker. Favorite state does not affect
    /// position — the unified list reads consistently regardless of how many items are starred,
    /// and a dedicated filter (in the Foods tab toolbar) handles "show only favorites".
    static func myFoodsSort(_ lhs: CachedFood, _ rhs: CachedFood) -> Bool {
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        let lb = lhs.brand ?? ""
        let rb = rhs.brand ?? ""
        return lb.localizedCaseInsensitiveCompare(rb) == .orderedAscending
    }

    /// Single source of truth for the star toggle. Favoriting auto-promotes to My Foods (so the
    /// "favorite a recent" gesture lands the row in the user's saved catalog). The first favorite
    /// captures a sticky preset so the row reopens with the unit + quantity at favorite-time.
    /// Unfavoriting a transient quick-add row (no logs, not in My Foods) cleans it up — that
    /// branch is mostly defensive now that favorite implies My Foods.
    static func toggleFavorite(_ cached: CachedFood, in context: ModelContext) {
        cached.isFavorite.toggle()
        if cached.isFavorite {
            cached.isInMyFoods = true
            if cached.favoriteSelectedUnit == nil,
               let unit = cached.lastSelectedUnit,
               let qty = cached.lastSelectedQuantity {
                cached.favoriteSelectedUnit = unit
                cached.favoriteSelectedQuantity = qty
            }
        } else if !cached.isInMyFoods && cached.useCount == 0 {
            context.delete(cached)
        }
        try? context.save()
    }

    /// Backfill: promote every existing `isFavorite && !isInMyFoods` row into My Foods so the
    /// unified list catches old data. Idempotent — running it on an already-migrated store finds
    /// zero matches and saves nothing.
    static func promoteFavoritesToMyFoods(in context: ModelContext) {
        let descriptor = FetchDescriptor<CachedFood>(
            predicate: #Predicate<CachedFood> { $0.isFavorite == true && $0.isInMyFoods == false }
        )
        guard let foods = try? context.fetch(descriptor), !foods.isEmpty else { return }
        for food in foods { food.isInMyFoods = true }
        try? context.save()
    }

    init(
        id: UUID = UUID(),
        externalId: String? = nil,
        name: String,
        brand: String? = nil,
        nativeUnit: String,
        nativeUnitGrams: Double? = nil,
        nativeUnitMilliliters: Double? = nil,
        lastSelectedUnit: String? = nil,
        lastSelectedQuantity: Double? = nil,
        caloriesPerServing: Double,
        proteinPerServing: Double = 0,
        carbsPerServing: Double = 0,
        fatPerServing: Double = 0,
        saturatedFatPerServing: Double? = nil,
        transFatPerServing: Double? = nil,
        monounsaturatedFatPerServing: Double? = nil,
        polyunsaturatedFatPerServing: Double? = nil,
        cholesterolPerServing: Double? = nil,
        sodiumPerServing: Double? = nil,
        fiberPerServing: Double? = nil,
        sugarsPerServing: Double? = nil,
        addedSugarsPerServing: Double? = nil,
        source: FoodSource,
        isFavorite: Bool = false,
        isInMyFoods: Bool = false,
        lastUsed: Date = .now,
        useCount: Int = 0,
        notes: String? = nil,
        favoriteSelectedUnit: String? = nil,
        favoriteSelectedQuantity: Double? = nil
    ) {
        self.id = id
        self.externalId = externalId
        self.name = name
        self.brand = brand
        self.nativeUnit = nativeUnit
        self.nativeUnitGrams = nativeUnitGrams
        self.nativeUnitMilliliters = nativeUnitMilliliters
        self.lastSelectedUnit = lastSelectedUnit
        self.lastSelectedQuantity = lastSelectedQuantity
        self.caloriesPerServing = caloriesPerServing
        self.proteinPerServing = proteinPerServing
        self.carbsPerServing = carbsPerServing
        self.fatPerServing = fatPerServing
        self.saturatedFatPerServing = saturatedFatPerServing
        self.transFatPerServing = transFatPerServing
        self.monounsaturatedFatPerServing = monounsaturatedFatPerServing
        self.polyunsaturatedFatPerServing = polyunsaturatedFatPerServing
        self.cholesterolPerServing = cholesterolPerServing
        self.sodiumPerServing = sodiumPerServing
        self.fiberPerServing = fiberPerServing
        self.sugarsPerServing = sugarsPerServing
        self.addedSugarsPerServing = addedSugarsPerServing
        self.source = source
        self.isFavorite = isFavorite
        self.isInMyFoods = isInMyFoods
        self.lastUsed = lastUsed
        self.useCount = useCount
        self.notes = notes
        self.favoriteSelectedUnit = favoriteSelectedUnit
        self.favoriteSelectedQuantity = favoriteSelectedQuantity
    }
}
