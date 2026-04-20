import Foundation
import SwiftUI

nonisolated enum HistoryMetric: String, CaseIterable, Identifiable, Hashable {
    case calories
    case protein
    case carbs
    case fat
    case exercise

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .calories: "Calories"
        case .protein: "Protein"
        case .carbs: "Carbs"
        case .fat: "Fat"
        case .exercise: "Exercise"
        }
    }

    var unit: String {
        switch self {
        case .calories, .exercise: "kCal"
        case .protein, .carbs, .fat: "g"
        }
    }

    var color: Color {
        switch self {
        case .calories: .accentColor
        case .protein: .blue
        case .carbs: .orange
        case .fat: .pink
        case .exercise: .green
        }
    }
}

nonisolated enum HistoryTimeframe: String, CaseIterable, Identifiable, Hashable {
    case day
    case currentWeek
    case rolling7
    case month
    case year

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .day: "Day"
        case .currentWeek: "This Week"
        case .rolling7: "7 Days"
        case .month: "Month"
        case .year: "Year"
        }
    }
}

nonisolated struct HistoryBucket: Identifiable, Hashable {
    let id: String
    let label: String
    /// Representative date for the bucket (used for axis sorting). For `.year` this is the first of the month.
    let date: Date
    let value: Double
}

nonisolated struct HistoryChartData: Hashable {
    let buckets: [HistoryBucket]
    /// Horizontal rule value to render as a goal line. `nil` when the selected metric has no goal.
    let goal: Double?
    /// Human-facing note describing what the goal line represents. `nil` when no goal.
    let goalLabel: String?
    let total: Double
    let average: Double
    let metric: HistoryMetric
    let timeframe: HistoryTimeframe
}

@MainActor
enum HistoryAggregator {

    struct Goals: Hashable {
        let dailyCalorieGoal: Double?
        let dailyWorkoutGoal: Double?
    }

    struct DailyTotals: Hashable {
        let date: Date
        let calories: Double
        let protein: Double
        let carbs: Double
        let fat: Double
        let exercise: Double
    }

    /// Collapse DayLogs + HK burn into per-day totals keyed by startOfDay.
    static func dailyTotals(
        dayLogs: [DayLog],
        workoutBurnByDay: [Date: Double],
        calendar: Calendar = .current
    ) -> [Date: DailyTotals] {
        var result: [Date: DailyTotals] = [:]
        for log in dayLogs {
            let day = calendar.startOfDay(for: log.date)
            let manualBurn = log.totalManualBurned
            let hkBurn = workoutBurnByDay[day] ?? 0
            result[day] = DailyTotals(
                date: day,
                calories: log.totalConsumedCalories,
                protein: log.totalProtein,
                carbs: log.totalCarbs,
                fat: log.totalFat,
                exercise: manualBurn + hkBurn
            )
        }
        // Any HK-only days (burn without food logs) should still contribute to exercise charts.
        for (day, burn) in workoutBurnByDay where result[day] == nil {
            result[day] = DailyTotals(
                date: day,
                calories: 0,
                protein: 0,
                carbs: 0,
                fat: 0,
                exercise: burn
            )
        }
        return result
    }

