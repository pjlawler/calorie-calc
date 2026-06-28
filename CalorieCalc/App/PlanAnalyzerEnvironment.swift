import Foundation

@Observable
@MainActor
final class PlanAnalyzerEnvironment {
    let service: PlanRecommendationService

    init(service: PlanRecommendationService) {
        self.service = service
    }
}
