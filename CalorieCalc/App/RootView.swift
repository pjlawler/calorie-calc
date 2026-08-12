import SwiftUI
import SwiftData
import StoreKit

struct RootView: View {
    @State private var selection: AppTab
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue
    /// One-time gate for the AI-plan-features "What's New" announcement.
    @AppStorage("whatsNew.aiPlanFeatures.seen") private var whatsNewSeen = false
    @State private var showWhatsNew = false
    /// First-run flow gates. Stored as epoch seconds (0 = unset) since `@AppStorage` can't hold
    /// an optional `Date`.
    @AppStorage("onboarding.completedAt") private var onboardingCompletedAt: Double = 0
    @AppStorage("onboarding.firstLaunchedAt") private var firstLaunchedAt: Double = 0
    @State private var showOnboarding = false
    @Environment(HealthKitService.self) private var healthKitService
    @Environment(EntitlementService.self) private var entitlements
    @Environment(SubscriptionService.self) private var subscription
    @Environment(RewardedAdService.self) private var rewardedAd
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview

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
        .sheet(isPresented: $showWhatsNew, onDismiss: { whatsNewSeen = true }) {
            WhatsNewSheet()
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingFlow {
                onboardingCompletedAt = Date().timeIntervalSince1970
                showOnboarding = false
            }
        }
        // The permission prompts skipped during onboarding fire the moment the flow closes.
        .onChange(of: showOnboarding) { _, isShowing in
            guard !isShowing else { return }
            Task { await startPermissionPrompts() }
        }
        .task {
            // Decide on the first-run flow before anything else so the cover is up on the first
            // frame rather than flashing an empty week calendar behind it.
            evaluateOnboardingGate()
            // Show the AI-plan-features "What's New" once, but only to users with logged history
            // (so a brand-new install doesn't get a "what's new" before they've used the app —
            // they'll see it on a later launch once they've started logging).
            if !whatsNewSeen {
                let hasHistory = ((try? modelContext.fetchCount(FetchDescriptor<FoodEntry>())) ?? 0) > 0
                if hasHistory { showWhatsNew = true }
            }
            // Convert any pre-redesign rows (servingDescription / servingSizeGrams) into the new
            // nativeUnit / selectedUnit / quantity layout. No-op after first successful run.
            // BackupService snapshotted the previous-session store before this point, so there's
            // a roll-back path in Settings → Backups if anything goes sideways.
            LegacyDataMigrator.runIfNeeded(in: modelContext)
            // Unify Favorites + My Foods: backfills any pre-existing favorite that isn't yet in
            // My Foods. Idempotent — does nothing once the store is fully migrated.
            CachedFood.promoteFavoritesToMyFoods(in: modelContext)
            // HealthKit and ATT both raise system permission dialogs, which would stack on top of
            // the first-run cover and ask a user who hasn't yet seen the app to grant access to
            // their health data. Deferred to `startPermissionPrompts()` when onboarding is up.
            if !showOnboarding {
                await startPermissionPrompts()
            }

            // Subscriptions/credits bootstrap. `startListeningForTransactions` survives the
            // task's cancellation since it's stored on the service. `loadProduct` is what
            // populates the paywall's price label. `entitlements.refresh()` pulls the
            // authoritative credit/subscription state — without it, the first AI call would
            // be the only signal of "out of credits", which makes the paywall feel reactive.
            // `rewardedAd.bootstrap()` initialises Google Mobile Ads (no-op in the stub build
            // before the SDK is added).
            subscription.startListeningForTransactions()
            // Resolve the StoreKit environment (Production vs Sandbox) before the first
            // entitlement poll so AI calls carry the `X-StoreKit-Env` header. The proxy
            // uses it to keep the free-AI promo on for App Store users while letting
            // App Review / TestFlight (Sandbox) reach the paywall — see StoreKitEnvironment.
            await StoreKitEnvironment.shared.prime()
            await subscription.loadProduct()
            await entitlements.refresh()
            // Defer the review prompt past bootstrap so it doesn't fight the splash/first-frame
            // work above. The service enforces a 10-launch minimum and a 3-per-year ceiling.
            try? await Task.sleep(for: .seconds(3))
            if !showOnboarding {
                ReviewPromptService.recordLaunchAndMaybePrompt(requestReview: requestReview)
            }
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

    /// The bootstrap work that raises system permission dialogs, held back until the user is
    /// actually looking at the app rather than at a cover on top of it.
    ///
    /// HealthKit: kicks off auth (idempotent), the initial HK backfill into the SwiftData cache,
    /// observer queries with background delivery, and the 60s foreground refresh timer.
    /// ATT: must resolve before the ad SDK can request personalized fills; prompting here (rather
    /// than at first paywall open) guarantees the prompt is reachable for App Store reviewers who
    /// never burn through the initial credits. Both are no-ops on subsequent calls.
    private func startPermissionPrompts() async {
        await healthKitService.startBackgroundSync()
        await rewardedAd.requestATTIfNeeded()
        await rewardedAd.bootstrap()
    }

    /// Stamps this install's first launch and asks `OnboardingGate` whether the first-run flow
    /// should open. Uses counts and a one-row fetch rather than `@Query`: a returning user's food
    /// log can be thousands of rows and nothing here needs the rows themselves.
    private func evaluateOnboardingGate() {
        if firstLaunchedAt == 0 { firstLaunchedAt = Date().timeIntervalSince1970 }

        var profileDescriptor = FetchDescriptor<UserProfile>(sortBy: [SortDescriptor(\.createdAt)])
        profileDescriptor.fetchLimit = 1
        let earliestProfile = (try? modelContext.fetch(profileDescriptor))?.first

        let signals = OnboardingGate.Signals(
            completedAt: onboardingCompletedAt > 0
                ? Date(timeIntervalSince1970: onboardingCompletedAt)
                : nil,
            firstLaunchedAt: Date(timeIntervalSince1970: firstLaunchedAt),
            earliestProfileCreatedAt: earliestProfile?.createdAt,
            hasLoggedFood: ((try? modelContext.fetchCount(FetchDescriptor<FoodEntry>())) ?? 0) > 0,
            hasPlanHistory: ((try? modelContext.fetchCount(FetchDescriptor<GoalPeriod>())) ?? 0) > 1
        )
        showOnboarding = OnboardingGate.shouldPresent(signals)
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
