import Foundation
import SwiftUI

nonisolated enum HistoryMetric: String, CaseIterable, Identifiable, Hashable {
    case calories
    case exercise
    case steps
    case net
    case protein
    case carbs
    case fat

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .calories: "Calories"
        case .net: "Net Calories"
        case .protein: "Protein"
        case .carbs: "Carbs"
        case .fat: "Fat"
        case .exercise: "Exercise"
        case .steps: "Steps"
        }
    }

    var unit: String {
        switch self {
        case .calories, .net, .exercise: "kCal"
        case .protein, .carbs, .fat: "g"
        case .steps: "steps"
        }
    }

    var color: Color {
        switch self {
        case .calories: .accentColor
        case .net: .indigo
        case .protein: .blue
        case .carbs: .orange
        case .fat: .pink
        case .exercise: .green
        case .steps: .teal
        }
    }
}

nonisolated enum HistoryTimeframe: String, CaseIterable, Identifiable, Hashable {
    case day
    case currentWeek
    case lastWeek
    case rolling7
    case month
    case days90
    case days180
    case year
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .day: "Day"
        case .currentWeek: "This Week"
        case .lastWeek: "Last Week"
        case .rolling7: "Last 7 Days"
        case .month: "Month"
        case .days90: "90 Days"
        case .days180: "180 Days"
        case .year: "Year"
        case .custom: "Custom"
        }
    }
}

nonisolated struct HistorySummary: Hashable {
    let total: Double
    let dayAvg: Double
    let weekAvg: Double
    let monthAvg: Double
}

@MainActor
enum HistoryAggregator {

    struct DailyTotals: Hashable {
        let date: Date
        let calories: Double
        let protein: Double
        let carbs: Double
        let fat: Double
        let exercise: Double
        let steps: Double
    }

    /// Collapse DayLogs + HK burn + HK steps into per-day totals keyed by startOfDay.
    static func dailyTotals(
        dayLogs: [DayLog],
        workoutBurnByDay: [Date: Double],
        stepsByDay: [Date: Double] = [:],
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
                exercise: manualBurn + hkBurn,
                steps: stepsByDay[day] ?? 0
            )
        }
        // HK-only days (burn or steps without a food log) should still contribute to totals.
        let extraDays = Set(workoutBurnByDay.keys).union(stepsByDay.keys).subtracting(result.keys)
        for day in extraDays {
            result[day] = DailyTotals(
                date: day,
                calories: 0,
                protein: 0,
                carbs: 0,
                fat: 0,
                exercise: workoutBurnByDay[day] ?? 0,
                steps: stepsByDay[day] ?? 0
            )
        }
        return result
    }

    static func dateRange(
        for timeframe: HistoryTimeframe,
        reference: Date,
        weekStart: Weekday,
        customStart: Date? = nil,
        customEnd: Date? = nil,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let today = calendar.startOfDay(for: reference)
        switch timeframe {
        case .day:
            return (today, today)
        case .currentWeek:
            let week = calendar.daysOfWeek(containing: today, firstWeekday: weekStart.calendarValue)
            return (week.first ?? today, week.last ?? today)
        case .lastWeek:
            let priorReference = calendar.date(byAdding: .day, value: -7, to: today) ?? today
            let week = calendar.daysOfWeek(containing: priorReference, firstWeekday: weekStart.calendarValue)
            return (week.first ?? priorReference, week.last ?? priorReference)
        case .rolling7:
            let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
            return (start, today)
        case .month:
            let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            return (start, today)
        case .days90:
            let start = calendar.date(byAdding: .day, value: -89, to: today) ?? today
            return (start, today)
        case .days180:
            let start = calendar.date(byAdding: .day, value: -179, to: today) ?? today
            return (start, today)
        case .year:
            let currentMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
            let start = calendar.date(byAdding: .month, value: -11, to: currentMonth) ?? currentMonth
            let endOfMonth: Date = {
                guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: currentMonth),
                      let last = calendar.date(byAdding: .day, value: -1, to: nextMonth) else { return today }
                return last
            }()
            return (start, endOfMonth)
        case .custom:
            let s = calendar.startOfDay(for: customStart ?? today)
            let e = calendar.startOfDay(for: customEnd ?? today)
            return s <= e ? (s, e) : (e, s)
        }
    }

    /// Total + per-day / per-week / per-month averages over the inclusive `[start, end]` range
    /// for one metric. Averages divide by *tracked* days only — and tracked is defined per metric:
    ///
    /// - calories / net / protein / carbs / fat → days where food was logged (calories > 0)
    /// - exercise → days where any workout burn > 0
    /// - steps → days where step count > 0
    ///
    /// HK records steps automatically every day, so we can't treat "any DailyTotals entry" as
    /// tracked — that would inflate the divisor for food metrics on days the user didn't log.
    ///
    /// Pass `averageEnd` to clamp the averaging window (e.g. to exclude today's incomplete data);
    /// the total stays full-range.
    static func summary(
        metric: HistoryMetric,
        start: Date,
        end: Date,
        dailyTotals: [Date: DailyTotals],
        averageEnd: Date? = nil,
        calendar: Calendar = .current
    ) -> HistorySummary {
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)

        // Walks the calendar range, summing the metric and counting only tracked days. Returns
        // (sum, trackedDayCount) — caller decides how to divide.
        func walk(through limit: Date) -> (sum: Double, trackedDays: Int) {
            var sum = 0.0
            var tracked = 0
            var cursor = startDay
            while cursor <= limit {
                if let totals = dailyTotals[cursor], isTrackedDay(metric: metric, totals: totals) {
                    sum += value(for: metric, totals: totals)
                    tracked += 1
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            return (sum, tracked)
        }

        let total = walk(through: endDay).sum

        let avgEndDay = averageEnd.map { min(endDay, calendar.startOfDay(for: $0)) } ?? endDay
        guard avgEndDay >= startDay else {
            return HistorySummary(total: total, dayAvg: 0, weekAvg: 0, monthAvg: 0)
        }
        let avg = walk(through: avgEndDay)
        guard avg.trackedDays > 0 else {
            return HistorySummary(total: total, dayAvg: 0, weekAvg: 0, monthAvg: 0)
        }
        let dayAvg = avg.sum / Double(avg.trackedDays)
        // Per-week/per-month: scale the per-day average up. Using tracked days (not calendar
        // span) means a month where 10 of 30 days were logged reports the average of those 10,
        // multiplied by 7 / 30 for week / month projections.
        return HistorySummary(
            total: total,
            dayAvg: dayAvg,
            weekAvg: dayAvg * 7,
            monthAvg: dayAvg * 30
        )
    }

    /// Whether `totals` should count toward this metric's average. See `summary` for the rules.
    private static func isTrackedDay(metric: HistoryMetric, totals: DailyTotals) -> Bool {
        switch metric {
        case .calories, .net, .protein, .carbs, .fat:
            return totals.calories > 0
        case .exercise:
            return totals.exercise > 0
        case .steps:
            return totals.steps > 0
        }
    }

    static func value(for metric: HistoryMetric, totals: DailyTotals?) -> Double {
        guard let totals else { return 0 }
        switch metric {
        case .calories: return totals.calories
        case .net: return totals.calories - totals.exercise
        case .protein: return totals.protein
        case .carbs: return totals.carbs
        case .fat: return totals.fat
        case .exercise: return totals.exercise
        case .steps: return totals.steps
        }
    }
}
