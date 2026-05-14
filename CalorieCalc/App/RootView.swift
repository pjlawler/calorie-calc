import SwiftUI
import SwiftData

struct RootView: View {
    @State private var selection: AppTab
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue
    @Environment(HealthKitService.self) private var healthKitService
    @Environment(EntitlementService.self) private var entitlements
    @Environment(SubscriptionService.self) private var subscription
    @Environment(RewardedAdService.self) private var rewardedAd
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

            // Subscriptions/credits bootstrap. `startListeningForTransactions` survives the
            // task's cancellation since it's stored on the service. `loadProduct` is what
            // populates the paywall's price label. `entitlements.refresh()` pulls the
            // authoritative credit/subscription state — without it, the first AI call would
            // be the only signal of "out of credits", which makes the paywall feel reactive.
            // `rewardedAd.bootstrap()` initialises Google Mobile Ads (no-op in the stub build
            // before the SDK is added).
            subscription.startListeningForTransactions()
            await subscription.loadProduct()
            await entitlements.refresh()
            await rewardedAd.bootstrap()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                selection = .week
            }
        }
        .onChange(of: selection) { _, newValue in
            NotificationCenter.default.post(name: .scrollToTop, object: nil)
            if newValue == .week {
                NotificationCenter.default.post(name: .jumpToCurrentWeek, object: nil)
            }
        }
    }
}

extension Notification.Name {
    /// Posted when the active tab changes. Each tab's top-level scroll view listens
    /// and resets to its top anchor so the user always lands at the top of a tab.
    static let scrollToTop = Notification.Name("scrollToTop")
    /// Posted when the user switches to the Calc tab. The week calendar listens and
    /// resets the visible week to the one containing today, so tapping Calc is a
    /// reliable "take me home" gesture regardless of where the user previously left it.
    static let jumpToCurrentWeek = Notification.Name("jumpToCurrentWeek")
}
