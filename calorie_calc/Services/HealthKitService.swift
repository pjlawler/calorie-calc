import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

nonisolated struct HealthKitWorkout: Sendable, Hashable, Identifiable {
    let id: UUID
    let displayName: String
    let startDate: Date
    let endDate: Date
    let activeEnergyBurned: Double
    let duration: TimeInterval
}

nonisolated enum HealthKitAuthorizationStatus: Sendable, Hashable {
    case notDetermined
    case authorized
    case denied
    case unavailable
}

@Observable
@MainActor
final class HealthKitService {

    var authorizationStatus: HealthKitAuthorizationStatus = .notDetermined

    #if canImport(HealthKit) && os(iOS)
    private let store = HKHealthStore()
    #endif

    var isAvailable: Bool {
        #if canImport(HealthKit) && os(iOS)
        return HKHealthStore.isHealthDataAvailable()
        #else
        return false
        #endif
    }

    init() {
        #if canImport(HealthKit) && os(iOS)
        authorizationStatus = isAvailable ? .notDetermined : .unavailable
        #else
        authorizationStatus = .unavailable
        #endif
    }

    func requestAuthorization() async throws {
        #if canImport(HealthKit) && os(iOS)
        guard isAvailable else {
            authorizationStatus = .unavailable
            return
        }
        let readTypes: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKObjectType.workoutType(),
        ]
        try await store.requestAuthorization(toShare: [], read: readTypes)
        authorizationStatus = .authorized
        #else
        authorizationStatus = .unavailable
        #endif
    }

    /// Sum of active energy burned across recorded workouts for the day.
    /// This is *only* workout calories — not the whole Move ring. Matches what you see
    /// under "Workouts" in the Fitness app, not the daily active-energy total.
    func workoutsEnergyBurned(on date: Date, calendar: Calendar = .current) async throws -> Double {
        #if canImport(HealthKit) && os(iOS)
        guard isAvailable else { return 0 }
        let list = try await workouts(on: date, calendar: calendar)
        return list.reduce(0) { $0 + $1.activeEnergyBurned }
        #else
        return 0
        #endif
    }

    func workouts(on date: Date, calendar: Calendar = .current) async throws -> [HealthKitWorkout] {
        #if canImport(HealthKit) && os(iOS)
        guard isAvailable else { return [] }
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        let workouts = try await descriptor.result(for: store)
        return workouts.map { workout in
            HealthKitWorkout(
                id: workout.uuid,
                displayName: workout.workoutActivityType.displayName,
                startDate: workout.startDate,
                endDate: workout.endDate,
                activeEnergyBurned: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
                    .sumQuantity()?
                    .doubleValue(for: .kilocalorie()) ?? 0,
                duration: workout.duration
            )
        }
        #else
        return []
        #endif
    }
}

#if canImport(HealthKit) && os(iOS)
private extension HKWorkoutActivityType {
    var displayName: String {
        switch self {
        case .running: "Running"
        case .walking: "Walking"
        case .cycling: "Cycling"
        case .swimming: "Swimming"
        case .hiking: "Hiking"
        case .yoga: "Yoga"
        case .functionalStrengthTraining, .traditionalStrengthTraining: "Strength"
        case .highIntensityIntervalTraining: "HIIT"
        case .rowing: "Rowing"
        case .elliptical: "Elliptical"
        case .dance: "Dance"
        case .mixedCardio, .crossTraining: "Cross Training"
        default: "Workout"
        }
    }
}
#endif
