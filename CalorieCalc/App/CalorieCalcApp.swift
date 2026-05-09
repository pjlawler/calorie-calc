import SwiftUI
import SwiftData

@main
struct CalorieCalcApp: App {

    private let modelContainer: ModelContainer
    private let healthKitService: HealthKitService
    private let foodDataSource: FoodDataSourceEnvironment
    private let foodRecognition: FoodRecognitionEnvironment
    private let nutritionAnalysis: NutritionAnalysisEnvironment
    private let entitlementService: EntitlementService
    private let subscriptionService: SubscriptionService
    private let rewardedAdService: RewardedAdService

    init() {
        // Auto-snapshot the previous session's store files BEFORE opening the container, so
        // if this launch corrupts data we can roll back to the last good state. No-op on first
        // install (no files to copy yet). Best-effort — failures don't block launch.
        BackupService.snapshotIfNeeded(maxKeep: 10)

        // One-shot lift of the user's My Foods / Favorites out of the legacy local-only cache
        // store and into the synced store, so they fan out via CloudKit. Has to run BEFORE the
        // new container opens — once the new container is created with CachedFood declared in
        // `syncedSchema`, the cache store no longer has a schema entry for CachedFood and the
        // data would be unreachable. See `CachedFoodStoreMigrator` for the snapshot+replay logic.
        let stagedFoods = CachedFoodStoreMigrator.stageLegacyRowsIfNeeded()

        // Three-tier layout:
        //   • Synced store (CloudKit-backed): user data — logs, goals, weights, AND the My Foods
        //     catalog so a fresh install on a second device rehydrates the user's saved foods.
        //   • Cache store (local-only): per-device noise — HealthKit workouts/steps mirrored from
        //     the on-device HK store, which is itself a per-device source of truth.
        // CachedFood used to live in the cache store; the migrator above moves it to the synced
        // store on first launch under this build.
        let syncedSchema = Schema([
            UserProfile.self,
            GoalPeriod.self,
            DayLog.self,
            FoodEntry.self,
            ManualWorkout.self,
            SupplementEntry.self,
            WeightEntry.self,
            CachedFood.self,
        ])
        let cacheSchema = Schema([
            CachedWorkout.self,
            CachedDailySteps.self,
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
            CachedWorkout.self,
            CachedDailySteps.self,
        ])
        // `cloudKitDatabase: .automatic` opts the synced store into CloudKit. Requires the iCloud
        // capability + a CloudKit container in the project's Signing & Capabilities (entitlements
        // are already wired). On a device without an iCloud account, SwiftData silently falls
        // back to a local store — no crash.
        let syncedConfig = ModelConfiguration(
            schema: syncedSchema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )
        // Explicit `.none` opt-out: with the iCloud entitlement active, ModelConfiguration
        // otherwise tries to sync this store too — and CloudKit rejects the `@Attribute(.unique)`
        // constraints on `CachedWorkout.healthKitUUID` and `CachedDailySteps.dayStart`. The HK
        // cache is intentionally per-device anyway, so opting out is correct, not a workaround.
        let cacheConfig = ModelConfiguration(
            "Cache",
            schema: cacheSchema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        do {
            modelContainer = try ModelContainer(for: fullSchema, configurations: syncedConfig, cacheConfig)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }

        // Replay any rows the migrator pulled out of the legacy cache store into the new synced
        // store. No-op once the install has run this branch (UserDefaults flag).
        CachedFoodStoreMigrator.restore(stagedFoods, into: modelContainer.mainContext)

        healthKitService = HealthKitService(modelContainer: modelContainer)
        let openFoodFacts = OpenFoodFactsService()
        let usda = USDAFoodDataCentralService()
        let chained = ChainedFoodDataSource(
            searchSources: [usda, openFoodFacts],
            barcodeSources: [openFoodFacts, usda]
        )
        foodDataSource = FoodDataSourceEnvironment(dataSource: chained)
        let proxyURLString = (Bundle.main.object(forInfoDictionaryKey: "PROXY_BASE_URL") as? String) ?? ""
        guard !proxyURLString.isEmpty, let proxyBaseURL = URL(string: proxyURLString) else {
            fatalError("PROXY_BASE_URL must be set in Secrets.xcconfig — see proxy/README.md.")
        }
        let attest = AppAttestService(proxyBaseURL: proxyBaseURL)
        let entitlements = EntitlementService(proxyBaseURL: proxyBaseURL, attest: attest)
        entitlementService = entitlements
        subscriptionService = SubscriptionService(
            proxyBaseURL: proxyBaseURL,
            attest: attest,
            entitlements: entitlements
        )
        // Test rewarded unit when the xcconfig key is unset — lets dev builds run before
        // a real AdMob unit is provisioned. Replace via Secrets.xcconfig for prod.
        let configuredAdUnit = Bundle.main.object(forInfoDictionaryKey: "ADMOB_REWARDED_AD_UNIT_ID") as? String
        let adUnitId = (configuredAdUnit?.isEmpty == false ? configuredAdUnit! : "ca-app-pub-3940256099942544/1712485313")
        rewardedAdService = RewardedAdService(attest: attest, adUnitId: adUnitId)
        foodRecognition = FoodRecognitionEnvironment(
            service: ClaudeFoodRecognitionService(
                proxyBaseURL: proxyBaseURL,
                attest: attest,
                entitlements: entitlements
            )
        )
        nutritionAnalysis = NutritionAnalysisEnvironment(
            service: NutritionAnalysisService(
                proxyBaseURL: proxyBaseURL,
                attest: attest,
                entitlements: entitlements
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(healthKitService)
                .environment(foodDataSource)
                .environment(foodRecognition)
                .environment(nutritionAnalysis)
                .environment(entitlementService)
                .environment(subscriptionService)
                .environment(rewardedAdService)
        }
        .modelContainer(modelContainer)
    }
}
