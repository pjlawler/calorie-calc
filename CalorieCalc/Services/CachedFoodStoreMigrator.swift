import Foundation
import SwiftData

/// One-shot migration that lifts `CachedFood` rows out of the local-only "Cache" store and into
/// the synced store, so the user's My Foods + Favorites sync to iCloud across devices.
///
/// Why a snapshot-and-replay pattern instead of a SwiftData VersionedSchema migration: SwiftData
/// doesn't natively support moving an entity *between configurations* in the same container.
/// The model belongs to exactly one `ModelConfiguration`, so we can't have CachedFood live in
/// both old + new shapes simultaneously. Instead:
///
///   1. Open the OLD container shape (CachedFood in `cacheSchema`), fetch every row, snapshot
///      the field values into plain structs, delete the rows, save, then let the container go
///      out of scope. Swift's ARC closes the SwiftData / SQLite handles for us.
///   2. Caller opens the NEW container shape (CachedFood in `syncedSchema`).
///   3. Caller passes the snapshots back through `restore(_:into:)` to recreate the rows in the
///      synced store, where they'll sync via CloudKit.
///
/// Idempotent — guarded by a `UserDefaults` flag, so the snapshot+replay only runs once per
/// install. If anything fails (corrupt store, missing schema, etc.) the migration logs and
/// returns empty; the user's catalog is rebuilt fresh rather than blocking app launch.
@MainActor
enum CachedFoodStoreMigrator {

    /// Bumped if a future migration reshapes CachedFood again. v1 was a broken release that set
    /// the flag *before* successfully restoring rows into the synced store; bumping to v2 means
    /// any device that ran v1 will retry — picking up legacy CachedFood rows that returned to the
    /// cache store via a `BackupService` restore. Devices that simply have no legacy data left
    /// will hit the empty-snapshots fast-path and set v2 immediately.
    private static let migrationKey = "CachedFood.movedToSyncedStore.v2"

    /// Snapshot the legacy cache-store rows, then nuke `Cache.store` so the new container starts
    /// fresh (without the file deletion, SwiftData's residual entity-to-config mapping survives
    /// and breaks insert routing on the synced store). Caller restores after opening the new
    /// container shape. Returns `[]` if migration already ran or the legacy store has no rows.
    /// The migration-completed flag is set later, in `restore(_:into:)`, so a crash between
    /// these two calls leaves the flag unset and the next launch retries.
    static func stageLegacyRowsIfNeeded() -> [CachedFoodSnapshot] {
        if UserDefaults.standard.bool(forKey: migrationKey) { return [] }
        return readAndPurgeLegacy()
    }

