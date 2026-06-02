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

    private static let keychainService = "com.lawlerinnovationsinc-calorie"
    private static let keychainAccount = "AppAttest.keyId"

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
        let keyId = try await registerNewKey()
        let writeStatus = Self.writeKeychain(keyId)
        cachedKeyId = keyId
        // Registration should happen once per install. If this logs on every launch, the
        // device identity is churning — which re-rolls the initial credit grant and makes
        // ad-reward credits land on an id the app has already abandoned.
        print("AppAttestService: registered new key (keychain write status \(writeStatus))")
        return keyId
    }

    /// Builds a base64 assertion over the request body. The proxy verifies it against the
    /// stored public key.
    func assertion(for body: Data) async throws -> String {
        let keyId = try await deviceId()
        guard let keyIdData = Data(base64Encoded: keyId) else {
            throw AppAttestError.malformedKeyId
        }
        var input = keyIdData
        input.append(body)
        return try await sign(keyId: keyId, clientData: input)
    }

    /// Signs a GET request that has no body. The proxy reconstructs the same byte string
    /// (`keyId || "GET:" || path || ":" || timestampMs`) and verifies the assertion;
    /// requests outside a 60s window are rejected. Use for read-only authenticated
    /// endpoints like `/v1/account/state`.
    func assertionForGet(path: String, timestampMs: Int64) async throws -> String {
        let keyId = try await deviceId()
        guard let keyIdData = Data(base64Encoded: keyId) else {
            throw AppAttestError.malformedKeyId
        }
        var input = keyIdData
        input.append(Data("GET:\(path):\(timestampMs)".utf8))
        return try await sign(keyId: keyId, clientData: input)
    }

    private func sign(keyId: String, clientData: Data) async throws -> String {
        let clientDataHash = Data(SHA256.hash(data: clientData))
        do {
            let assertion = try await attestService.generateAssertion(
                keyId,
                clientDataHash: clientDataHash
            )
            return assertion.base64EncodedString()
        } catch {
            // Only discard the key when Apple says it's genuinely unusable — `.invalidKey`
            // is what you get when a key is invalidated by app restore / OS update / tamper.
            // Transient failures (`.serverUnavailable`, networking) must NOT nuke a good key:
            // doing so forces a re-registration and a brand-new device id, which churns
            // identity (ad-reward credits then land on a stale id) and re-rolls the initial
            // free-credit grant. Re-register only on a real invalid-key error.
            if let dcError = error as? DCError, dcError.code == .invalidKey {
                print("AppAttestService: key invalidated by Apple — discarding for re-registration")
                Self.deleteKeychain()
                cachedKeyId = nil
            } else {
                print("AppAttestService: assertion failed transiently, keeping key: \(error)")
            }
            throw error
        }
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
