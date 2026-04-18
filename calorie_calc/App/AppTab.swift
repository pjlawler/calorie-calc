import Foundation

nonisolated enum AppTab: String, CaseIterable, Hashable, Identifiable, Sendable {
    case week
    case dashboard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dashboard: "My Plan"
        case .week: "Week"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "target"
        case .week: "calendar"
        }
    }

    static let defaultTabStorageKey = "app.defaultTab"
}
