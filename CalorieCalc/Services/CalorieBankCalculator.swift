import Foundation

nonisolated struct WeeklyPlan: Sendable, Hashable {
    let dailyNetCalorieGoal: Int
    let dailyGrossCalorieGoal: Int
    let dailyWorkoutCalorieGoal: Int
}

nonisolated enum DayStatus: Sendable, Hashable {
    case past
    case today
    case future
}

nonisolated struct DayInput: Sendable, Hashable {
    let weekday: Weekday
    let isBankingDay: Bool
    let status: DayStatus
    /// What the user actually logged / HealthKit recorded — this is what the day cell displays.
    let consumedCalories: Double
    let burnedCalories: Double
    /// `true` if this day has any real data. `false` means "no food entries, no workouts, no HK burn".
    /// The calculator uses this to decide whether a past day should be treated as at-plan for
    /// aggregate math (so a fresh install mid-week doesn't register phantom zero-consumed days).
    let hasLoggedData: Bool

    init(
        weekday: Weekday,
        isBankingDay: Bool,
        status: DayStatus,
        consumedCalories: Double = 0,
        burnedCalories: Double = 0,
        hasLoggedData: Bool = true
    ) {
        self.weekday = weekday
        self.isBankingDay = isBankingDay
        self.status = status
        self.consumedCalories = consumedCalories
        self.burnedCalories = burnedCalories
        self.hasLoggedData = hasLoggedData
    }
}

nonisolated struct DailyBudget: Sendable, Hashable {
    let weekday: Weekday
    let isBankingDay: Bool
    let status: DayStatus
    let consumed: Double
    let burned: Double
    let net: Double
    /// `nil` for past off-days (no meaningful retrospective budget).
    let grossBudget: Double?
}

nonisolated struct WeeklyCalculation: Sendable, Hashable {
    let weeklyNetTarget: Double
    let weeklyGrossAllowance: Double
    let caloriesAlreadyEaten: Double
    let committedToBankingDays: Double
    let offDayBank: Double
    let totalOffDaysInWeek: Int
    /// Dynamic per-off-day share = offDayBank / totalOffDaysInWeek.
    /// Goes up when user under-eats or over-burns on banking days, down when they over-eat or skip workouts.
    /// `nil` when there are no off-days at all (7/0 split).
    let perOffDayBudget: Double?
    /// Plan-only per-off-day budget (doesn't react to actuals). Kept for reference / future UI.
    let plannedPerOffDayBudget: Double?
    /// Sum of (consumed − burned) across every day with real logged data — past, today, or future.
    /// A workout-only day (0 consumed, 500 burned) contributes -500, which means
    /// `caloriesRemaining = weeklyNetTarget − runningWeeklyNetActual` gets credited
    /// by the full exercise burn. Future days without any logs contribute 0.
    let runningWeeklyNetActual: Double
    /// Count of days (past, today, or future) with real logged food / workouts / HK data.
    let daysWithLoggedData: Int
    /// Daily average of net calories across `daysWithLoggedData`. `nil` when nothing has been logged yet.
    let averageDailyNetActual: Double?
    /// How the user is tracking against their plan across logged past+today days.
    /// Positive = ahead of plan (ate less / burned more than planned). Negative = over plan.
    /// `nil` when no past/today day has logged data yet.
    let planVariance: Double?
    let dailyBudgets: [DailyBudget]
}

