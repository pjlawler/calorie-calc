import Foundation
import SwiftData

/// Converts every `FoodEntry`/`CachedFood` still parked at `nativeUnit == "ea"` into something
/// meaningful. Two strategies, applied in order:
///
/// 1. **Legacy-field parsing**: if SwiftData lightweight migration preserved the legacy
///    `servingDescription` + `servingSizeGrams` fields, parse them into `nativeUnit` /
///    `nativeUnitGrams` / `selectedUnit` / `quantity` with totals preserved exactly.
/// 2. **Name+brand inference**: when the legacy fields are missing (lost to an earlier
///    migration), fall back to a hard-coded table of common foods — RX Bar → bar (52g),
///    Hershey's → bar (43g), and so on. Totals are not adjusted in this branch (we have nothing
///    to adjust against), so per-serving values stay the same and the new unit is just better
///    metadata in the picker.
///
/// Idempotent and runs on every launch. Rows already promoted to a real unit are skipped.
@MainActor
enum LegacyDataMigrator {

    struct Summary {
        var foodEntriesFromLegacy = 0
        var foodEntriesFromInference = 0
        var foodEntriesUntouched = 0
        var cachedFoodsFromLegacy = 0
        var cachedFoodsFromInference = 0
        var cachedFoodsUntouched = 0
        /// Diagnostic: a few example rows from the current state, so the user can see exactly
        /// what was on disk when migration ran.
        var sampleDiagnostics: [String] = []

        var foodEntriesTotal: Int { foodEntriesFromLegacy + foodEntriesFromInference + foodEntriesUntouched }
        var cachedFoodsTotal: Int { cachedFoodsFromLegacy + cachedFoodsFromInference + cachedFoodsUntouched }
    }

    @discardableResult
    static func runIfNeeded(in context: ModelContext) -> Summary {
        run(in: context)
    }

    @discardableResult
    static func forceRun(in context: ModelContext) -> Summary {
        run(in: context)
    }

    private static func run(in context: ModelContext) -> Summary {
        var summary = Summary()

        if let entries = try? context.fetch(FetchDescriptor<FoodEntry>()) {
            // Diagnostic: capture the state of the first few entries before any rewrites so we
            // can tell *why* the migrator decided what it decided.
            for entry in entries.prefix(3) {
                summary.sampleDiagnostics.append(diagnosticString(for: entry))
            }
            for entry in entries {
                switch migrate(entry) {
                case .fromLegacy: summary.foodEntriesFromLegacy += 1
                case .fromInference: summary.foodEntriesFromInference += 1
                case .skipped: summary.foodEntriesUntouched += 1
                }
            }
        }
        if let foods = try? context.fetch(FetchDescriptor<CachedFood>()) {
            for food in foods {
                switch migrate(food) {
                case .fromLegacy: summary.cachedFoodsFromLegacy += 1
                case .fromInference: summary.cachedFoodsFromInference += 1
                case .skipped: summary.cachedFoodsUntouched += 1
                }
            }
        }
        try? context.save()
        return summary
    }

    private static func diagnosticString(for entry: FoodEntry) -> String {
        let name = entry.name.isEmpty ? "<no name>" : entry.name
        let nu = entry.nativeUnit.isEmpty ? "<empty>" : entry.nativeUnit
        let nug = entry.nativeUnitGrams.map { String(format: "%.1f", $0) } ?? "nil"
        let num = entry.nativeUnitMilliliters.map { String(format: "%.1f", $0) } ?? "nil"
        let su = entry.selectedUnit.isEmpty ? "<empty>" : entry.selectedUnit
        let sd = entry.servingDescription.map { "\"\($0)\"" } ?? "nil"
        let sg = entry.servingSizeGrams.map { String(format: "%.1f", $0) } ?? "nil"
        return "• \(name): nativeUnit=\(nu), nativeUnitGrams=\(nug), nativeUnitMl=\(num), selectedUnit=\(su), legacyDesc=\(sd), legacyGrams=\(sg)"
    }

