import Foundation

nonisolated enum AppTab: String, CaseIterable, Hashable, Identifiable, Sendable {
    case week
    case dashboard
    case history
    case foods
    case info

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dashboard: "Progress"
        case .week: "Calc"
        case .foods: "Foods"
        case .history: "History"
        case .info: "Info"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "chart.line.uptrend.xyaxis"
        case .week: "flame"
        case .foods: "fork.knife"
        case .history: "clock.arrow.circlepath"
        case .info: "info.circle"
        }
    }

    static let defaultTabStorageKey = "app.defaultTab"
}
