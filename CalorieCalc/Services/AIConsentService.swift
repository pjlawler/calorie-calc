import Foundation
import Observation

/// Tracks the user's one-time grant to send data to the third-party AI service
/// (Anthropic's Claude). Every AI entry point — Photo, Describe with AI, Recipe
/// Analyzer, Period Analysis — checks `isGranted` and presents `AIConsentSheet`
/// before sending. Revocable from Settings → Privacy.
///
/// Apple guidelines 5.1.1(i) / 5.1.2(i) require an explicit pre-share consent any
/// time the app transmits personal data to a third-party AI service. Storing a
/// timestamp (rather than a bare Bool) gives us a soft audit trail and lets the
/// UI show "Granted MMM d" in Settings.
@MainActor
@Observable
final class AIConsentService {
    private let userDefaults: UserDefaults
    private let storageKey = "ai.consent.grantedAt"

    private(set) var grantedAt: Date?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let raw = userDefaults.double(forKey: storageKey)
        self.grantedAt = raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    var isGranted: Bool { grantedAt != nil }

    func grant() {
        let now = Date()
        userDefaults.set(now.timeIntervalSince1970, forKey: storageKey)
        grantedAt = now
    }

    func revoke() {
        userDefaults.removeObject(forKey: storageKey)
        grantedAt = nil
    }
}
