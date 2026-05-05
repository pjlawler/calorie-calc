import SwiftUI
import SwiftData

struct RootView: View {
    @State private var selection: AppTab
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue
    @Environment(HealthKitService.self) private var healthKitService
    @Environment(\.modelContext) private var modelContext
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
            Tab(AppTab.dashboard.displayName, systemImage: AppTab.dashboard.systemImage, value: AppTab.dashboard) {
                DashboardView()
            }
            Tab(AppTab.history.displayName, systemImage: AppTab.history.systemImage, value: AppTab.history) {
                HistoryView()
            }
            Tab(AppTab.foods.displayName, systemImage: AppTab.foods.systemImage, value: AppTab.foods) {
                FoodsView()
            }
            Tab(AppTab.info.displayName, systemImage: AppTab.info.systemImage, value: AppTab.info) {
                InfoView()
            }
        }
        .task(id: appearanceRaw) {
            AppAppearance.apply(appearance)
        }
        .task {
            // Convert any pre-redesign rows (servingDescription / servingSizeGrams) into the new
            // nativeUnit / selectedUnit / quantity layout. No-op after first successful run.
            // BackupService snapshotted the previous-session store before this point, so there's
            // a roll-back path in Settings → Backups if anything goes sideways.
            LegacyDataMigrator.runIfNeeded(in: modelContext)
            // Unify Favorites + My Foods: backfills any pre-existing favorite that isn't yet in
            // My Foods. Idempotent — does nothing once the store is fully migrated.
            CachedFood.promoteFavoritesToMyFoods(in: modelContext)
            // Kicks off auth (idempotent), the initial HK backfill into the SwiftData cache,
            // observer queries with background delivery, and the 60s foreground refresh timer.
            // Subsequent calls no-op.
            await healthKitService.startBackgroundSync()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                selection = .week
            }
        }
        .onChange(of: selection) { _, _ in
            NotificationCenter.default.post(name: .scrollToTop, object: nil)
        }
    }
}

extension Notification.Name {
    /// Posted when the active tab changes. Each tab's top-level scroll view listens
    /// and resets to its top anchor so the user always lands at the top of a tab.
    static let scrollToTop = Notification.Name("scrollToTop")
}
