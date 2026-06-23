import Foundation
import SwiftData

/// One-shot cleanup that drops the legacy `CachedDailySteps` rows after the model switched its
/// key from an absolute start-of-day `Date` (`dayStart`) to a timezone-stable `yyyymmdd` Int
/// (`dayKey`). See `CachedDailySteps` for why the key changed.
///
/// Lightweight migration backfills the new `dayKey` column with its default (`0`) for every
/// pre-existing row, leaving them un-matchable junk (no real day is key 0). Rather than try to
/// recompute a `dayKey` for each — which we can't do reliably, since the original timezone the
/// row was fetched in is lost — we delete them all. The step cache is HK-derived, so the regular
/// background sync (`HealthKitService.applyStepChanges`) repopulates it with correct `dayKey`s.
///
/// Idempotent — guarded by a `UserDefaults` flag so it runs exactly once per install.
@MainActor
enum StepsCacheMigrator {

    private static let migrationKey = "CachedDailySteps.migratedToDayKey.v1"

    /// Deletes all `CachedDailySteps` rows once. No-op after the first successful run. Best-effort:
    /// a failure leaves the flag unset so the next launch retries, and a stale 0-keyed row at worst
    /// shows zero steps for one phantom day until the next HK sync overwrites the real days anyway.
    static func clearLegacyRowsIfNeeded(in context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        do {
            try context.delete(model: CachedDailySteps.self)
            try context.save()
            UserDefaults.standard.set(true, forKey: migrationKey)
        } catch {
            print("StepsCacheMigrator: failed to clear legacy rows, will retry next launch: \(error)")
        }
    }
}
