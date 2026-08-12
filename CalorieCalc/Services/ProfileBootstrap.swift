import Foundation
import SwiftData

/// The single place a `UserProfile` (and its open `GoalPeriod`) gets created. Every view that can
/// be the app's first entry point — Week, Dashboard, Onboarding — calls this, so a fresh install
/// ends up with exactly one canonical profile no matter which screen wins the race to render.
///
/// `DataDeduplicator` runs first on purpose: CloudKit can sync in a profile from another install
/// on the same iCloud account, and inserting a second one before that collapse lands is precisely
/// how duplicate singletons get created. See the CloudKit singleton-duplication note in
/// `DataDeduplicator`.
@MainActor
enum ProfileBootstrap {

    /// Idempotent. Returns the canonical (earliest-`createdAt`) profile, or `nil` only if the
    /// insert itself failed.
    @discardableResult
    static func ensure(
        in context: ModelContext,
        profiles: [UserProfile],
        goalPeriods: [GoalPeriod]
    ) -> UserProfile? {
        DataDeduplicator.run(in: context)
        if profiles.isEmpty {
            context.insert(UserProfile())
            try? context.save()
        }
        // `profiles` is the caller's @Query snapshot, which won't reflect an insert made in this
        // same render cycle — re-fetch so the period bootstrap below runs on the first launch
        // rather than waiting for the next one. Same reasoning as `PlanCommitter`'s re-fetch.
        let latest = (try? context.fetch(
            FetchDescriptor<UserProfile>(sortBy: [SortDescriptor(\.createdAt)])
        )) ?? profiles
        guard let profile = latest.first else { return nil }
        GoalPeriod.ensureBootstrapped(in: context, profile: profile, existing: goalPeriods)
        return profile
    }
}
