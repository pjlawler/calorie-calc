import Foundation

/// Composes `UserProfile`, local `DayLog`s, and HealthKit data into a `WeeklyCalculation`.
@MainActor
struct WeekAssembler {

    let profile: UserProfile
    let referenceDate: Date
    let calendar: Calendar

    init(profile: UserProfile, referenceDate: Date = .now, calendar: Calendar = .current) {
        self.profile = profile
        self.referenceDate = referenceDate
        self.calendar = calendar
    }

    var weekDates: [Date] {
        calendar.daysOfWeek(containing: referenceDate, firstWeekday: profile.weekStart.calendarValue)
    }

    func plan() -> WeeklyPlan {
        WeeklyPlan(
            dailyNetCalorieGoal: profile.dailyNetCalorieGoal,
            dailyGrossCalorieGoal: profile.dailyGrossCalorieGoal,
            dailyWorkoutCalorieGoal: profile.dailyWorkoutCalorieGoal
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
            let isBanking = profile.isBankingDay(weekday)
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
