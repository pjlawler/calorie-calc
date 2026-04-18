import SwiftUI

struct RootView: View {
    @State private var selection: AppTab
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue

    init() {
        let raw = UserDefaults.standard.string(forKey: AppTab.defaultTabStorageKey) ?? AppTab.week.rawValue
        _selection = State(initialValue: AppTab(rawValue: raw) ?? .week)
    }

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab(AppTab.week.displayName, systemImage: AppTab.week.systemImage, value: AppTab.week) {
                WeekCalendarView()
            }
            Tab(AppTab.dashboard.displayName, systemImage: AppTab.dashboard.systemImage, value: AppTab.dashboard) {
                DashboardView()
            }
        }
        .task(id: appearanceRaw) {
            AppAppearance.apply(appearance)
        }
    }
}