nonisolated enum CalorieBankCalculator {

    nonisolated static func calculate(
        plan: WeeklyPlan,
        days: [DayInput]
    ) -> WeeklyCalculation {
        precondition(days.count == 7, "WeeklySnapshot must contain exactly 7 days")

        let weeklyNetTarget = Double(plan.dailyNetCalorieGoal) * 7
        let grossGoal = Double(plan.dailyGrossCalorieGoal)
        let workoutGoal = Double(plan.dailyWorkoutCalorieGoal)

        // Effective values feed the aggregate math only — they never show up in a cell.
        //   • past + has data     → actual
        //   • past + no data      → at plan (treat as if the user hit their plan that day)
        //   • today               → consumed = actual; burn = max(actual, workoutGoal) so mid-day
        //                           allowance isn't depressed just because the workout hasn't happened yet
        //   • future              → projected
        func effectiveConsumed(_ day: DayInput) -> Double {
            switch day.status {
            case .past:
                if day.hasLoggedData { return day.consumedCalories }
                return day.isBankingDay ? grossGoal : 0
            case .today:
                return day.consumedCalories
            case .future:
                return 0
            }
        }

        func effectiveBurn(_ day: DayInput) -> Double {
            switch day.status {
            case .past:
                if day.hasLoggedData { return day.burnedCalories }
                return workoutGoal
            case .today:
                return max(day.burnedCalories, workoutGoal)
            case .future:
                return workoutGoal
            }
        }

        let totalWeekBurn = days.reduce(0.0) { $0 + effectiveBurn($1) }
        let weeklyGrossAllowance = weeklyNetTarget + totalWeekBurn

        let caloriesAlreadyEaten = days.reduce(0.0) { acc, day in
            switch day.status {
            case .past, .today: acc + effectiveConsumed(day)
            case .future: acc
            }
        }

        // Any day with real logged data contributes its (consumed − burned), whether past, today,
        // or a future day the user has pre-logged a workout / food on. Future days without data
        // don't contribute (they'd just add 0 anyway).
        let runningWeeklyNetActual = days.reduce(0.0) { acc, day in
            switch day.status {
            case .past, .today:
                return acc + (day.consumedCalories - day.burnedCalories)
            case .future:
                return day.hasLoggedData
                    ? acc + (day.consumedCalories - day.burnedCalories)
                    : acc
            }
        }

        let futureBankingCommitment = days.reduce(0.0) { acc, day in
            day.status == .future && day.isBankingDay ? acc + grossGoal : acc
        }

        let todayBankingRemaining: Double = {
            guard let today = days.first(where: { $0.status == .today }), today.isBankingDay else {
                return 0
            }
            return max(0, grossGoal - today.consumedCalories)
        }()

        let committedToBankingDays = futureBankingCommitment + todayBankingRemaining

        let offDayBank = weeklyGrossAllowance - caloriesAlreadyEaten - committedToBankingDays

        let bankingDaysInWeek = days.filter(\.isBankingDay).count
        let totalOffDaysInWeek = days.count - bankingDaysInWeek

        let perOffDayBudget: Double? = {
            guard totalOffDaysInWeek > 0 else { return nil }
            return offDayBank / Double(totalOffDaysInWeek)
        }()

        let plannedPerOffDayBudget: Double? = {
            guard totalOffDaysInWeek > 0 else { return nil }
            let atPlanAllowance = weeklyNetTarget + Double(plan.dailyWorkoutCalorieGoal) * Double(days.count)
            let atPlanBanking = Double(bankingDaysInWeek) * grossGoal
            return (atPlanAllowance - atPlanBanking) / Double(totalOffDaysInWeek)
        }()

        // Off-day cell shows the static plan-only share — always the same value for a given
        // week split so users see a stable daily target that doesn't shift with actuals on
        // other days. The dynamic bank still drives `Net calories remaining` above the grid.
        let dailyBudgets = days.map { day -> DailyBudget in
            let net = day.consumedCalories - day.burnedCalories
            let gross: Double? = day.isBankingDay ? grossGoal : plannedPerOffDayBudget
            return DailyBudget(
                weekday: day.weekday,
                isBankingDay: day.isBankingDay,
                status: day.status,
                consumed: day.consumedCalories,
                burned: day.burnedCalories,
                net: net,
                grossBudget: gross
            )
        }

        // Includes any day (past, today, or pre-logged future) with real logged food / workouts / HK data.
        let daysWithLoggedData = days.filter(\.hasLoggedData).count
        let averageDailyNetActual: Double? = daysWithLoggedData > 0
            ? runningWeeklyNetActual / Double(daysWithLoggedData)
            : nil

        // Plan variance: compare actual net to plan net across logged past+today days.
        // A banking day's plan net = grossGoal − workoutGoal.
        // An off day's plan net = plannedPerOffDayBudget − workoutGoal (matches the weekly average).
        let plannedOffNet = (plannedPerOffDayBudget ?? grossGoal) - workoutGoal
        let plannedBankingNet = grossGoal - workoutGoal
        let varianceDays = days.filter { $0.hasLoggedData && $0.status != .future }
        let expectedNet = varianceDays.reduce(0.0) { acc, day in
            acc + (day.isBankingDay ? plannedBankingNet : plannedOffNet)
        }
        let actualNetForVariance = varianceDays.reduce(0.0) { acc, day in
            acc + (day.consumedCalories - day.burnedCalories)
        }
        let planVariance: Double? = varianceDays.isEmpty ? nil : expectedNet - actualNetForVariance

        return WeeklyCalculation(
            weeklyNetTarget: weeklyNetTarget,
            weeklyGrossAllowance: weeklyGrossAllowance,
            caloriesAlreadyEaten: caloriesAlreadyEaten,
            committedToBankingDays: committedToBankingDays,
            offDayBank: offDayBank,
            totalOffDaysInWeek: totalOffDaysInWeek,
            perOffDayBudget: perOffDayBudget,
            plannedPerOffDayBudget: plannedPerOffDayBudget,            runningWeeklyNetActual: runningWeeklyNetActual,
            daysWithLoggedData: daysWithLoggedData,
            averageDailyNetActual: averageDailyNetActual,
            planVariance: planVariance,
            dailyBudgets: dailyBudgets
        )
    }
}
