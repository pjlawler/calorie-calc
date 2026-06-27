import CryptoKit
import DeviceCheck
import Foundation
import Security

/// Talks to the proxy's `/v1/attest/*` endpoints. On first use, generates a hardware-backed
/// App Attest key, registers it with the proxy, and stores the keyId in Keychain. For each
/// API request, produces a one-shot ECDSA assertion bound to the request body so a captured
/// header can't be replayed against a different prompt.
///
/// App Attest is hardware-gated — `isSupported` returns false in the iOS Simulator, so AI
/// features only work on a real device for builds wired to this service.
actor AppAttestService {

    private let proxyBaseURL: URL
    private let session: URLSession
    private let attestService = DCAppAttestService.shared

    private var cachedKeyId: String?
    // Held while a registration is in flight so concurrent first-callers await the same
    // registration instead of each starting their own (see deviceId()).
    private var registrationTask: Task<String, Error>?

    private static let keychainService = "com.lawlerinnovationsinc-calorie"
    // A Debug (Xcode = development env) build and a Release (TestFlight/App Store = production
    // env) build share a keychain that survives uninstalls, so a single account name lets one
    // build's key get reused by the other environment — which Apple rejects with
    // DCError.invalidInput. We give the Debug build its OWN slot so the two coexist on one
    // device. Production KEEPS the original "AppAttest.keyId" name on purpose: renaming it would
    // make every existing install re-register a fresh identity on update, stranding ad-reward
    // credits and re-rolling the initial grant — the exact churn this service guards against.
    // #if DEBUG tracks APP_ATTEST_ENV exactly (Debug → development, Release → production).
    #if DEBUG
    private static let keychainAccount = "AppAttest.keyId.development"
    #else
    private static let keychainAccount = "AppAttest.keyId"
    #endif

    init(proxyBaseURL: URL, session: URLSession = .shared) {
        self.proxyBaseURL = proxyBaseURL
        self.session = session
    }

    /// Returns the keyId used as `X-Device-Id`. Triggers registration on first call.
    func deviceId() async throws -> String {
        if let cached = cachedKeyId { return cached }
        if let stored = Self.readKeychain() {
            cachedKeyId = stored
            return stored
        }
        // Single-flight the registration. `deviceId()` is called concurrently by several
        // services on a cold launch (entitlements, subscriptions, the AI services, the
        // rewarded-ad loader). Actors are reentrant across `await`, so without this guard
        // each concurrent first-caller would start its OWN registerNewKey() while the
        // first is suspended on its network round-trips — minting several App Attest keys
        // and server device records in a single launch, and stranding any ad reward that
        // was tagged with one of the losing identities. Funnelling everyone through one
        // Task makes registration happen exactly once.
        if let existing = registrationTask {
            return try await existing.value
        }
        let task = Task { try await self.performRegistration() }
        registrationTask = task
        defer { registrationTask = nil }
        return try await task.value
    }

    /// Generates + registers a new key, persists it, and caches it. Extracted so the
    /// single-flight Task in `deviceId()` has exactly one thing to await. Caches the keyId
    /// in memory unconditionally so every caller this session shares ONE identity (no
    /// mid-session churn); a failure to persist only risks a re-register on the next cold
    /// launch, which we log loudly rather than silently absorbing.
    private func performRegistration() async throws -> String {
        let keyId = try await registerNewKey()
        let writeStatus = Self.writeKeychain(keyId)
        // Read back to confirm the write actually stuck — a silent failure here is what
        // turns into cross-launch identity churn.
        let persisted = writeStatus == errSecSuccess && Self.readKeychain() == keyId
        cachedKeyId = keyId
        if persisted {
            print("AppAttestService: registered new key (persisted)")
        } else {
            // If this recurs, identity is churning across launches — re-rolling the
            // initial credit grant and stranding ad-reward credits on abandoned ids.
            print("AppAttestService: registered new key but keychain did NOT persist (status \(writeStatus)) — identity may churn across launches")
        }
        return keyId
    }

    /// The `X-Device-Id` + `X-Assertion` pair for one request. Returned together (rather than
    /// having callers fetch the id via a separate `deviceId()` call) so the two ALWAYS name the
    /// same key: a recovery re-registration inside the signing path changes the keyId mid-call,
    /// and a stale `X-Device-Id` paired with a fresh assertion would be rejected by the proxy.
    struct AttestedHeaders {
        let deviceId: String
        let assertion: String
    }

    /// Builds the attested headers for a POST body. The proxy verifies the assertion against
    /// the stored public key for `deviceId`.
    func attestedHeaders(for body: Data) async throws -> AttestedHeaders {
        try await signedAssertion { keyId in
            guard let keyIdData = Data(base64Encoded: keyId) else {
                throw AppAttestError.malformedKeyId
            }
            var input = keyIdData
            input.append(body)
            return input
        }
    }

    /// Builds the attested headers for a GET request that has no body. The proxy reconstructs
    /// the same byte string (`keyId || "GET:" || path || ":" || timestampMs`) and verifies the
    /// assertion; requests outside a 60s window are rejected. Use for read-only authenticated
    /// endpoints like `/v1/account/state`.
    func attestedHeadersForGet(path: String, timestampMs: Int64) async throws -> AttestedHeaders {
        try await signedAssertion { keyId in
            guard let keyIdData = Data(base64Encoded: keyId) else {
                throw AppAttestError.malformedKeyId
            }
            var input = keyIdData
            input.append(Data("GET:\(path):\(timestampMs)".utf8))
            return input
        }
    }

    /// Signs `clientData(keyId)` with the current key and returns the keyId it used. If Apple
    /// rejects the stored key as unusable — `.invalidKey` (invalidated by app restore / OS
    /// update / tamper) or `.invalidInput` (notably what you get when the stored key was minted
    /// under a different App Attest environment, e.g. after the same device runs both an Xcode
    /// build [development] and a TestFlight build [production]; the keychain keyId survives the
    /// uninstall, so the wrong-environment key keeps getting reused) — it discards the key,
    /// registers a fresh one, and retries exactly ONCE.
    ///
    /// The single retry is deliberate: it bounds identity churn so a transient Apple blip can't
    /// loop us into re-registering on every call. All other failures (`.serverUnavailable`,
    /// networking) keep the key untouched and propagate — nuking a good key there would force a
    /// needless re-registration, churning the device id (ad-reward credits then land on a stale
    /// id) and re-rolling the initial free-credit grant.
    private func signedAssertion(_ clientData: (String) throws -> Data) async throws -> AttestedHeaders {
        let keyId = try await deviceId()
        do {
            let assertion = try await rawSign(keyId: keyId, clientData: try clientData(keyId))
            return AttestedHeaders(deviceId: keyId, assertion: assertion)
        } catch let error as DCError where error.code == .invalidKey || error.code == .invalidInput {
            print("AppAttestService: key rejected by Apple (code \(error.code.rawValue)) — re-registering once and retrying")
            Self.deleteKeychain()
            cachedKeyId = nil
            // Empty keychain + cache → deviceId() mints and registers a fresh key. If this
            // retried assertion also fails, we let it propagate rather than loop.
            let freshKeyId = try await deviceId()
            let assertion = try await rawSign(keyId: freshKeyId, clientData: try clientData(freshKeyId))
            return AttestedHeaders(deviceId: freshKeyId, assertion: assertion)
        } catch {
            print("AppAttestService: assertion failed transiently, keeping key: \(error)")
            throw error
        }
    }

    private func rawSign(keyId: String, clientData: Data) async throws -> String {
        let clientDataHash = Data(SHA256.hash(data: clientData))
        let assertion = try await attestService.generateAssertion(
            keyId,
            clientDataHash: clientDataHash
        )
        return assertion.base64EncodedString()
    }

    private func registerNewKey() async throws -> String {
        guard attestService.isSupported else {
            throw AppAttestError.unsupportedDevice
        }
        let keyId = try await attestService.generateKey()
        let challengeB64 = try await fetchChallenge()
        guard let challengeBytes = Data(base64Encoded: challengeB64) else {
            throw AppAttestError.badServerResponse("challenge")
        }
        let clientDataHash = Data(SHA256.hash(data: challengeBytes))
        let attestation = try await attestService.attestKey(
            keyId,
            clientDataHash: clientDataHash
        )
        try await sendRegistration(
            keyId: keyId,
            attestation: attestation,
            challenge: challengeB64
        )
        return keyId
    }

    private func fetchChallenge() async throws -> String {
        var req = URLRequest(url: proxyBaseURL.appendingPathComponent("v1/attest/challenge"))
        req.httpMethod = "POST"
        let (data, resp) = try await session.data(for: req)
        try Self.expectOK(resp, context: "challenge")
        let decoded = try JSONDecoder().decode(ChallengeResponse.self, from: data)
        return decoded.challenge
    }

    private func sendRegistration(keyId: String, attestation: Data, challenge: String) async throws {
        var req = URLRequest(url: proxyBaseURL.appendingPathComponent("v1/attest/register"))
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "content-type")
        let body = RegistrationRequest(
            keyId: keyId,
            attestation: attestation.base64EncodedString(),
            challenge: challenge
        )
        req.httpBody = try JSONEncoder().encode(body)
        let (_, resp) = try await session.data(for: req)
        try Self.expectOK(resp, context: "register")
    }

    private static func expectOK(_ resp: URLResponse, context: String) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw AppAttestError.badServerResponse(context)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppAttestError.serverRejected(context, http.statusCode)
        }
    }

    private struct ChallengeResponse: Decodable { let challenge: String }
    private struct RegistrationRequest: Encodable {
        let keyId: String
        let attestation: String
        let challenge: String
    }

    // MARK: - Keychain

    private static func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Persists the keyId. Returns the OSStatus so the caller can surface failures —
    /// a silent write failure means a new identity is minted on every launch, which is
    /// precisely the churn we're guarding against.
    @discardableResult
    private static func writeKeychain(_ value: String) -> OSStatus {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attrs) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            print("AppAttestService: keychain write failed, status \(status)")
        }
        return status
    }

    private static func deleteKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum AppAttestError: LocalizedError {
    case unsupportedDevice
    case malformedKeyId
    case badServerResponse(String)
    case serverRejected(String, Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedDevice:
            "AI features require a physical device with App Attest support."
        case .malformedKeyId:
            "Internal error: stored attest key id is invalid."
        case .badServerResponse(let ctx):
            "Bad response from server (\(ctx))."
        case .serverRejected(let ctx, let code):
            "Server rejected \(ctx) with status \(code)."
        }
    }
}
