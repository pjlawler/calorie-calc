import Foundation

/// Composes a `GoalPeriod` snapshot, local `DayLog`s, and HealthKit data into a
/// `WeeklyCalculation`. The period is resolved per-week so changing *goals* today doesn't
/// rewrite historical weeks' plan math — but `weekStart` is intentionally *not* per-period:
/// it's passed in by the caller (typically the current user setting), so toggling Sun↔Mon
/// re-anchors every week's visible 7-day window, the header range, and the banking-day
/// layout consistently across the whole history.
@MainActor
struct WeekAssembler {

    let period: GoalPeriod
    let weekStart: Weekday
    let referenceDate: Date
    let calendar: Calendar

    init(period: GoalPeriod, weekStart: Weekday, referenceDate: Date = .now, calendar: Calendar = .current) {
        self.period = period
        self.weekStart = weekStart
        self.referenceDate = referenceDate
        self.calendar = calendar
    }

    var weekDates: [Date] {
        calendar.daysOfWeek(containing: referenceDate, firstWeekday: weekStart.calendarValue)
    }

    func plan() -> WeeklyPlan {
        WeeklyPlan(
            dailyNetCalorieGoal: period.dailyNetCalorieGoal,
            dailyGrossCalorieGoal: period.dailyGrossCalorieGoal,
            dailyWorkoutCalorieGoal: period.dailyWorkoutCalorieGoal
        )
    }

    func buildInputs(
        dayLogs: [DayLog],
        healthKitBurn: [Date: Double]
    ) -> [DayInput] {
        let today = calendar.startOfDay(for: .now)
        let logsByDate = Dictionary(grouping: dayLogs) { log in
            calendar.startOfDay(for: log.date)
        }

        return weekDates.map { date in
            let weekday = date.weekday(in: calendar)
            let isBanking = isBankingDay(weekday)
            let status: DayStatus = {
                if calendar.isDate(date, inSameDayAs: today) { return .today }
                return date < today ? .past : .future
            }()

            let log = DayLog.preferredForDay(logsByDate[date] ?? [], on: date, calendar: calendar)
            let actualConsumed = log?.totalConsumedCalories ?? 0
            let hkBurn = healthKitBurn[date] ?? 0
            let manualBurn = log?.totalManualBurned ?? 0
            let actualBurn = hkBurn + manualBurn

            // "Has data" = the user actually logged food or a workout, or HealthKit reports a burn.
            // An empty DayLog (e.g. created by visiting the day detail but not logging) counts as no data.
            let hasAnyData =
                (log?.foodEntriesList.isEmpty == false)
                || (log?.manualWorkoutsList.isEmpty == false)
                || hkBurn > 0

            return DayInput(
                weekday: weekday,
                isBankingDay: isBanking,
                status: status,
                consumedCalories: actualConsumed,
                burnedCalories: actualBurn,
                hasLoggedData: hasAnyData
            )
        }
    }

    func calculate(dayLogs: [DayLog], healthKitBurn: [Date: Double]) -> WeeklyCalculation {
        let inputs = buildInputs(dayLogs: dayLogs, healthKitBurn: healthKitBurn)
        return CalorieBankCalculator.calculate(plan: plan(), days: inputs)
    }

    /// Banking-day rule re-anchored to the caller-supplied `weekStart` rather than the
    /// period's stored value. Uses the period's `bankSplit` (5/2 vs 6/1) — count of banking
    /// days is still a per-period plan setting, just *which* weekdays they land on follows
    /// the current weekStart.
    private func isBankingDay(_ weekday: Weekday) -> Bool {
        let offset = (weekday.rawValue - weekStart.rawValue + 7) % 7
        return offset < period.bankSplit.bankingDayCount
    }
}