    static func dateRange(
        for timeframe: HistoryTimeframe,
        reference: Date,
        weekStart: Weekday,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let today = calendar.startOfDay(for: reference)
        switch timeframe {
        case .day:
            return (today, today)
        case .currentWeek:
            let week = calendar.daysOfWeek(containing: today, firstWeekday: weekStart.calendarValue)
            return (week.first ?? today, week.last ?? today)
        case .rolling7:
            let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
            return (start, today)
        case .month:
            let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            return (start, today)
        case .year:
            // 12 calendar months ending with the current month.
            let currentMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
            let start = calendar.date(byAdding: .month, value: -11, to: currentMonth) ?? currentMonth
            let endOfMonth: Date = {
                guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: currentMonth),
                      let last = calendar.date(byAdding: .day, value: -1, to: nextMonth) else { return today }
                return last
            }()
            return (start, endOfMonth)
        }
    }

    static func chartData(
        metric: HistoryMetric,
        timeframe: HistoryTimeframe,
        reference: Date,
        weekStart: Weekday,
        dailyTotals: [Date: DailyTotals],
        dayLogs: [DayLog],
        goals: Goals,
        calendar: Calendar = .current
    ) -> HistoryChartData {
        let buckets: [HistoryBucket] = {
            switch timeframe {
            case .day:
                return dayBuckets(metric: metric, reference: reference, dayLogs: dayLogs, dailyTotals: dailyTotals, calendar: calendar)
            case .currentWeek, .rolling7, .month:
                let range = dateRange(for: timeframe, reference: reference, weekStart: weekStart, calendar: calendar)
                return dailyBuckets(metric: metric, start: range.start, end: range.end, dailyTotals: dailyTotals, compact: timeframe == .month, calendar: calendar)
            case .year:
                let range = dateRange(for: timeframe, reference: reference, weekStart: weekStart, calendar: calendar)
                return monthlyBuckets(metric: metric, start: range.start, end: range.end, dailyTotals: dailyTotals, calendar: calendar)
            }
        }()

        let total = buckets.reduce(0) { $0 + $1.value }
        let nonZeroCount = max(1, buckets.filter { $0.value > 0 }.count)
        let average = buckets.isEmpty ? 0 : total / Double(nonZeroCount)

        let (goal, goalLabel) = goalFor(metric: metric, timeframe: timeframe, goals: goals)

        return HistoryChartData(
            buckets: buckets,
            goal: goal,
            goalLabel: goalLabel,
            total: total,
            average: average,
            metric: metric,
            timeframe: timeframe
        )
    }

    // MARK: - Private bucketers

    private static func dayBuckets(
        metric: HistoryMetric,
        reference: Date,
        dayLogs: [DayLog],
        dailyTotals: [Date: DailyTotals],
        calendar: Calendar
    ) -> [HistoryBucket] {
        let today = calendar.startOfDay(for: reference)
        if metric == .exercise {
            let value = dailyTotals[today]?.exercise ?? 0
            return [HistoryBucket(id: "exercise-today", label: "Today", date: today, value: value)]
        }
        let todayLog = dayLogs.first { calendar.isDate($0.date, inSameDayAs: today) }
        let meals = MealType.allCases.sorted { $0.order < $1.order }
        var buckets: [HistoryBucket] = []
        for meal in meals {
            let entries = todayLog?.foodEntries.filter { $0.mealType == meal } ?? []
            var value = 0.0
            for entry in entries {
                value += mealEntryValue(entry, metric: metric)
            }
            buckets.append(HistoryBucket(
                id: "day-\(meal.rawValue)",
                label: meal.displayName,
                date: today,
                value: value
            ))
        }
        return buckets
    }

    private static func mealEntryValue(_ entry: FoodEntry, metric: HistoryMetric) -> Double {
        switch metric {
        case .calories: entry.totalCalories
        case .protein: entry.totalProtein
        case .carbs: entry.totalCarbs
        case .fat: entry.totalFat
        case .exercise: 0
        }
    }

    private static func dailyBuckets(
        metric: HistoryMetric,
        start: Date,
        end: Date,
        dailyTotals: [Date: DailyTotals],
        compact: Bool,
        calendar: Calendar
    ) -> [HistoryBucket] {
        var result: [HistoryBucket] = []
        var cursor = calendar.startOfDay(for: start)
        let stop = calendar.startOfDay(for: end)
        let dayFormat: Date.FormatStyle = compact
            ? .dateTime.day()
            : .dateTime.weekday(.abbreviated)
        while cursor <= stop {
            let value = value(for: metric, totals: dailyTotals[cursor])
            result.append(HistoryBucket(
                id: "day-\(cursor.timeIntervalSince1970)",
                label: cursor.formatted(dayFormat),
                date: cursor,
                value: value
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    private static func monthlyBuckets(
        metric: HistoryMetric,
        start: Date,
        end: Date,
        dailyTotals: [Date: DailyTotals],
        calendar: Calendar
    ) -> [HistoryBucket] {
        var result: [HistoryBucket] = []
        var cursor = calendar.date(from: calendar.dateComponents([.year, .month], from: start)) ?? start
        let stop = calendar.date(from: calendar.dateComponents([.year, .month], from: end)) ?? end
        while cursor <= stop {
            guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            var monthTotal = 0.0
            var daysContributing = 0
            var day = cursor
            while day < nextMonth {
                if let totals = dailyTotals[day] {
                    let v = value(for: metric, totals: totals)
                    monthTotal += v
                    if v > 0 { daysContributing += 1 }
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            // Average per active day for calories/macros (more meaningful month-over-month);
            // total for exercise (users usually want "how much I burned this month").
            let value: Double
            switch metric {
            case .exercise: value = monthTotal
            case .calories, .protein, .carbs, .fat:
                value = daysContributing > 0 ? monthTotal / Double(daysContributing) : 0
            }
            result.append(HistoryBucket(
                id: "month-\(cursor.timeIntervalSince1970)",
                label: cursor.formatted(.dateTime.month(.abbreviated)),
                date: cursor,
                value: value
            ))
            cursor = nextMonth
        }
        return result
    }

    private static func value(for metric: HistoryMetric, totals: DailyTotals?) -> Double {
        guard let totals else { return 0 }
        switch metric {
        case .calories: return totals.calories
        case .protein: return totals.protein
        case .carbs: return totals.carbs
        case .fat: return totals.fat
        case .exercise: return totals.exercise
        }
    }

    private static func goalFor(
        metric: HistoryMetric,
        timeframe: HistoryTimeframe,
        goals: Goals
    ) -> (Double?, String?) {
        let dailyValue: Double?
        switch metric {
        case .calories: dailyValue = goals.dailyCalorieGoal
        case .exercise: dailyValue = goals.dailyWorkoutGoal
        case .protein, .carbs, .fat: dailyValue = nil
        }
        guard let daily = dailyValue else { return (nil, nil) }
        switch timeframe {
        case .day, .currentWeek, .rolling7, .month:
            return (daily, "Daily goal")
        case .year:
            // Year view shows monthly aggregates; scale the goal to match (avg daily for calories/macros, monthly total for exercise).
            switch metric {
            case .exercise: return (daily * 30, "Monthly goal")
            case .calories, .protein, .carbs, .fat: return (daily, "Daily goal")
            }
        }
    }
}
