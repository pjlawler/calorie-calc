import SwiftUI
import SwiftData

@main
struct CalorieCalcApp: App {

    private let modelContainer: ModelContainer
    private let healthKitService: HealthKitService
    private let foodDataSource: FoodDataSourceEnvironment
    private let foodRecognition: FoodRecognitionEnvironment

    init() {
        // Auto-snapshot the previous session's store files BEFORE opening the container, so
        // if this launch corrupts data we can roll back to the last good state. No-op on first
        // install (no files to copy yet). Best-effort — failures don't block launch.
        BackupService.snapshotIfNeeded(maxKeep: 10)

        // Two-store layout: user data (food, workouts, goals, weight) lives in the default
        // store and will sync via CloudKit once the iCloud capability is enabled. The food
        // cache is per-device noise — it lives in a separate local-only store so iCloud
        // isn't bloated with data that would just be re-fetched anyway.
        let syncedSchema = Schema([
            UserProfile.self,
            GoalPeriod.self,
            DayLog.self,
            FoodEntry.self,
            ManualWorkout.self,
            SupplementEntry.self,
            WeightEntry.self,
        ])
        let cacheSchema = Schema([
            CachedFood.self,
        ])
        let fullSchema = Schema([
            UserProfile.self,
            GoalPeriod.self,
            DayLog.self,
            FoodEntry.self,
            ManualWorkout.self,
            SupplementEntry.self,
            WeightEntry.self,
            CachedFood.self,
        ])
        // Synced config keeps the default store URL so existing on-device data is preserved
        // when this two-store split lands. CloudKit stays off until the capability is wired.
        let syncedConfig = ModelConfiguration(schema: syncedSchema, isStoredInMemoryOnly: false)
        let cacheConfig = ModelConfiguration("Cache", schema: cacheSchema, isStoredInMemoryOnly: false)
        do {
            modelContainer = try ModelContainer(for: fullSchema, configurations: syncedConfig, cacheConfig)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }

        healthKitService = HealthKitService()
        let openFoodFacts = OpenFoodFactsService()
        let usda = USDAFoodDataCentralService()
        let chained = ChainedFoodDataSource(
            searchSources: [usda, openFoodFacts],
            barcodeSources: [openFoodFacts, usda]
        )
        foodDataSource = FoodDataSourceEnvironment(dataSource: chained)
        foodRecognition = FoodRecognitionEnvironment(service: ClaudeFoodRecognitionService())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(healthKitService)
                .environment(foodDataSource)
                .environment(foodRecognition)
        }
        .modelContainer(modelContainer)
    }
}
