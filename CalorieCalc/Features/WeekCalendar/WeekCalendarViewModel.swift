import Foundation
import SwiftData

@Observable
@MainActor
final class WeekCalendarViewModel {

    var healthKitBurn: [Date: Double] = [:]
    var referenceDate: Date = .now
    var isRefreshing: Bool = false

    private let healthKitService: HealthKitService
    // `var`, not `let`: `Calendar.current` is a snapshot of the device's timezone at capture time,
    // NOT auto-updating. If the device crosses time zones mid-session this must be re-captured or
    // every day/week boundary stays anchored to the launch timezone. See `handleSignificantTimeChange`.
    private var calendar: Calendar

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

    /// Re-anchors the week to the device's *current* calendar after a significant time change
    /// (a timezone change from travel, or a local-midnight rollover). Re-captures the frozen
    /// `calendar` snapshot so day/week math uses the new timezone, and — if the user was viewing
    /// the current week — snaps `referenceDate` to `.now` so "today" follows them across the change.
    ///
    /// Returns `true` only when the timezone actually moved, so the caller can force a HealthKit
    /// refresh (the burn cache is keyed by start-of-day Dates that shift with the timezone). A
    /// same-timezone midnight tick returns `false` to avoid needless churn.
    @discardableResult
    func handleSignificantTimeChange(reanchorToNow: Bool) -> Bool {
        let fresh = Calendar.current
        let timeZoneMoved = fresh.timeZone != calendar.timeZone
        if timeZoneMoved {
            calendar = fresh
            // Burn is keyed by start-of-day in the old timezone; those keys no longer match the
            // new week's dates. Drop them so the view re-fetches against the new day boundaries.
            healthKitBurn = [:]
        }
        if reanchorToNow {
            referenceDate = .now
        }
        return timeZoneMoved
    }
}
