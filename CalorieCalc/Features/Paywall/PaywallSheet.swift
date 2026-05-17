import SwiftUI
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

/// Presented from any AI call site that hits a 402 from the proxy. Offers the user
/// two ways forward: subscribe to the monthly plan for unlimited AI, or watch a
/// rewarded video for `CREDITS_PER_AD` credits. Auto-dismisses when entitlements
/// flip back to a usable state — i.e. the verify call lands or SSV grants credits.
struct PaywallSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(EntitlementService.self) private var entitlements
    @Environment(SubscriptionService.self) private var subscription
    @Environment(RewardedAdService.self) private var rewardedAd

    @State private var errorMessage: String?
    @State private var isWatchingAd: Bool = false
    @State private var isRestoring: Bool = false
    @State private var adLoadFailed: Bool = false
    @State private var adLoadError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header

                    subscribeButton

                    orDivider

                    watchAdButton

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                    }

                    if adLoadFailed, let adLoadError {
                        Text("Ad load error: \(adLoadError)")
                            .foregroundStyle(.secondary)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                    }

                    restoreButton
                        .padding(.top, 8)

                    subscriptionDisclosure
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .navigationTitle("AI Credits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            // Warm the rewarded-ad cache so "Watch a video" feels instant. We deliberately
            // do NOT refresh entitlements here: the only way the paywall opens is via a
            // 402 from the proxy (or the debug short-circuit), so the authoritative server
            // state is already "no credits, no sub" by definition. Polling on appear would
            // immediately auto-dismiss the paywall whenever the client and server briefly
            // disagree (e.g. the debug short-circuit), and any real entitlement gain
            // arrives via Transaction.updates or the watch-ad handler — both of which
            // call refresh themselves and trip the onChange handlers below.
            await loadAdIfNeeded()
        }
        .onChange(of: entitlements.subscriptionActive) { _, active in
            if active { dismiss() }
        }
        .onChange(of: entitlements.creditsRemaining) { _, credits in
            if credits > 0 { dismiss() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tint)
                .padding(.top, 8)

            Text("You're out of AI credits")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text("Subscribe for unlimited AI estimates, or watch a short video to earn more credits.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var subscribeButton: some View {
        Button {
            Task { await subscribe() }
        } label: {
            HStack {
                if subscription.purchaseInProgress {
                    ProgressView().controlSize(.small)
                }
                Text(subscribeButtonLabel)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(subscription.product == nil || subscription.purchaseInProgress)
    }

    private var subscribeButtonLabel: String {
        if subscription.purchaseInProgress { return "Subscribing…" }
        if let product = subscription.product {
            return "Subscribe — \(product.displayPrice) / month"
        }
        return "Subscribe — loading…"
    }

    private var orDivider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(.tertiary).frame(height: 1)
            Text("or").font(.footnote).foregroundStyle(.secondary)
            Rectangle().fill(.tertiary).frame(height: 1)
        }
    }

    private var watchAdButton: some View {
        Button {
            Task { await watchAd() }
        } label: {
            HStack {
                if isWatchingAd {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "play.rectangle.fill")
                }
                Text(watchAdButtonLabel)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(!rewardedAd.isReady || isWatchingAd || adLoadFailed)
    }

    private var watchAdButtonLabel: String {
        if isWatchingAd { return "Loading video…" }
        if adLoadFailed { return "Video unavailable" }
        if !rewardedAd.isReady { return "Preparing video…" }
        return "Watch a video — earn credits"
    }

    private var restoreButton: some View {
        Button {
            Task { await restore() }
        } label: {
            HStack(spacing: 6) {
                if isRestoring { ProgressView().controlSize(.small) }
                Text(isRestoring ? "Restoring…" : "Restore purchases")
            }
            .font(.footnote)
        }
        .disabled(isRestoring)
    }

    /// App Store Schedule 2 requires every auto-renewable subscription paywall to display
    /// the subscription title and length, an auto-renew explanation, and functional links
    /// to the Terms of Use and Privacy Policy. Missing any of these is a recurring 3.1.2
    /// rejection reason for indie apps.
    private var subscriptionDisclosure: some View {
        VStack(spacing: 10) {
            Text(disclosureTitleLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("Payment is charged to your Apple ID at purchase confirmation. Subscription auto-renews unless canceled at least 24 hours before the end of the current period. Manage or cancel in Settings → Apple ID → Subscriptions.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 18) {
                Link("Terms of Use", destination: URL(string: "https://pjlawler.github.io/calorie-calc/terms.html")!)
                Link("Privacy Policy", destination: URL(string: "https://pjlawler.github.io/calorie-calc/privacy.html")!)
            }
            .font(.caption)
        }
        .padding(.top, 16)
        .padding(.horizontal, 4)
    }

    private var disclosureTitleLine: String {
        let title = subscription.product?.displayName ?? "AI Subscription"
        if let price = subscription.product?.displayPrice {
            return "\(title) · \(price) / month · auto-renewing subscription"
        }
        return "\(title) · auto-renewing monthly subscription"
    }

    // MARK: - Actions

    private func subscribe() async {
        errorMessage = nil
        let outcome = await subscription.purchase()
        switch outcome {
        case .success:
            // The verify roundtrip inside `purchase()` already refreshed entitlements,
            // which trips `.onChange(...)` and dismisses. Nothing else to do here.
            break
        case .userCancelled:
            break
        case .pending:
            errorMessage = "Purchase is pending — check Settings → Apple ID for any approval needed."
        case .failed(let message):
            errorMessage = message
        }
    }

    private func restore() async {
        errorMessage = nil
        isRestoring = true
        defer { isRestoring = false }
        let found = await subscription.restore()
        if !found {
            errorMessage = "No active subscription was found on this Apple ID."
        }
    }

    private func loadAdIfNeeded() async {
        guard !rewardedAd.isReady else { return }
        // ATT must be resolved before we ask Google for personalised ads. Apple is
        // strict about prompting only at the moment of opt-in; the paywall qualifies
        // since the user has clearly engaged with the credits flow.
        await rewardedAd.requestATTIfNeeded()
        do {
            try await rewardedAd.loadAd()
            adLoadFailed = false
            adLoadError = nil
        } catch {
            adLoadFailed = true
            adLoadError = (error as NSError).localizedDescription
            print("PaywallSheet.loadAd failed: \(error)")
        }
    }

    private func watchAd() async {
        errorMessage = nil
        isWatchingAd = true
        defer { isWatchingAd = false }

        #if canImport(UIKit)
        guard let rootVC = topMostViewController() else {
            errorMessage = "Couldn't open the video right now. Please try again."
            return
        }
        do {
            try await rewardedAd.present(from: rootVC)
            // Credits arrive via SSV — usually before the dismissal transition finishes,
            // but a refresh confirms either way and trips the auto-dismiss.
            await entitlements.refresh()
            // Pre-load the next one so a second tap on a still-presented paywall is also
            // instant. Errors here are non-fatal — the button just disables.
            await loadAdIfNeeded()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        #else
        errorMessage = "Rewarded videos aren't available on this platform."
        #endif
    }

    #if canImport(UIKit)
    /// Walks from the key window's rootViewController down to whatever is currently
    /// presented (this very paywall sheet, normally), so Google Mobile Ads has a
    /// presenter that isn't already presenting something else.
    private func topMostViewController() -> UIViewController? {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?
            .rootViewController else { return nil }
        var vc: UIViewController = root
        while let presented = vc.presentedViewController {
            vc = presented
        }
        return vc
    }
    #endif
}
