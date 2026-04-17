import Foundation

@Observable
@MainActor
final class SettingsViewModel {

    private let healthKitService: HealthKitService
    var healthKitStatus: HealthKitAuthorizationStatus
    var healthKitError: String?

    init(healthKitService: HealthKitService) {
        self.healthKitService = healthKitService
        self.healthKitStatus = healthKitService.authorizationStatus
    }

    func requestHealthKit() async {
        do {
            try await healthKitService.requestAuthorization()
            healthKitStatus = healthKitService.authorizationStatus
        } catch {
            healthKitError = error.localizedDescription
        }
    }
}