    /// Re-insert staged snapshots into the synced store. No-op for an empty array. Sets the
    /// migration flag only on a successful save, so a crash here leaves the flag clear and the
    /// next launch retries the migration.
    static func restore(_ snapshots: [CachedFoodSnapshot], into context: ModelContext) {
        guard !snapshots.isEmpty else {
            // Even with no rows to restore, mark the migration done so we don't keep snapshotting
            // an empty cache store on every launch.
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }
        for snapshot in snapshots {
            context.insert(snapshot.makeCachedFood())
        }
        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: migrationKey)
        } catch {
            // Leave flag unset — next launch will retry. Snapshots were already lifted out of
            // the legacy store, so a permanent failure here means the data is lost; the BackupService
            // snapshot taken at app init is the recovery path.
        }
    }

    /// Delete the cache.store SQLite files. Called after snapshotting legacy CachedFood rows so
    /// the new container creates a fresh cache store — without this, SwiftData/CoreData carries
    /// over the stale metadata that maps CachedFood to the cache config, and inserts on the new
    /// container's main context throw "Can't assign an object to a store that does not contain
    /// the object's entity." The data we lose here is just the HK cache (CachedWorkout +
    /// CachedDailySteps), which `HealthKitSyncService` rebuilds from HealthKit on next launch.
    private static func nukeLegacyCacheStore() {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }
        for name in ["Cache.store", "Cache.store-shm", "Cache.store-wal"] {
            let url = dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Open a container in the OLD shape (CachedFood living in `cacheSchema`), read every row,
    /// snapshot it, delete the rows, save, return the snapshots. Best-effort — any failure here
    /// just yields an empty list; the new app continues with no legacy data.
    private static func readAndPurgeLegacy() -> [CachedFoodSnapshot] {
        // Old shapes — these have to match the layout the previous build wrote to disk so SwiftData
        // can open the existing files without a schema mismatch. CachedFood lives in the cache
        // config; the synced config has the seven user-data models only.
        let oldSyncedSchema = Schema([
            UserProfile.self,
            GoalPeriod.self,
            DayLog.self,
            FoodEntry.self,
            ManualWorkout.self,
            SupplementEntry.self,
            WeightEntry.self,
        ])
        let oldCacheSchema = Schema([
            CachedFood.self,
            CachedWorkout.self,
            CachedDailySteps.self,
        ])
        let oldFullSchema = Schema([
            UserProfile.self,
            GoalPeriod.self,
            DayLog.self,
            FoodEntry.self,
            ManualWorkout.self,
            SupplementEntry.self,
            WeightEntry.self,
            CachedFood.self,
            CachedWorkout.self,
            CachedDailySteps.self,
        ])
        // `.none` on both configs even though the synced store was originally `.automatic`: this
        // is a transactional read, and we don't want CloudKit mirroring to kick in (or tear down)
        // for a container we're going to drop within microseconds. Reduces side effects on the
        // synced store's CloudKit state and avoids the teardown churn in the logs.
        let oldSyncedConfig = ModelConfiguration(
            schema: oldSyncedSchema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        let oldCacheConfig = ModelConfiguration(
            "Cache",
            schema: oldCacheSchema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        var snapshots: [CachedFoodSnapshot] = []
        // Open inside a do-block so the container goes out of scope (and SwiftData closes the
        // SQLite handles) BEFORE we delete the underlying files — closing first lets the
        // file removal succeed even when WAL files are mid-write.
        do {
            let container = try ModelContainer(for: oldFullSchema, configurations: oldSyncedConfig, oldCacheConfig)
            let context = ModelContext(container)
            let foods = (try? context.fetch(FetchDescriptor<CachedFood>())) ?? []
            snapshots = foods.map(CachedFoodSnapshot.init(from:))
            // No need to delete from the legacy container — `nukeLegacyCacheStore` below removes
            // the entire cache.store file, which is more reliable than row-level deletes.
        } catch {
            return []
        }

        nukeLegacyCacheStore()
        return snapshots
    }
}

/// Plain-data snapshot of a `CachedFood` row, decoupled from any SwiftData context. Used as the
/// hand-off between the legacy container (where we read) and the new container (where we
/// re-insert) — values can cross containers safely; managed objects can't.
struct CachedFoodSnapshot: Sendable {
    let id: UUID
    let externalId: String?
    let name: String
    let brand: String?
    let nativeUnit: String
    let nativeUnitGrams: Double?
    let nativeUnitMilliliters: Double?
    let lastSelectedUnit: String?
    let lastSelectedQuantity: Double?
    let caloriesPerServing: Double
    let proteinPerServing: Double
    let carbsPerServing: Double
    let fatPerServing: Double
    let saturatedFatPerServing: Double?
    let transFatPerServing: Double?
    let monounsaturatedFatPerServing: Double?
    let polyunsaturatedFatPerServing: Double?
    let cholesterolPerServing: Double?
    let sodiumPerServing: Double?
    let fiberPerServing: Double?
    let sugarsPerServing: Double?
    let addedSugarsPerServing: Double?
    let source: FoodSource
    let isFavorite: Bool
    let isInMyFoods: Bool
    let lastUsed: Date
    let useCount: Int
    let notes: String?
    let favoriteSelectedUnit: String?
    let favoriteSelectedQuantity: Double?

    init(from food: CachedFood) {
        self.id = food.id
        self.externalId = food.externalId
        self.name = food.name
        self.brand = food.brand
        self.nativeUnit = food.nativeUnit
        self.nativeUnitGrams = food.nativeUnitGrams
        self.nativeUnitMilliliters = food.nativeUnitMilliliters
        self.lastSelectedUnit = food.lastSelectedUnit
        self.lastSelectedQuantity = food.lastSelectedQuantity
        self.caloriesPerServing = food.caloriesPerServing
        self.proteinPerServing = food.proteinPerServing
        self.carbsPerServing = food.carbsPerServing
        self.fatPerServing = food.fatPerServing
        self.saturatedFatPerServing = food.saturatedFatPerServing
        self.transFatPerServing = food.transFatPerServing
        self.monounsaturatedFatPerServing = food.monounsaturatedFatPerServing
        self.polyunsaturatedFatPerServing = food.polyunsaturatedFatPerServing
        self.cholesterolPerServing = food.cholesterolPerServing
        self.sodiumPerServing = food.sodiumPerServing
        self.fiberPerServing = food.fiberPerServing
        self.sugarsPerServing = food.sugarsPerServing
        self.addedSugarsPerServing = food.addedSugarsPerServing
        self.source = food.source
        self.isFavorite = food.isFavorite
        self.isInMyFoods = food.isInMyFoods
        self.lastUsed = food.lastUsed
        self.useCount = food.useCount
        self.notes = food.notes
        self.favoriteSelectedUnit = food.favoriteSelectedUnit
        self.favoriteSelectedQuantity = food.favoriteSelectedQuantity
    }

    func makeCachedFood() -> CachedFood {
        CachedFood(
            id: id,
            externalId: externalId,
            name: name,
            brand: brand,
            nativeUnit: nativeUnit,
            nativeUnitGrams: nativeUnitGrams,
            nativeUnitMilliliters: nativeUnitMilliliters,
            lastSelectedUnit: lastSelectedUnit,
            lastSelectedQuantity: lastSelectedQuantity,
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
            source: source,
            isFavorite: isFavorite,
            isInMyFoods: isInMyFoods,
            lastUsed: lastUsed,
            useCount: useCount,
            notes: notes,
            favoriteSelectedUnit: favoriteSelectedUnit,
            favoriteSelectedQuantity: favoriteSelectedQuantity
        )
    }
}
