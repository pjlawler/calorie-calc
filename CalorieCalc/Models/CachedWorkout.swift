import Foundation
import SwiftData

/// Local-only cache of HealthKit workouts. Lives in the cache store (not synced to iCloud) —
/// each device's HK is its own truth, and re-querying HK is the source of recovery if the cache
/// is wiped. The dashboard / history / day-detail views read from this so they render instantly
/// without blocking on HK, and `HealthKitSyncService` keeps it fresh in the background.
@Model
final class CachedWorkout {
    @Attribute(.unique) var healthKitUUID: UUID = UUID()

    var startDate: Date = Date()
    var endDate: Date = Date()
    var activeEnergyBurned: Double = 0
    var displayName: String = "Workout"
    /// HKWorkoutActivityType raw value, kept so we can re-derive `displayName` if the mapping changes.
    var activityTypeRaw: Int = 0
    var duration: Double = 0

    init(
        healthKitUUID: UUID,
        startDate: Date,
        endDate: Date,
        activeEnergyBurned: Double,
        displayName: String,
        activityTypeRaw: Int,
        duration: Double
    ) {
        self.healthKitUUID = healthKitUUID
        self.startDate = startDate
        self.endDate = endDate
        self.activeEnergyBurned = activeEnergyBurned
        self.displayName = displayName
        self.activityTypeRaw = activityTypeRaw
        self.duration = duration
    }
}

/// Per-day step total cached locally. Steps in HK come as many small samples; we collapse them
/// to one row per calendar day because every consumer wants a daily number. Keyed by start-of-day
/// timestamp so re-fetching the same day overwrites cleanly.
@Model
final class CachedDailySteps {
    @Attribute(.unique) var dayStart: Date = Date()
    var stepCount: Double = 0
    var updatedAt: Date = Date()

    init(dayStart: Date, stepCount: Double, updatedAt: Date = .now) {
        self.dayStart = dayStart
        self.stepCount = stepCount
        self.updatedAt = updatedAt
    }
}
