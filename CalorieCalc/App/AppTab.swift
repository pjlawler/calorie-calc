import Foundation

nonisolated enum AppTab: String, CaseIterable, Hashable, Identifiable, Sendable {
    case week
    case history
    case progress
    case dashboard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dashboard: "My Plan"
        case .week: "Week"
        case .history: "History"
        case .progress: "Progress"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "target"
        case .week: "calendar"
        case .history: "chart.xyaxis.line"
        case .progress: "chart.line.uptrend.xyaxis"
        }
    }

    static let defaultTabStorageKey = "app.defaultTab"
}
