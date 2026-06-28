import Foundation

/// Builds a `PeriodNutritionData` covering the user's CURRENT plan only — from the open
/// `GoalPeriod`'s start date through today — regardless of any Progress-tab timeframe selection.
///
/// The "Ask about my plan" flow asks about the plan in effect now, so anything logged before the
/// current plan started is irrelevant: if the plan changed a month ago but the user has a year of
/// history, only the last month is on-topic. Food/exercise totals are strictly windowed to
/// [planStart, today]; weight samples reach a short way before plan start so there's a baseline
/// weigh-in to measure change against.
@MainActor
enum PlanProgressGatherer {

    /// Days of weight history to include *before* the plan start, purely as a trend baseline.
    private static let weightBaselineLookbackDays = 14

    static func currentPlanData(
        profile: UserProfile,
        goalPeriods: [GoalPeriod],
        dayLogs: [DayLog],
        weightEntries: [WeightEntry],
        healthKit: HealthKitService,
        now: Date = .now
    ) async -> PeriodNutritionData {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

        let currentPeriod = GoalPeriod.current(in: goalPeriods)
        let planStartDate = currentPeriod?.startDate ?? profile.createdAt
        let start = calendar.startOfDay(for: planStartDate)
        let end = today

        // Pull burns over a long horizon (up to a year back) once. The same per-day totals serve
        // both the current-plan window and the long-term context block below — so a brand-new plan
        // still gets a months-long behavior baseline to compare its target against.
        let longStart = calendar.date(byAdding: .day, value: -(longTermWindowDays - 1), to: today) ?? today
        let burnsStart = Swift.min(longStart, start)
        let burns = (try? await healthKit.dailyWorkoutBurn(from: burnsStart, through: now)) ?? [:]
        let totals = HistoryAggregator.dailyTotals(dayLogs: dayLogs, workoutBurnByDay: burns)

        let calories = HistoryAggregator.summary(metric: .calories, start: start, end: end, dailyTotals: totals)
        let protein = HistoryAggregator.summary(metric: .protein, start: start, end: end, dailyTotals: totals)
        let carbs = HistoryAggregator.summary(metric: .carbs, start: start, end: end, dailyTotals: totals)
        let fat = HistoryAggregator.summary(metric: .fat, start: start, end: end, dailyTotals: totals)
        let exercise = HistoryAggregator.summary(metric: .exercise, start: start, end: end, dailyTotals: totals)
        let net = HistoryAggregator.summary(metric: .net, start: start, end: end, dailyTotals: totals)

        let dayCount = max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
        let exerciseDayCount = totals
            .filter { $0.key >= start && $0.key <= end && $0.value.exercise > 0 }
            .count

        let displayUnit = profile.weightUnit
        let weightWindowStart = calendar.date(byAdding: .day, value: -weightBaselineLookbackDays, to: start) ?? start
        let weightSamples = weightEntries
            .filter { $0.timestamp >= weightWindowStart && $0.timestamp <= now }
            .sorted { $0.timestamp < $1.timestamp }
            .map { WeightSample(date: $0.timestamp, weight: $0.weight(in: displayUnit)) }

        let label: String = {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .none
            return "Current plan — since \(fmt.string(from: planStartDate))"
        }()

        let longTermContext = longTermContext(
            totals: totals,
            weightEntries: weightEntries,
            displayUnit: displayUnit,
            longStart: longStart,
            today: today,
            now: now,
            calendar: calendar
        )

        return PeriodNutritionData(
            periodLabel: label,
            dayCount: dayCount,
            totalCalories: calories.total,
            avgCalories: calories.dayAvg,
            totalProtein: protein.total,
            avgProtein: protein.dayAvg,
            totalCarbs: carbs.total,
            avgCarbs: carbs.dayAvg,
            totalFat: fat.total,
            avgFat: fat.dayAvg,
            totalExercise: exercise.total,
            avgExercise: exercise.dayAvg,
            totalNetCalories: net.total,
            avgNetCalories: net.dayAvg,
            dailyCalorieGoal: currentPeriod?.dailyGrossCalorieGoal ?? profile.dailyGrossCalorieGoal,
            dailyNetCalorieGoal: currentPeriod?.dailyNetCalorieGoal ?? profile.dailyNetCalorieGoal,
            dailyExerciseGoal: currentPeriod?.dailyWorkoutCalorieGoal ?? profile.dailyWorkoutCalorieGoal,
            weightSamples: weightSamples,
            weightUnitSuffix: displayUnit.suffix,
            goalWeight: profile.goalWeight,
            exerciseDayCount: exerciseDayCount,
            currentPlanStartDate: planStartDate,
            longTermContext: longTermContext
        )
    }

    /// How far back the long-term context reaches (a 12-month cap to bound the HealthKit query
    /// and prompt size).
    private static let longTermWindowDays = 365

    /// Behavior baseline over the long window. Returns `nil` when there's too little logged
    /// history for it to add anything (≤ a couple weeks), so short-history users aren't given a
    /// redundant block.
    private static func longTermContext(
        totals: [Date: HistoryAggregator.DailyTotals],
        weightEntries: [WeightEntry],
        displayUnit: WeightUnit,
        longStart: Date,
        today: Date,
        now: Date,
        calendar: Calendar
    ) -> PlanHistoryContext? {
        let loggedDays = totals.keys.filter { $0 >= longStart && $0 <= today && (totals[$0]?.calories ?? 0) > 0 }
        guard loggedDays.count > 14 else { return nil }

        let calories = HistoryAggregator.summary(metric: .calories, start: longStart, end: today, dailyTotals: totals)
        let net = HistoryAggregator.summary(metric: .net, start: longStart, end: today, dailyTotals: totals)
        let exercise = HistoryAggregator.summary(metric: .exercise, start: longStart, end: today, dailyTotals: totals)

        let firstLogged = loggedDays.min() ?? longStart
        let spanDays = (calendar.dateComponents([.day], from: firstLogged, to: today).day ?? 0) + 1

        let weightSamples = weightEntries
            .filter { $0.timestamp >= longStart && $0.timestamp <= now }
            .sorted { $0.timestamp < $1.timestamp }
            .map { WeightSample(date: $0.timestamp, weight: $0.weight(in: displayUnit)) }

        return PlanHistoryContext(
            loggedDayCount: loggedDays.count,
            spanDays: spanDays,
            avgCalories: calories.dayAvg,
            avgNetCalories: net.dayAvg,
            avgExercise: exercise.dayAvg,
            weightSamples: weightSamples
        )
    }
}
