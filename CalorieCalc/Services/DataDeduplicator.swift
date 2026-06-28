import Foundation
import SwiftData

/// Collapses duplicate singleton records that CloudKit sync can produce when one iCloud account
/// runs more than one install of the app (e.g. switching between the App Store and TestFlight
/// builds, or a fresh install whose local bootstrap races the first sync down).
///
/// `UserProfile` and the open `GoalPeriod` are meant to be singletons, but SwiftData can't put a
/// `@Attribute(.unique)` on CloudKit-synced models, and the views bootstrap a profile with
/// `if profiles.isEmpty { insert(UserProfile()) }` — so a profile created locally *before* the
/// other build's profile syncs in leaves two rows. Reads then resolve `profiles.first` to one row
/// while Settings writes to another, so plan edits appear not to stick. This pass keeps a single
/// canonical row and deletes/closes the rest. Idempotent: a no-op once there's exactly one of each.
enum DataDeduplicator {

    @MainActor
    static func run(in context: ModelContext) {
        let collapsedProfiles = dedupeProfiles(in: context)
        let collapsedPeriods = dedupeOpenGoalPeriods(in: context)
        if collapsedProfiles || collapsedPeriods {
            try? context.save()
        }
    }

    /// Keep the earliest-`createdAt` profile as the canonical identity — that's the same row every
    /// view's `@Query(sort: \UserProfile.createdAt).first` resolves, so reads and writes line up.
    /// Fold the *most recently edited* duplicate's values onto it first so the user's latest plan
    /// wins, then delete the extras. Returns true if anything changed.
    @MainActor
    @discardableResult
    private static func dedupeProfiles(in context: ModelContext) -> Bool {
        guard let profiles = try? context.fetch(
            FetchDescriptor<UserProfile>(sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)])
        ), profiles.count > 1 else { return false }

        let canonical = profiles[0]
        if let newest = profiles.max(by: { $0.updatedAt < $1.updatedAt }), newest !== canonical {
            canonical.copySettings(from: newest)
        }
        for duplicate in profiles.dropFirst() {
            context.delete(duplicate)
        }
        return true
    }

    /// Exactly one `GoalPeriod` should have `endDate == nil`. If sync produced several, keep the
    /// most-recently-started one open (the user's latest plan) and cap the others' `endDate` at the
    /// keeper's start so they become historical and exactly one period stays current. Returns true
    /// if anything changed.
    @MainActor
    @discardableResult
    private static func dedupeOpenGoalPeriods(in context: ModelContext) -> Bool {
        guard let periods = try? context.fetch(
            FetchDescriptor<GoalPeriod>(sortBy: [SortDescriptor(\.startDate)])
        ) else { return false }

        let open = periods.filter { $0.endDate == nil }
        guard open.count > 1, let keeper = open.max(by: { $0.startDate < $1.startDate }) else {
            return false
        }
        for period in open where period !== keeper {
            period.endDate = keeper.startDate
        }
        return true
    }
}
