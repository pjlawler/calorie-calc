import Foundation

extension Date {
    func weekday(in calendar: Calendar = .current) -> Weekday {
        let component = calendar.component(.weekday, from: self)
        return Weekday(rawValue: component) ?? .monday
    }
}

extension Calendar {
    /// Normalizes a date coming from `DatePicker(.date)` (or `.now`) to the start of the day the
    /// user actually chose, in *this* calendar's timezone.
    ///
    /// `DatePicker(.date)` hands back a `Date` already expressed in the local calendar, so the
    /// correct normalization is simply `startOfDay`. An earlier version read the Y/M/D through a
    /// UTC calendar and rebuilt them locally, which shifted the day back one for UTC+ timezones
    /// (e.g. Bangkok logging entries to the previous day). Keep this local-only.
    func loggingDay(from pickerDate: Date) -> Date {
        startOfDay(for: pickerDate)
    }

    /// The anchor date (midnight) for the start of the week containing `date`,
    /// using the supplied `firstWeekday` (1 = Sunday … 2 = Monday, etc.).
    func startOfWeek(for date: Date, firstWeekday: Int) -> Date {
        var calendar = self
        calendar.firstWeekday = firstWeekday
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components) ?? startOfDay(for: date)
    }

    /// Seven dates (midnight each) spanning the week containing `date`, ordered from `firstWeekday`.
    func daysOfWeek(containing date: Date, firstWeekday: Int) -> [Date] {
        let start = startOfWeek(for: date, firstWeekday: firstWeekday)
        return (0..<7).compactMap { self.date(byAdding: .day, value: $0, to: start) }
    }
}

extension Weekday {
    var calendarValue: Int { rawValue }
}
