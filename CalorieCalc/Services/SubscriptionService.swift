import Foundation
import Observation
import StoreKit

/// StoreKit 2 wrapper that handles the monthly AI subscription end-to-end:
///   • Loading the product so the paywall can show its display price.
///   • Driving the `product.purchase()` flow on tap.
///   • Posting verified transactions' JWS to `/v1/subscriptions/verify` so the
///     proxy records this device's subscription window in KV.
///   • Listening for `Transaction.updates` (renewals, refunds, family-sharing
///     additions) and routing them to the same verify path.
///   • Restoring purchases — used directly by the paywall's "Restore" button and
///     silently by the 402 retry path so a user who subscribed on another device
///     gets recognized without manual intervention.
///
/// Cross-device propagation: when this device first verifies a transaction, the
/// proxy maps `originalTransactionId → [deviceId]`. App Store Server
/// Notifications V2 then fan renewal/refund events out to every device under the
/// same Apple ID. iOS 15+ only (StoreKit 2 / `Transaction.jwsRepresentation`).
@MainActor
@Observable
final class SubscriptionService {
    static let productId = "com.lawlerinnovationsinc_calorie.ai.monthly"

    private(set) var product: Product?
    private(set) var purchaseInProgress: Bool = false

    private let proxyBaseURL: URL
    private let attest: AppAttestService
    private let entitlements: EntitlementService
    private let session: URLSession
    private var transactionListener: Task<Void, Never>?

    init(
        proxyBaseURL: URL,
        attest: AppAttestService,
        entitlements: EntitlementService,
        session: URLSession = .shared
    ) {
        self.proxyBaseURL = proxyBaseURL
        self.attest = attest
        self.entitlements = entitlements
        self.session = session
    }

    /// Idempotent. Call once at app launch from `RootView.task`. Without this, a
    /// renewal or external purchase that arrives while the app is foregrounded
    /// would be silently dropped — the user would only notice on the next launch.
    /// The task runs for the lifetime of the app (no cancellation path); since
    /// this service is owned by `CalorieCalcApp`, that matches the process lifetime.
    func startListeningForTransactions() {
        guard transactionListener == nil else { return }
        transactionListener = Task.detached { [weak self] in
            for await update in Transaction.updates {
                await self?.handleVerification(update)
            }
        }
    }

    func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.productId])
            self.product = products.first
        } catch {
            print("SubscriptionService.loadProduct failed: \(error)")
        }
    }

    enum PurchaseOutcome: Sendable {
        case success
        case userCancelled
        case pending
        case failed(String)
    }

    func purchase() async -> PurchaseOutcome {
        guard let product = product else { return .failed("Product not loaded") }
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified = verification {
                    await handleVerification(verification)
                    return .success
                }
                return .failed("Transaction failed Apple's verification.")
            case .userCancelled:
                return .userCancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed("Unknown StoreKit result.")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Iterates all of the user's current entitlements (across devices, via Apple
    /// ID) and posts each to the proxy. Returns true if at least one matching
    /// subscription was found — the paywall uses this to decide whether to show
    /// "No purchases to restore" or just dismiss.
    @discardableResult
    func restore() async -> Bool {
        var found = false
        for await result in Transaction.currentEntitlements {
            if case let .verified(tx) = result, tx.productID == Self.productId {
                await handleVerification(result)
                found = true
            }
        }
        await entitlements.refresh()
        return found
    }

    /// The JWS we forward to the proxy lives on the `VerificationResult` wrapper,
    /// not on the unwrapped `Transaction` — that's where Apple keeps the originally
    /// signed payload. Unwrap once for the `finish()` call, then post the JWS.
    private func handleVerification(_ result: VerificationResult<Transaction>) async {
        guard case let .verified(tx) = result else { return }
        do {
            try await postVerify(jws: result.jwsRepresentation)
            await tx.finish()
            await entitlements.refresh()
        } catch {
            print("SubscriptionService.handleVerification failed: \(error)")
        }
    }

    private func postVerify(jws: String) async throws {
        struct Body: Encodable { let jwsRepresentation: String }
        let bodyData = try JSONEncoder().encode(Body(jwsRepresentation: jws))
        let attested = try await attest.attestedHeaders(for: bodyData)

        var req = URLRequest(url: proxyBaseURL.appendingPathComponent("v1/subscriptions/verify"))
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "content-type")
        req.addValue(attested.deviceId, forHTTPHeaderField: "X-Device-Id")
        req.addValue(attested.assertion, forHTTPHeaderField: "X-Assertion")
        req.httpBody = bodyData

        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
