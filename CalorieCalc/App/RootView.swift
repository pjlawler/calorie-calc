import SwiftUI

struct RootView: View {
    @State private var selection: AppTab
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue
    @Environment(HealthKitService.self) private var healthKitService
    @Environment(\.scenePhase) private var scenePhase

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
            Tab(AppTab.history.displayName, systemImage: AppTab.history.systemImage, value: AppTab.history) {
                HistoryView()
            }
            Tab(AppTab.progress.displayName, systemImage: AppTab.progress.systemImage, value: AppTab.progress) {
                ProgressTrendView()
            }
            Tab(AppTab.dashboard.displayName, systemImage: AppTab.dashboard.systemImage, value: AppTab.dashboard) {
                DashboardView()
            }
        }
        .task(id: appearanceRaw) {
            AppAppearance.apply(appearance)
        }
        .task {
            await healthKitService.ensureAuthorizationAtStartup()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                selection = .week
            }
        }
    }
}
