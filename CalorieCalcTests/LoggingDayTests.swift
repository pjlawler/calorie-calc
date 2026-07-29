import Foundation
import Testing
@testable import CalorieCalc

/// Regression coverage for the quick-add day-shift bug: the lightning-bolt "My Staples"
/// quick-add was filing entries on the previous calendar day for users in UTC+ timezones.
///
/// The sheet defaults its date to `Calendar.current.startOfDay(for: .now)` and then normalizes
/// it via `Calendar.loggingDay(from:)`. The bug lived in an earlier normalization that read the
/// Y/M/D through a UTC calendar and rebuilt them locally — for a local midnight that maps to the
/// prior UTC date (e.g. Bangkok 00:00 = 17:00 UTC the day before) that produced the wrong day.
@Suite("Calendar.loggingDay — quick-add day-shift")
struct LoggingDayTests {

    private func calendar(_ tzID: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tzID)!
        return cal
    }

    /// The exact reported scenario: Bangkok (UTC+7), user's local day is 2026-07-29.
    /// The sheet's default selectedDate is local midnight, which is 2026-07-28 17:00 UTC.
    @Test("Bangkok local midnight normalizes to the same local day, not the day before")
    func bangkokLocalMidnightKeepsDay() {
        let bangkok = calendar("Asia/Bangkok")
        let localMidnight = bangkok.date(from: DateComponents(year: 2026, month: 7, day: 29))!

        let logged = bangkok.loggingDay(from: localMidnight)

        let comps = bangkok.dateComponents([.year, .month, .day], from: logged)
        #expect(comps.year == 2026)
        #expect(comps.month == 7)
        #expect(comps.day == 29)
    }

    /// Locks in *why* this is a regression test: the old UTC-round-trip approach really did
    /// shift Bangkok's local midnight back to the 28th. If someone reintroduces it, this
    /// documents the failure mode the fix removed.
    @Test("Old UTC-round-trip normalization would have shifted the day back")
    func oldApproachDemonstratesTheBug() {
        let bangkok = calendar("Asia/Bangkok")
        let localMidnight = bangkok.date(from: DateComponents(year: 2026, month: 7, day: 29))!

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let utcComps = utc.dateComponents([.year, .month, .day], from: localMidnight)
        let oldResult = bangkok.startOfDay(for: bangkok.date(from: utcComps)!)

        #expect(bangkok.component(.day, from: oldResult) == 28) // the bug
        #expect(bangkok.component(.day, from: bangkok.loggingDay(from: localMidnight)) == 29) // the fix
    }

    /// The fix must not regress UTC- timezones, which the old code happened to get right.
    @Test("Honolulu (UTC-10) local midnight keeps its day")
    func honoluluLocalMidnightKeepsDay() {
        let honolulu = calendar("Pacific/Honolulu")
        let localMidnight = honolulu.date(from: DateComponents(year: 2026, month: 7, day: 29))!

        let logged = honolulu.loggingDay(from: localMidnight)

        #expect(honolulu.component(.day, from: logged) == 29)
    }

    /// General property: for any timezone, normalizing local midnight of day D yields day D,
    /// and normalizing any wall-clock time later that same day also yields day D.
    @Test("Local day is preserved across a spread of timezones", arguments: [
        "Pacific/Honolulu",  // UTC-10
        "America/Los_Angeles", // UTC-7/8
        "UTC",                 // UTC+0
        "Europe/London",       // UTC+0/1
        "Asia/Bangkok",        // UTC+7
        "Pacific/Kiritimati",  // UTC+14
    ])
    func localDayPreservedEverywhere(tzID: String) {
        let cal = calendar(tzID)
        let midnight = cal.date(from: DateComponents(year: 2026, month: 7, day: 29))!
        let evening = cal.date(from: DateComponents(year: 2026, month: 7, day: 29, hour: 23, minute: 59))!

        #expect(cal.component(.day, from: cal.loggingDay(from: midnight)) == 29)
        #expect(cal.component(.day, from: cal.loggingDay(from: evening)) == 29)
        // Result is always a start-of-day.
        #expect(cal.loggingDay(from: evening) == cal.startOfDay(for: evening))
    }
}
