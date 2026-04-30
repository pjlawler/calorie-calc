import Foundation

nonisolated enum AppTab: String, CaseIterable, Hashable, Identifiable, Sendable {
    case week
    case dashboard
    case history
    case info

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dashboard: "My Plan"
        case .week: "Calc"
        case .history: "History"
        case .info: "Info"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "target"
        case .week: "flame"
        case .history: "clock.arrow.circlepath"
        case .info: "info.circle"
        }
    }

    static let defaultTabStorageKey = "app.defaultTab"
}