    private enum Outcome { case fromLegacy, fromInference, skipped }

    private static func migrate(_ entry: FoodEntry) -> Outcome {
        // Skip only if the row already has a real (non-default) native unit. Don't gate on
        // nativeUnitGrams / nativeUnitMilliliters — earlier code paths may have left bogus
        // values there even while nativeUnit stayed at the default, and we still want those
        // rows fixed.
        if !entry.nativeUnit.isEmpty && entry.nativeUnit != "ea" {
            return .skipped
        }

        // Path 1: legacy fields survived lightweight migration.
        if let desc = entry.servingDescription, !desc.isEmpty {
            let plan = MigrationPlan.derive(
                description: desc,
                servingGrams: entry.servingSizeGrams,
                servingMilliliters: entry.servingSizeMilliliters
            )
            apply(plan, to: entry)
            return .fromLegacy
        }

        // Path 2: legacy fields gone — use name-based inference. Totals stay as-is (we don't
        // know what the original per-serving was scaled against), but at least the unit is
        // sensible.
        let inference = LegacyInference.infer(name: entry.name, brand: entry.brand)
        if inference.unit != "ea" || inference.grams != nil {
            entry.nativeUnit = inference.unit
            entry.nativeUnitGrams = inference.grams
            entry.selectedUnit = inference.unit
            return .fromInference
        }
        return .skipped
    }

    private static func migrate(_ food: CachedFood) -> Outcome {
        if !food.nativeUnit.isEmpty && food.nativeUnit != "ea" {
            return .skipped
        }

        if let desc = food.defaultServingDescription, !desc.isEmpty {
            let plan = MigrationPlan.derive(
                description: desc,
                servingGrams: food.defaultServingSizeGrams,
                servingMilliliters: food.defaultServingSizeMilliliters
            )
            apply(plan, to: food)
            // If this was favorited under the old schema, capture the favorite preset too.
            if let favDesc = food.favoriteServingDescription, !favDesc.isEmpty {
                let favPlan = MigrationPlan.derive(
                    description: favDesc,
                    servingGrams: food.favoriteServingSizeGrams,
                    servingMilliliters: food.favoriteServingSizeMilliliters
                )
                food.favoriteSelectedUnit = favPlan.selectedUnit
                food.favoriteSelectedQuantity = favPlan.quantityMultiplier
            }
            return .fromLegacy
        }

        let inference = LegacyInference.infer(name: food.name, brand: food.brand)
        if inference.unit != "ea" || inference.grams != nil {
            food.nativeUnit = inference.unit
            food.nativeUnitGrams = inference.grams
            if food.lastSelectedUnit == nil || food.lastSelectedUnit == "ea" {
                food.lastSelectedUnit = inference.unit
                if food.lastSelectedQuantity == nil { food.lastSelectedQuantity = 1 }
            }
            return .fromInference
        }
        return .skipped
    }

    private static func apply(_ plan: MigrationPlan, to entry: FoodEntry) {
        entry.nativeUnit = plan.nativeUnit
        entry.nativeUnitGrams = plan.nativeUnitGrams
        entry.nativeUnitMilliliters = plan.nativeUnitMilliliters
        entry.selectedUnit = plan.selectedUnit
        entry.quantity = entry.quantity * plan.quantityMultiplier
        let factor = plan.perServingDivisor
        if factor > 0 {
            entry.caloriesPerServing /= factor
            entry.proteinPerServing /= factor
            entry.carbsPerServing /= factor
            entry.fatPerServing /= factor
            entry.saturatedFatPerServing = entry.saturatedFatPerServing.map { $0 / factor }
            entry.transFatPerServing = entry.transFatPerServing.map { $0 / factor }
            entry.monounsaturatedFatPerServing = entry.monounsaturatedFatPerServing.map { $0 / factor }
            entry.polyunsaturatedFatPerServing = entry.polyunsaturatedFatPerServing.map { $0 / factor }
            entry.cholesterolPerServing = entry.cholesterolPerServing.map { $0 / factor }
            entry.sodiumPerServing = entry.sodiumPerServing.map { $0 / factor }
            entry.fiberPerServing = entry.fiberPerServing.map { $0 / factor }
            entry.sugarsPerServing = entry.sugarsPerServing.map { $0 / factor }
            entry.addedSugarsPerServing = entry.addedSugarsPerServing.map { $0 / factor }
        }
    }

