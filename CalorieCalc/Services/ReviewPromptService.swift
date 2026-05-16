import Foundation
import StoreKit
import SwiftUI

/// Gates Apple's review prompt by app-launch count and a rolling 365-day cap. Apple's own
/// StoreKit throttling already enforces a hard 3-per-year ceiling, but we layer our own gate
/// on top so the very first prompt only fires after the user has had a chance to form an
/// opinion (10 launches), and so we never burn through Apple's quota on a single user with a
/// fourth attempt that would silently fail.
@MainActor
enum ReviewPromptService {
    private static let launchCountKey = "review.launchCount"
    private static let promptHistoryKey = "review.promptHistory"

    private static let minLaunchesBeforePrompt = 10
    private static let maxPromptsPerYear = 3

    /// Call once per app launch from a SwiftUI context that holds `\.requestReview`. Increments
    /// the launch counter and, if the gate passes, asks SwiftUI to surface the review prompt.
    /// We record the attempt locally regardless of whether Apple actually displays it — Apple
    /// gives us no callback, so this is the only signal we can use to space attempts out.
    static func recordLaunchAndMaybePrompt(requestReview: RequestReviewAction) {
        let defaults = UserDefaults.standard
        let launchCount = defaults.integer(forKey: launchCountKey) + 1
        defaults.set(launchCount, forKey: launchCountKey)

        guard launchCount >= minLaunchesBeforePrompt else { return }

        let now = Date()
        let oneYearAgo = now.addingTimeInterval(-365 * 24 * 60 * 60)
        let history = (defaults.array(forKey: promptHistoryKey) as? [Date]) ?? []
        let recent = history.filter { $0 > oneYearAgo }

        guard recent.count < maxPromptsPerYear else { return }

        requestReview()
        let updated = Array((recent + [now]).suffix(maxPromptsPerYear))
        defaults.set(updated, forKey: promptHistoryKey)
    }
}
