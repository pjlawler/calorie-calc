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
/// to one row per calendar day because every consumer wants a daily number.
///
/// Keyed by a timezone-stable integer `dayKey` (yyyymmdd) rather than an absolute start-of-day
/// `Date`. A `Date`-based key is an absolute instant — local midnight in whatever timezone the
/// fetch ran in — so the same calendar day produced a *different* key after the device crosses
/// time zones, slipping past the unique constraint and inserting a duplicate row. yyyymmdd is the
/// same integer regardless of timezone, so re-fetching a day overwrites cleanly.
///
/// `dayKey` is deliberately NOT `@Attribute(.unique)`: lightweight migration backfills the new
/// column with its default (0) for every existing row, and a unique constraint would then reject
/// the second 0-keyed row and crash at container open. Uniqueness is instead enforced in
/// `HealthKitService.applyStepChanges` (fetch-by-key then update-or-insert), and the legacy
/// Date-keyed rows are cleared once on first launch under this schema (see `StepsCacheMigrator`).
@Model
final class CachedDailySteps {
    var dayKey: Int = 0
    var stepCount: Double = 0
    var updatedAt: Date = Date()

    init(dayKey: Int, stepCount: Double, updatedAt: Date = .now) {
        self.dayKey = dayKey
        self.stepCount = stepCount
        self.updatedAt = updatedAt
    }

    /// yyyymmdd for the calendar day containing `date`, in `calendar`'s timezone. Monotonic, so
    /// integer `<`/`>` comparisons order days correctly for range queries.
    static func dayKey(for date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    /// Inverse of `dayKey(for:)` — the start-of-day Date for a yyyymmdd key in `calendar`'s
    /// timezone, so Date-keyed consumers line up with the week grid. Returns nil for a 0/invalid key.
    static func date(forDayKey key: Int, calendar: Calendar = .current) -> Date? {
        guard key > 0 else { return nil }
        var components = DateComponents()
        components.year = key / 10000
        components.month = (key / 100) % 100
        components.day = key % 100
        return calendar.date(from: components).map { calendar.startOfDay(for: $0) }
    }
}
