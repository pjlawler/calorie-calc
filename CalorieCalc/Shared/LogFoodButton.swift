import SwiftUI

/// The single "Log" food button used both on the day-detail screen and in the weekly
/// view's toolbar. Defined once here so the two entry points are literally the same
/// button — change it here and both update.
struct LogFoodButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Explicit HStack rather than a Label: inside a navigation toolbar SwiftUI
            // collapses a Label to icon-only and strips the title. An HStack of the same
            // image + text isn't recognized as a collapsible label, so the "Log" pill
            // renders identically here and on the day-detail screen.
            HStack(spacing: 4) {
                Image(systemName: "plus.circle.fill")
                Text("Log")
            }
            .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .accessibilityLabel("Log food")
    }
}
