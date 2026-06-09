import Foundation
import StoreKit

/// Reports the app's StoreKit distribution environment to the proxy so the temporary
/// "free AI for everyone" promo can be limited to real App Store users.
///
/// App Review builds and TestFlight run in the **Sandbox** environment; App Store
/// downloads run in **Production**. By tagging each authenticated request with
/// `X-StoreKit-Env`, the proxy keeps the promo on for production users while letting the
/// reviewer's sandbox build fall through to the normal credit/paywall flow — so the
/// in-app purchase is reachable during review without taking free AI away from live
/// users (App Store guideline 2.1(b)).
///
/// The value comes from `AppTransaction.shared`, which is available at launch without
/// any purchase. We resolve it once into a cached string; until it resolves (or if it
/// can't be read), `value` is nil and the header is omitted — the proxy treats a missing
/// header as production, so a transient failure never strips the promo from real users.
final class StoreKitEnvironment: @unchecked Sendable {
    static let shared = StoreKitEnvironment()

    private let lock = NSLock()
    private var cached: String?

    /// Current environment string ("Production" / "Sandbox" / "Xcode"), or nil if not
    /// yet resolved. Suitable for the `X-StoreKit-Env` header.
    var value: String? {
        lock.withLock { cached }
    }

    private init() {}

    /// Resolves the environment from `AppTransaction.shared` and caches it. Call once at
    /// launch (e.g. from `RootView.task`). Safe to call repeatedly; failures are silent
    /// and leave the cached value unchanged.
    func prime() async {
        do {
            let result = try await AppTransaction.shared
            if case .verified(let appTransaction) = result {
                store(appTransaction.environment.rawValue)
            }
        } catch {
            print("StoreKitEnvironment.prime failed: \(error)")
        }
    }

    private func store(_ env: String) {
        lock.withLock { cached = env }
    }
}
