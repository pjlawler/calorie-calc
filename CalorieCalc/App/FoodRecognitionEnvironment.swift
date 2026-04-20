import Foundation

@Observable
@MainActor
final class FoodRecognitionEnvironment {
    let service: FoodRecognitionService

    init(service: FoodRecognitionService) {
        self.service = service
    }
}
