import Foundation

@Observable
@MainActor
final class NutritionAnalysisEnvironment {
    let service: NutritionAnalysisService

    init(service: NutritionAnalysisService) {
        self.service = service
    }
}
