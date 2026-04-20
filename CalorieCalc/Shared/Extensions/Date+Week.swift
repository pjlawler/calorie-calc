import Foundation

extension Date {
    func weekday(in calendar: Calendar = .current) -> Weekday {
        let component = calendar.component(.weekday, from: self)
        return Weekday(rawValue: component) ?? .monday
    }
}

extension Calendar {
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
