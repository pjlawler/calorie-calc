import Foundation
import Observation
import UIKit
import AppTrackingTransparency

#if canImport(GoogleMobileAds)
import GoogleMobileAds

/// Wraps Google Mobile Ads SDK's rewarded-video flow. The actual credit grant
/// happens via Server-Side Verification on the proxy — this client just loads
/// and presents the ad, and tags it with the device's App Attest keyId so AdMob
/// passes that as `user_id` in the SSV callback.
///
/// Lifecycle:
///   • `bootstrap()` once at app launch.
///   • `requestATTIfNeeded()` the first time the user taps "Earn credits" — Apple
///     requires App Tracking Transparency consent before personalized ads.
///   • `loadAd()` when the paywall opens (warms the cache so present is instant).
///   • `present(from:)` when the user taps the watch button. Resolves on dismissal.
///
/// After `present` returns, the caller refreshes `EntitlementService` to pull the
/// new credit balance — the actual grant is async via the SSV callback and
/// usually arrives before the user finishes dismissing the ad.
@MainActor
@Observable
final class RewardedAdService {
    private(set) var isReady: Bool = false

    private let attest: AppAttestService
    private let adUnitId: String
    private var rewardedAd: GADRewardedAd?
    private var presentationCoordinator: AdPresentationCoordinator?
    private var didBootstrap = false

    init(attest: AppAttestService, adUnitId: String) {
        self.attest = attest
        self.adUnitId = adUnitId
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            GADMobileAds.sharedInstance().start { _ in continuation.resume() }
        }
    }

    /// Apple requires explicit ATT consent before SDKs may use IDFA for ad
    /// targeting. We prompt at the point the user opts into watching an ad —
    /// not at app launch — for both compliance and a higher grant rate.
    func requestATTIfNeeded() async {
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }
        _ = await ATTrackingManager.requestTrackingAuthorization()
    }

    func loadAd() async throws {
        let request = GADRequest()
        let ad = try await GADRewardedAd.load(withAdUnitID: adUnitId, request: request)
        // Tag the ad with the App Attest keyId. AdMob includes this as the `user_id`
        // querystring param in the SSV callback, so the proxy knows which device
        // record to credit. Skipping this would mean every reward goes to /dev/null.
        let deviceId = try await attest.deviceId()
        let options = GADServerSideVerificationOptions()
        options.userIdentifier = deviceId
        ad.serverSideVerificationOptions = options
        rewardedAd = ad
        isReady = true
    }

    /// Presents the loaded ad and resolves when it's dismissed. Throws
    /// `RewardedAdError.notReady` if `loadAd()` hasn't completed. The user-earned
    /// reward callback is fired but ignored client-side — credits arrive via SSV.
    func present(from rootVC: UIViewController) async throws {
        guard let ad = rewardedAd else { throw RewardedAdError.notReady }

        // Coordinator must be retained for the duration of the presentation since
        // GADRewardedAd holds the delegate weakly. Storing on `self` survives the
        // method's continuation suspension.
        let coordinator = AdPresentationCoordinator()
        presentationCoordinator = coordinator
        ad.fullScreenContentDelegate = coordinator

        defer {
            rewardedAd = nil
            isReady = false
            presentationCoordinator = nil
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coordinator.continuation = continuation
            ad.present(fromRootViewController: rootVC) {
                // User qualified for the reward. Server-side verification will fire
                // the actual credit grant — nothing to do here.
            }
        }
    }
}

private final class AdPresentationCoordinator: NSObject, GADFullScreenContentDelegate {
    var continuation: CheckedContinuation<Void, Error>?

    func adDidDismissFullScreenContent(_ ad: GADFullScreenPresentingAd) {
        continuation?.resume()
        continuation = nil
    }

    func ad(
        _ ad: GADFullScreenPresentingAd,
        didFailToPresentFullScreenContentWithError error: Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

#else

/// Stub for builds before the Google Mobile Ads SDK has been added via Swift
/// Package Manager (Phase 3 manual step). Compiles cleanly so the rest of the app
/// continues to build; reports "ad SDK not installed" at runtime if invoked.
@MainActor
@Observable
final class RewardedAdService {
    private(set) var isReady: Bool = false

    init(attest: AppAttestService, adUnitId: String) {}

    func bootstrap() async {}
    func requestATTIfNeeded() async {}
    func loadAd() async throws {
        throw RewardedAdError.sdkNotInstalled
    }
    func present(from rootVC: UIViewController) async throws {
        throw RewardedAdError.sdkNotInstalled
    }
}

#endif

enum RewardedAdError: LocalizedError, Sendable {
    case notReady
    case sdkNotInstalled

    var errorDescription: String? {
        switch self {
        case .notReady:
            "The ad isn't ready yet — give it a moment and try again."
        case .sdkNotInstalled:
            "Ad SDK isn't installed in this build."
        }
    }
}
