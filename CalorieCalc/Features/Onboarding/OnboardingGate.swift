import Foundation

/// Decides whether the first-run flow should be presented. Pure and value-typed so the case that
/// actually bites — a returning user whose data arrives from CloudKit *after* this launch — is
/// unit-testable without a ModelContainer.
///
/// "No profile yet" is deliberately NOT the signal: a fresh install on an existing iCloud account
/// has no profile for the first few seconds either, and re-onboarding someone with two years of
/// history is a worse failure than skipping onboarding for someone who needed it.
nonisolated enum OnboardingGate {

    /// How far back a profile's `createdAt` must sit, relative to this install's first launch,
    /// before we read it as "synced in from another device" rather than "created by this launch".
    /// A local bootstrap insert lands within milliseconds; a CloudKit row carries the originating
    /// device's timestamp, which is days or months old.
    static let syncedProfileGrace: TimeInterval = 60

    struct Signals: Equatable, Sendable {
        /// Set once the user finishes (or explicitly skips out of) the flow.
        var completedAt: Date?
        /// First time this install ran, stamped by `RootView` on launch.
        var firstLaunchedAt: Date
        /// `createdAt` of the canonical profile, if one exists yet.
        var earliestProfileCreatedAt: Date?
        /// Any food logged, ever — the strongest "this user has used the app before" signal.
        var hasLoggedFood: Bool
        /// More than one goal period means the plan has been edited at least once, which only
        /// happens after a real session.
        var hasPlanHistory: Bool
    }

    static func shouldPresent(_ signals: Signals) -> Bool {
        if signals.completedAt != nil { return false }
        if signals.hasLoggedFood { return false }
        if signals.hasPlanHistory { return false }
        if let created = signals.earliestProfileCreatedAt,
           created < signals.firstLaunchedAt.addingTimeInterval(-syncedProfileGrace) {
            return false
        }
        return true
    }
}
