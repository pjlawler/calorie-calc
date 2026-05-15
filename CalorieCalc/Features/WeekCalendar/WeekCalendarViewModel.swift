import Foundation
import SwiftData

@Observable
@MainActor
final class WeekCalendarViewModel {

    var healthKitBurn: [Date: Double] = [:]
    var referenceDate: Date = .now
    var isRefreshing: Bool = false

    private let healthKitService: HealthKitService
    private let calendar: Calendar

    init(healthKitService: HealthKitService, calendar: Calendar = .current) {
        self.healthKitService = healthKitService
        self.calendar = calendar
    }

    func assembler(for period: GoalPeriod, weekStart: Weekday) -> WeekAssembler {
        WeekAssembler(period: period, weekStart: weekStart, referenceDate: referenceDate, calendar: calendar)
    }

    func calculation(period: GoalPeriod, weekStart: Weekday, dayLogs: [DayLog]) -> WeeklyCalculation {
        let assembler = assembler(for: period, weekStart: weekStart)
        let weekStarts = Set(assembler.weekDates.map { calendar.startOfDay(for: $0) })
        let relevantLogs = dayLogs.filter { weekStarts.contains(calendar.startOfDay(for: $0.date)) }
        return assembler.calculate(dayLogs: relevantLogs, healthKitBurn: healthKitBurn)
    }

    func refreshHealthKit(for period: GoalPeriod, weekStart: Weekday) async {
        isRefreshing = true
        defer { isRefreshing = false }
        let dates = assembler(for: period, weekStart: weekStart).weekDates
        // Merge into the existing dict instead of replacing — re-visiting a previously
        // loaded week then becomes instant (no flicker while HK re-fetches).
        var burns = healthKitBurn
        for date in dates {
            let key = calendar.startOfDay(for: date)
            let value = (try? await healthKitService.workoutsEnergyBurned(on: date, calendar: calendar)) ?? 0
            burns[key] = value
        }
        healthKitBurn = burns
    }

    func shiftWeek(by weeks: Int) {
        if let newDate = calendar.date(byAdding: .weekOfYear, value: weeks, to: referenceDate) {
            referenceDate = newDate
        }
    }

    func jumpToCurrentWeek() {
        referenceDate = .now
    }
}
