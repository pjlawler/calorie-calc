import Foundation
import SwiftData

@Observable
@MainActor
final class DayDetailViewModel {

    let date: Date
    var healthKitWorkouts: [HealthKitWorkout] = []
    var healthKitActiveEnergy: Double = 0
    var excludedHealthKitWorkoutIDs: Set<UUID> = []

    private let healthKitService: HealthKitService
    private let calendar: Calendar

    init(date: Date, healthKitService: HealthKitService, calendar: Calendar = .current) {
        self.date = calendar.startOfDay(for: date)
        self.healthKitService = healthKitService
        self.calendar = calendar
    }

    func refresh() async {
        healthKitWorkouts = (try? await healthKitService.workouts(on: date, calendar: calendar)) ?? []
        healthKitActiveEnergy = healthKitWorkouts.reduce(0) { $0 + $1.activeEnergyBurned }
    }

    func toggleExclude(_ workoutID: UUID) {
        if excludedHealthKitWorkoutIDs.contains(workoutID) {
            excludedHealthKitWorkoutIDs.remove(workoutID)
        } else {
            excludedHealthKitWorkoutIDs.insert(workoutID)
        }
    }

    var includedHealthKitActiveEnergy: Double {
        let excludedBurn = healthKitWorkouts
            .filter { excludedHealthKitWorkoutIDs.contains($0.id) }
            .reduce(0) { $0 + $1.activeEnergyBurned }
        return max(0, healthKitActiveEnergy - excludedBurn)
    }
}
