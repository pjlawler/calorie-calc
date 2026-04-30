import Foundation

/// Timeframe selector for the weight-trend chart on the My Plan screen. Kept as a top-level
/// enum so its `@AppStorage` keys (which use the raw value) survive across rebuilds — moving it
/// to a different namespace would invalidate any saved preference.
nonisolated enum ProgressTrendTimeframe: String, CaseIterable, Identifiable, Hashable {
    case month
    case days90
    case days180
    case year
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .month: "Month"
        case .days90: "90 Days"
        case .days180: "180 Days"
        case .year: "Year"
        case .custom: "Custom"
        }
    }

    /// `nil` for `.custom`, where the range comes from explicit start/end pickers.
    var daysBack: Int? {
        switch self {
        case .month: 30
        case .days90: 90
        case .days180: 180
        case .year: 365
        case .custom: nil
        }
    }
}
