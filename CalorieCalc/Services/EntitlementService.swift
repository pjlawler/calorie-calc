import Foundation
import Observation

/// Single source of truth for "right now, can the user run AI?". Polls
/// `GET /v1/account/state` on the proxy and exposes the answer as observable
/// state. SwiftUI views read the published values; AI-call sites push optimistic
/// updates (decrement on success, clear on 402) so the UI reacts before the next
/// authoritative refresh lands.
///
/// Refresh strategy:
///   • At app launch via `RootView.task`.
///   • After every successful AI call (re-sync ground truth from server).
///   • After a 402 response from the proxy (but the call site already optimistically
///     cleared credits — refresh just confirms).
///   • After `Transaction.updates` fires from `SubscriptionService`.
///
/// Failure handling: a refresh that fails (network, attestation, bad timestamp)
/// is silent — the previously-observed state stays in place so transient errors
/// don't flicker the paywall on/off.
@MainActor
@Observable
final class EntitlementService {
    private(set) var subscriptionActive: Bool = false
    private(set) var creditsRemaining: Int = 0
    private(set) var subscriptionExpiresAt: Date?
    private(set) var lastFetched: Date?

    private let proxyBaseURL: URL
    private let attest: AppAttestService
    private let session: URLSession

    init(proxyBaseURL: URL, attest: AppAttestService, session: URLSession = .shared) {
        self.proxyBaseURL = proxyBaseURL
        self.attest = attest
        self.session = session
    }

    func refresh() async {
        do {
            let state = try await fetchState()
            self.subscriptionActive = state.subscriptionActive
            self.creditsRemaining = state.creditsRemaining
            self.subscriptionExpiresAt = state.expiresDate
            self.lastFetched = .now
        } catch {
            // Silently swallow — UI keeps showing last-known good state until the
            // next refresh succeeds. The user-facing surface for "AI doesn't work"
            // is the actual AI call's error, not a state poll.
            print("EntitlementService.refresh failed: \(error)")
        }
    }

    /// Optimistic update fired by the AI call site immediately after a 2xx response.
    /// The next `refresh()` will reconcile with the server's authoritative count, so
    /// any drift (e.g. concurrent ad-grant arriving) self-corrects within seconds.
    func decrementOptimistically() {
        if !subscriptionActive && creditsRemaining > 0 {
            creditsRemaining -= 1
        }
    }

    /// Fired when the proxy returns 402. Clears local credit state so the paywall
    /// renders correctly even before the follow-up refresh confirms.
    func handle402() {
        creditsRemaining = 0
        subscriptionActive = false
    }

    private func fetchState() async throws -> AccountState {
        let path = "/v1/account/state"
        let timestampMs = Int64(Date.now.timeIntervalSince1970 * 1000)
        let assertion = try await attest.assertionForGet(path: path, timestampMs: timestampMs)
        let deviceId = try await attest.deviceId()

        var req = URLRequest(url: proxyBaseURL.appendingPathComponent("v1/account/state"))
        req.httpMethod = "GET"
        req.addValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        req.addValue(assertion, forHTTPHeaderField: "X-Assertion")
        req.addValue(String(timestampMs), forHTTPHeaderField: "X-Timestamp")

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(AccountState.self, from: data)
    }

    /// Wire-format mirror of the proxy's `/v1/account/state` response. The server
    /// emits `subscriptionExpiresAt` as epoch milliseconds (or null); we convert to
    /// `Date?` via the `expiresDate` accessor rather than a custom decoder so the
    /// raw payload remains debuggable.
    private struct AccountState: Decodable {
        let subscriptionActive: Bool
        let creditsRemaining: Int
        let subscriptionExpiresAt: Int64?

        var expiresDate: Date? {
            subscriptionExpiresAt.map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1000)
            }
        }
    }
}
