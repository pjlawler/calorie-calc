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

    /// Set once per process after a successful (or attempted) `requestAuthorization`. iOS
    /// silently no-ops subsequent requests when the user has already granted access, so calling
    /// this on every launch is cheap and keeps the HealthKit session warm — queries can
    /// otherwise return empty data after periods of app inactivity.
    private var didEnsureAuthorization = false

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
        didEnsureAuthorization = true
        #else
        authorizationStatus = .unavailable
        #endif
    }

    /// Fire-and-forget startup call — safe to invoke from `.task` on every app launch. Silently
    /// swallows errors (a failed request still leaves queries working if access was granted
    /// previously; the Settings screen surfaces real errors when the user taps Request access).
    func ensureAuthorizationAtStartup() async {
        guard !didEnsureAuthorization else { return }
        do {
            try await requestAuthorization()
        } catch {
            didEnsureAuthorization = true
        }
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

    /// Workout active-energy, bucketed by start-of-day, for a date range. One HK query
    /// regardless of range length — avoids per-day round-trips when rendering monthly / yearly charts.
    func dailyWorkoutBurn(
        from startDate: Date,
        through endDate: Date,
        calendar: Calendar = .current
    ) async throws -> [Date: Double] {
        #if canImport(HealthKit) && os(iOS)
        guard isAvailable else { return [:] }
        let rangeStart = calendar.startOfDay(for: startDate)
        guard let rangeEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) else { return [:] }
        let predicate = HKQuery.predicateForSamples(withStart: rangeStart, end: rangeEnd, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        let workouts = try await descriptor.result(for: store)
        var buckets: [Date: Double] = [:]
        for workout in workouts {
            let day = calendar.startOfDay(for: workout.startDate)
            let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?
                .doubleValue(for: .kilocalorie()) ?? 0
            buckets[day, default: 0] += energy
        }
        return buckets
        #else
        return [:]
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