    private static func apply(_ plan: MigrationPlan, to food: CachedFood) {
        food.nativeUnit = plan.nativeUnit
        food.nativeUnitGrams = plan.nativeUnitGrams
        food.nativeUnitMilliliters = plan.nativeUnitMilliliters
        food.lastSelectedUnit = plan.selectedUnit
        food.lastSelectedQuantity = plan.quantityMultiplier
        let factor = plan.perServingDivisor
        if factor > 0 {
            food.caloriesPerServing /= factor
            food.proteinPerServing /= factor
            food.carbsPerServing /= factor
            food.fatPerServing /= factor
            food.saturatedFatPerServing = food.saturatedFatPerServing.map { $0 / factor }
            food.transFatPerServing = food.transFatPerServing.map { $0 / factor }
            food.monounsaturatedFatPerServing = food.monounsaturatedFatPerServing.map { $0 / factor }
            food.polyunsaturatedFatPerServing = food.polyunsaturatedFatPerServing.map { $0 / factor }
            food.cholesterolPerServing = food.cholesterolPerServing.map { $0 / factor }
            food.sodiumPerServing = food.sodiumPerServing.map { $0 / factor }
            food.fiberPerServing = food.fiberPerServing.map { $0 / factor }
            food.sugarsPerServing = food.sugarsPerServing.map { $0 / factor }
            food.addedSugarsPerServing = food.addedSugarsPerServing.map { $0 / factor }
        }
    }
}

private struct MigrationPlan {
    let nativeUnit: String
    let nativeUnitGrams: Double?
    let nativeUnitMilliliters: Double?
    let selectedUnit: String
    let quantityMultiplier: Double
    let perServingDivisor: Double

    static func derive(description: String, servingGrams: Double?, servingMilliliters: Double?) -> MigrationPlan {
        let parsed = ServingMath.parseServingDescription(description)
        let count = parsed?.count ?? 1
        let unitText = parsed?.unit ?? ""
        let token = ServingMath.normalizeUnitToken(unitText)

        if token.isEmpty || ServingMath.isMassUnit(token) {
            if let grams = servingGrams, grams > 0 {
                return MigrationPlan(
                    nativeUnit: "g",
                    nativeUnitGrams: 1,
                    nativeUnitMilliliters: nil,
                    selectedUnit: "g",
                    quantityMultiplier: grams,
                    perServingDivisor: grams
                )
            }
        }
        if ServingMath.isVolumeUnit(token), let ml = servingMilliliters, ml > 0 {
            return MigrationPlan(
                nativeUnit: "ml",
                nativeUnitGrams: nil,
                nativeUnitMilliliters: 1,
                selectedUnit: "ml",
                quantityMultiplier: ml,
                perServingDivisor: ml
            )
        }
        if !token.isEmpty && !ServingMath.isMeasurementUnit(token) {
            let perNativeGrams: Double? = servingGrams.flatMap { count > 0 ? $0 / count : nil }
            let perNativeMl: Double? = servingMilliliters.flatMap { count > 0 ? $0 / count : nil }
            return MigrationPlan(
                nativeUnit: token,
                nativeUnitGrams: perNativeGrams,
                nativeUnitMilliliters: perNativeMl,
                selectedUnit: token,
                quantityMultiplier: count,
                perServingDivisor: count
            )
        }
        return MigrationPlan(
            nativeUnit: "ea",
            nativeUnitGrams: servingGrams,
            nativeUnitMilliliters: servingMilliliters,
            selectedUnit: "ea",
            quantityMultiplier: 1,
            perServingDivisor: 1
        )
    }
}

