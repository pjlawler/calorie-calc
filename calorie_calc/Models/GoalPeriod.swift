import Foundation
import SwiftData

/// A frozen snapshot of plan-shaping goals across a time range. Exactly one period has
/// `endDate == nil` at any moment (the "current" period). When the user edits goals, the
/// current period is closed and a new one opens — historical weeks continue to evaluate against
/// whichever period covered their dates, so changing today's target doesn't retroactively
/// rewrite last month's plan variance.
@Model
final class GoalPeriod {
    @Attribute(.unique) var id: UUID

    /// First day this period applies to, inclusive. Usually the first day of the week (per
    /// `weekStart`) the user made the change in, so the change applies to the full current week.
    var startDate: Date

    /// First day of the NEXT period, exclusive. `nil` for the currently-active period.
    var endDate: Date?

    var dailyNetCalorieGoal: Int
    var dailyGrossCalorieGoal: Int
    var dailyWorkoutCalorieGoal: Int

    var bankSplit: BankSplit
    var weekStart: Weekday

    init(
        id: UUID = UUID(),
        startDate: Date,
        endDate: Date? = nil,
        dailyNetCalorieGoal: Int,
        dailyGrossCalorieGoal: Int,
        dailyWorkoutCalorieGoal: Int,
        bankSplit: BankSplit,
        weekStart: Weekday
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.dailyNetCalorieGoal = dailyNetCalorieGoal
        self.dailyGrossCalorieGoal = dailyGrossCalorieGoal
        self.dailyWorkoutCalorieGoal = dailyWorkoutCalorieGoal
        self.bankSplit = bankSplit
        self.weekStart = weekStart
    }

    /// Banking days are the first `bankSplit.bankingDayCount` weekdays starting at `weekStart`.
    /// Mirrors the convenience previously on `UserProfile` so the assembler can ask the period
    /// directly without reaching back to the profile.
    func isBankingDay(_ weekday: Weekday) -> Bool {
        let offset = (weekday.rawValue - weekStart.rawValue + 7) % 7
        return offset < bankSplit.bankingDayCount
    }
}

extension GoalPeriod {
    /// The period covering `date` — the one whose `startDate <= date < (endDate ?? ∞)`. Falls
    /// back to the earliest period if none match (shouldn't happen post-bootstrap, but keeps
    /// the app resilient if a user's DayLog somehow predates the first period).
    static func period(covering date: Date, in periods: [GoalPeriod]) -> GoalPeriod? {
        let match = periods.first { p in
            guard date >= p.startDate else { return false }
            if let end = p.endDate { return date < end }
            return true
        }
        return match ?? periods.min(by: { $0.startDate < $1.startDate })
    }

    /// The currently-open period (`endDate == nil`). `nil` only if none has been bootstrapped.
    static func current(in periods: [GoalPeriod]) -> GoalPeriod? {
        periods.first { $0.endDate == nil }
    }

    /// Ensures a current period exists for the profile's current goals. Idempotent — no-op when
    /// a current period is already present. Call this from every view that can be the app's
    /// first entry point (Week, Dashboard, Settings) so downstream edit flows never have to
    /// synthesize history from the newly-edited draft values.
    @MainActor
    static func ensureBootstrapped(
        in context: ModelContext,
        profile: UserProfile,
        existing periods: [GoalPeriod]
    ) {
        guard current(in: periods) == nil else { return }
        let seed = GoalPeriod(
            startDate: profile.createdAt,
            endDate: nil,
            dailyNetCalorieGoal: profile.dailyNetCalorieGoal,
            dailyGrossCalorieGoal: profile.dailyGrossCalorieGoal,
            dailyWorkoutCalorieGoal: profile.dailyWorkoutCalorieGoal,
            bankSplit: profile.bankSplit,
            weekStart: profile.weekStart
        )
        context.insert(seed)
        try? context.save()
    }
}
