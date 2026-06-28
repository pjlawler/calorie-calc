import Foundation
import SwiftData

/// Commits a `GoalDraft` to the plan model: mirrors it onto `UserProfile` and rolls the
/// `GoalPeriod` history forward so past weeks keep the goals that were active when they
/// happened. Extracted from `SettingsView` so the AI Plan Analyzer's Apply button and the
/// Settings Done button share one code path.
///
/// Self-contained: it bootstraps a current period if none exists and fetches the latest
/// periods directly (the caller's `@Query` may not have refreshed within the same render
/// cycle). The caller is still responsible for `modelContext.save()` afterward.
@MainActor
enum PlanCommitter {

    /// If any of the five period-scoped fields differ from the current period, close it and open
    /// a new one starting at the first day of the current week (per the draft's `weekStart`);
    /// otherwise overwrite in place. Always mirrors the result onto `profile`.
    static func commit(draft: GoalDraft, profile: UserProfile, in modelContext: ModelContext) {
        let existing = (try? modelContext.fetch(
            FetchDescriptor<GoalPeriod>(sortBy: [SortDescriptor(\.startDate)])
        )) ?? []
        GoalPeriod.ensureBootstrapped(in: modelContext, profile: profile, existing: existing)

        let latestPeriods = (try? modelContext.fetch(
            FetchDescriptor<GoalPeriod>(sortBy: [SortDescriptor(\.startDate)])
        )) ?? existing

        guard let current = GoalPeriod.current(in: latestPeriods) else {
            // Truly no current period — split immediately into a historical (pre-edit, from
            // profile) and a current (post-edit, from draft) so past weeks keep the old values.
            let startOfWeek = Calendar.current.startOfWeek(for: .now, firstWeekday: draft.weekStart.calendarValue)
            if draft.differs(from: GoalDraft(from: profile)) {
                let historical = GoalPeriod(
                    startDate: profile.createdAt,
                    endDate: startOfWeek,
                    dailyNetCalorieGoal: profile.dailyNetCalorieGoal,
                    dailyGrossCalorieGoal: profile.dailyGrossCalorieGoal,
                    dailyWorkoutCalorieGoal: profile.dailyWorkoutCalorieGoal,
                    bankSplit: profile.bankSplit,
                    weekStart: profile.weekStart
                )
                modelContext.insert(historical)
            }
            let open = GoalPeriod(
                startDate: draft.differs(from: GoalDraft(from: profile)) ? startOfWeek : profile.createdAt,
                endDate: nil,
                dailyNetCalorieGoal: draft.dailyNetCalorieGoal,
                dailyGrossCalorieGoal: draft.dailyGrossCalorieGoal,
                dailyWorkoutCalorieGoal: draft.dailyWorkoutCalorieGoal,
                bankSplit: draft.bankSplit,
                weekStart: draft.weekStart
            )
            modelContext.insert(open)
            draft.mirror(onto: profile)
            return
        }

        guard draft.differs(from: current) else {
            // No goal changes — just mirror back in case pass-through was stale.
            draft.mirror(onto: profile)
            return
        }

        let startOfWeek = Calendar.current.startOfWeek(for: .now, firstWeekday: draft.weekStart.calendarValue)
        // If the user hasn't moved forward in time from the current period (edge case: changing
        // goals twice in one week), keep the same startDate and overwrite. Otherwise close + open.
        if startOfWeek <= current.startDate {
            current.dailyNetCalorieGoal = draft.dailyNetCalorieGoal
            current.dailyGrossCalorieGoal = draft.dailyGrossCalorieGoal
            current.dailyWorkoutCalorieGoal = draft.dailyWorkoutCalorieGoal
            current.bankSplit = draft.bankSplit
            current.weekStart = draft.weekStart
        } else {
            current.endDate = startOfWeek
            let next = GoalPeriod(
                startDate: startOfWeek,
                endDate: nil,
                dailyNetCalorieGoal: draft.dailyNetCalorieGoal,
                dailyGrossCalorieGoal: draft.dailyGrossCalorieGoal,
                dailyWorkoutCalorieGoal: draft.dailyWorkoutCalorieGoal,
                bankSplit: draft.bankSplit,
                weekStart: draft.weekStart
            )
            modelContext.insert(next)
        }
        draft.mirror(onto: profile)
    }
}
