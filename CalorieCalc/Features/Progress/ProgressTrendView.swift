import Foundation

/// Timeframe selector for the weight-trend chart on the My Plan screen. Kept as a top-level
/// enum so its `@AppStorage` keys (which use the raw value) survive across rebuilds — moving it
/// to a different namespace would invalidate any saved preference.
nonisolated enum ProgressTrendTimeframe: String, CaseIterable, Identifiable, Hashable {
    case thisWeek
    case days7
    case days14
    case days30
    case days60
    case days90
    case days180
    case year
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .thisWeek: "This Week"
        case .days7: "7 Days"
        case .days14: "14 Days"
        case .days30: "30 Days"
        case .days60: "60 Days"
        case .days90: "90 Days"
        case .days180: "180 Days"
        case .year: "Year"
        case .custom: "Custom"
        }
    }

    /// `nil` for the cases whose range isn't a fixed look-back window: `.custom` (explicit
    /// start/end pickers) and `.thisWeek` (week-start through today — length varies by weekday).
    var daysBack: Int? {
        switch self {
        case .days7: 7
        case .days14: 14
        case .days30: 30
        case .days60: 60
        case .days90: 90
        case .days180: 180
        case .year: 365
        case .thisWeek, .custom: nil
        }
    }

    /// Whether the Progress picker prefixes the selected label with "Last" (e.g. "Last 30 Days").
    /// Suppressed for `.custom` (shows the date range) and `.thisWeek` ("Last This Week" is wrong).
    var prependsLast: Bool {
        self != .custom && self != .thisWeek
    }
}