/// Hard-coded fallback for foods whose legacy `servingDescription` is gone. Built from the names
/// in your CSV — covers RX Bar, Hershey's, Cliff, ONE, BUILT, Snickers, Noosa, Oikos, plus the
/// common menu items (Chick-fil-A, Bojangles, Shake Shack, Chipotle, etc.). Anything unrecognized
/// stays "ea".
struct LegacyInference {
    let unit: String
    let grams: Double?

    static func infer(name: String, brand: String?) -> LegacyInference {
        let n = name.lowercased()
        let b = (brand ?? "").lowercased()

        // Brand-anchored — strongest signal, gives accurate gram weight from the published label.
        if b.contains("rxbar") || n.contains("rxbar") || n.contains("rx bar") {
            return LegacyInference(unit: "bar", grams: 52)
        }
        if b.contains("clif") {
            return LegacyInference(unit: "bar", grams: 68)
        }
        if b.contains("built") || n.contains("built bar") {
            return LegacyInference(unit: "bar", grams: 68)
        }
        if (b == "one" || n.starts(with: "one ")) && (n.contains("bar") || n.contains("protein") || n.contains("doughnut") || n.contains("donut")) {
            return LegacyInference(unit: "bar", grams: 60)
        }
        if b.contains("hershey") || n.contains("hershey") {
            return LegacyInference(unit: "bar", grams: 43)
        }
        if n.contains("snickers") {
            return LegacyInference(unit: "bar", grams: 52)
        }
        if b.contains("noosa") || n.contains("noosa") {
            return LegacyInference(unit: "container", grams: 113)
        }
        if b.contains("oikos") || n.contains("oikos") {
            return LegacyInference(unit: "container", grams: 150)
        }
        if b.contains("costco food court") && n.contains("hot dog") {
            return LegacyInference(unit: "hot dog", grams: 240)
        }
        if b.contains("miss vickie") || n.contains("kettle cooked") {
            return LegacyInference(unit: "bag", grams: 43)
        }
        if b.contains("nabisco") && n.contains("cracker") {
            return LegacyInference(unit: "serving", grams: 30)
        }
        if b.contains("crystal farms") && n.contains("cheese") {
            return LegacyInference(unit: "serving", grams: 28)
        }
        if b.contains("la preferida") && n.contains("bean") {
            return LegacyInference(unit: "serving", grams: 130)
        }

        // Restaurant/menu items.
        if n.contains("chick-fil-a") && n.contains("biscuit") {
            return LegacyInference(unit: "biscuit", grams: 200)
        }
        if n.contains("bojangles") && n.contains("biscuit") {
            return LegacyInference(unit: "biscuit", grams: 220)
        }
        if n.contains("shake shack") && n.contains("cheeseburger") {
            return LegacyInference(unit: "burger", grams: 250)
        }
        if n.contains("five guys") && (n.contains("burger") || n.contains("cheeseburger")) {
            return LegacyInference(unit: "burger", grams: 300)
        }
        if n.contains("mcalister") && n.contains("dip") {
            return LegacyInference(unit: "sandwich", grams: 350)
        }
        if n.contains("chipotle") && n.contains("bowl") {
            return LegacyInference(unit: "bowl", grams: 550)
        }
        if n.contains("cracker barrel") && n.contains("pancake") {
            return LegacyInference(unit: "pancake", grams: 80)
        }
        if n.contains("whole foods") && n.contains("tiramisu") {
            return LegacyInference(unit: "serving", grams: 100)
        }

        // Specific bar shapes.
        if n.contains("ice cream bar") {
            return LegacyInference(unit: "bar", grams: 50)
        }
        if n.contains("protein bar") || n.contains("energy bar") || n.contains("granola bar") || n.contains("nutrition bar") {
            return LegacyInference(unit: "bar", grams: 60)
        }
        if n.contains("chocolate bar") || n.contains("candy bar") {
            return LegacyInference(unit: "bar", grams: 43)
        }

        // Generic countables — most specific first.
        if n.contains("smash burger") || n.contains("cheeseburger") || n.contains("hamburger") {
            return LegacyInference(unit: "burger", grams: 200)
        }
        if n.contains("burger") {
            return LegacyInference(unit: "burger", grams: 200)
        }
        if n.contains("hot dog") {
            return LegacyInference(unit: "hot dog", grams: 75)
        }
        if n.contains("taco") {
            return LegacyInference(unit: "taco", grams: 90)
        }
        if n.contains("burrito") {
            return LegacyInference(unit: "burrito", grams: 300)
        }
        if n.contains("wrap") {
            return LegacyInference(unit: "wrap", grams: 250)
        }
        if n.contains("panini") || n.contains("sandwich") || n.contains(" sub ") || n.hasSuffix(" sub") {
            return LegacyInference(unit: "sandwich", grams: 250)
        }
        if n.contains("biscuit") {
            return LegacyInference(unit: "biscuit", grams: 70)
        }
        if n.contains("cookie") {
            return LegacyInference(unit: "cookie", grams: 30)
        }
        if n.contains("doughnut") || n.contains("donut") {
            return LegacyInference(unit: "donut", grams: 64)
        }
        if n.contains("bagel") {
            return LegacyInference(unit: "bagel", grams: 95)
        }
        if n.contains("pancake") {
            return LegacyInference(unit: "pancake", grams: 80)
        }
        if n.contains("waffle") {
            return LegacyInference(unit: "waffle", grams: 75)
        }
        if n.contains("muffin") {
            return LegacyInference(unit: "muffin", grams: 75)
        }
        if n.contains("pizza") {
            return LegacyInference(unit: "slice", grams: 100)
        }
        if n.contains("yogurt") || n.contains("yoghurt") {
            return LegacyInference(unit: "container", grams: 170)
        }
        if n.contains("salad") {
            return LegacyInference(unit: "salad", grams: 200)
        }
        if n.contains("bowl") {
            return LegacyInference(unit: "bowl", grams: 350)
        }
        if n.contains("plate") || n.contains("platter") {
            return LegacyInference(unit: "plate", grams: 400)
        }
        if n.contains("nachos") {
            return LegacyInference(unit: "plate", grams: 400)
        }
        if n.contains("brownie") {
            return LegacyInference(unit: "brownie", grams: 60)
        }
        if n.contains("roll") {
            return LegacyInference(unit: "roll", grams: 80)
        }
        if n.contains(" bar") || n.hasSuffix(" bar") || n == "bar" {
            return LegacyInference(unit: "bar", grams: 60)
        }
        if n.contains("scrambled") && n.contains("egg") {
            return LegacyInference(unit: "serving", grams: 100)
        }
        if n.contains(" egg") || n.hasSuffix(" egg") || n == "egg" {
            return LegacyInference(unit: "egg", grams: 50)
        }
        if n.contains("soup") || n.contains("chili") {
            return LegacyInference(unit: "bowl", grams: 350)
        }
        if n.contains("chip") {
            return LegacyInference(unit: "serving", grams: 28)
        }
        if n.contains("cracker") {
            return LegacyInference(unit: "serving", grams: 30)
        }
        if n.contains("cheese") {
            return LegacyInference(unit: "serving", grams: 28)
        }
        if n.contains("salmon") || n.contains("steak") || n.contains("chicken") || n.contains("brisket") || n.contains("pork") || n.contains("beef") {
            return LegacyInference(unit: "serving", grams: 170)
        }
        if n.contains("banana") {
            return LegacyInference(unit: "banana", grams: 118)
        }

        return LegacyInference(unit: "ea", grams: nil)
    }
}
