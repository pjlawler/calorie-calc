import Foundation

/// Composes a `GoalPeriod` snapshot, local `DayLog`s, and HealthKit data into a
/// `WeeklyCalculation`. The period is resolved per-week so changing goals today doesn't
/// rewrite historical weeks' plan math.
@MainActor
struct WeekAssembler {

    let period: GoalPeriod
    let referenceDate: Date
    let calendar: Calendar

    init(period: GoalPeriod, referenceDate: Date = .now, calendar: Calendar = .current) {
        self.period = period
        self.referenceDate = referenceDate
        self.calendar = calendar
    }

    var weekDates: [Date] {
        calendar.daysOfWeek(containing: referenceDate, firstWeekday: period.weekStart.calendarValue)
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
        let today = calendar.startOfDay(for: referenceDate)
        let logsByDate = Dictionary(uniqueKeysWithValues: dayLogs.map { (calendar.startOfDay(for: $0.date), $0) })

        return weekDates.map { date in
            let weekday = date.weekday(in: calendar)
            let isBanking = period.isBankingDay(weekday)
            let status: DayStatus = {
                if calendar.isDate(date, inSameDayAs: today) { return .today }
                return date < today ? .past : .future
            }()

            let log = logsByDate[date]
            let actualConsumed = log?.totalConsumedCalories ?? 0
            let hkBurn = healthKitBurn[date] ?? 0
            let manualBurn = log?.totalManualBurned ?? 0
            let actualBurn = hkBurn + manualBurn

            // "Has data" = the user actually logged food or a workout, or HealthKit reports a burn.
            // An empty DayLog (e.g. created by visiting the day detail but not logging) counts as no data.
            let hasAnyData =
                (log?.foodEntries.isEmpty == false)
                || (log?.manualWorkouts.isEmpty == false)
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
}
