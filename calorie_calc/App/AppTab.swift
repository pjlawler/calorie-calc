import Foundation

nonisolated enum AppTab: String, CaseIterable, Hashable, Identifiable, Sendable {
    case dashboard
    case week

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dashboard: "Dashboard"
        case .week: "Week"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "square.grid.2x2.fill"
        case .week: "calendar"
        }
    }

    static let defaultTabStorageKey = "app.defaultTab"
}
