import Foundation
import os

/// Funnel events for the first-run flow.
///
/// There is no analytics backend in the app yet, so events go to `os.Logger` — visible in
/// Console.app and in a sysdiagnose, which is enough to watch the funnel on a dev or TestFlight
/// device. `sink` is the seam: point it at a real collector (or a proxy endpoint) once one exists
/// and the whole funnel starts reporting without touching a single call site.
///
/// Nothing here carries user content — event names and coarse enum values only.
@MainActor
enum OnboardingAnalytics {

    enum Event: String, Sendable {
        case started = "onboarding_started"
        case goalChosen = "onboarding_goal_chosen"
        case profileCompleted = "onboarding_profile_completed"
        case planCommitted = "onboarding_plan_committed"
        case planRefineOpened = "onboarding_plan_refine_opened"
        case firstLogAttempted = "onboarding_first_log_attempted"
        case firstLogSucceeded = "onboarding_first_log_succeeded"
        case firstLogSkipped = "onboarding_first_log_skipped"
        case completed = "onboarding_completed"
        /// Recorded when a returning user's CloudKit data lands mid-flow and we bow out.
        case supersededBySync = "onboarding_superseded_by_sync"
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "CalorieCalc",
        category: "onboarding"
    )

    /// Swap in a real collector here. Left `nil` in shipping builds today.
    static var sink: ((Event, [String: String]) -> Void)?

    static func track(_ event: Event, _ properties: [String: String] = [:]) {
        if properties.isEmpty {
            logger.info("\(event.rawValue, privacy: .public)")
        } else {
            let rendered = properties
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            logger.info("\(event.rawValue, privacy: .public) \(rendered, privacy: .public)")
        }
        sink?(event, properties)
    }
}
