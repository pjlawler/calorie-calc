import SwiftUI
import SwiftData

@main
struct calorie_calcApp: App {

    private let modelContainer: ModelContainer
    private let healthKitService: HealthKitService
    private let foodDataSource: FoodDataSourceEnvironment
    private let foodRecognition: FoodRecognitionEnvironment

    init() {
        let schema = Schema([
            UserProfile.self,
            GoalPeriod.self,
            DayLog.self,
            FoodEntry.self,
            ManualWorkout.self,
            WeightEntry.self,
            CachedFood.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }

        healthKitService = HealthKitService()
        let chained = ChainedFoodDataSource(sources: [
            OpenFoodFactsService(),
            USDAFoodDataCentralService(),
        ])
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
