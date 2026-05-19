import SwiftUI

/// Pre-share consent for AI-powered features (Photo, Describe with AI, Recipe
/// Analyzer, Period Analysis). Presented automatically the first time the user
/// taps any AI entry point, and reachable any time from Settings → Privacy.
///
/// Names the recipient (Anthropic PBC), enumerates exactly what each flow sends,
/// and asks for explicit permission before sharing — required by App Store
/// guidelines 5.1.1(i) / 5.1.2(i). The action buttons swap based on whether
/// consent is currently granted, so the same sheet doubles as the management UI.
struct AIConsentSheet: View {

    @Environment(AIConsentService.self) private var aiConsent
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// Fired after the user explicitly taps "Allow" — wire this up from a feature
    /// entry point to continue the pending action (open the photo sheet, etc.).
    /// Not called when the user opens the sheet from Settings.
    var onAllow: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    intro
                    whereCard
                    sentCard
                    notSentCard
                    linksCard
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("AI-powered features")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                buttons
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                    .background(.bar)
            }
        }
    }

    private var intro: some View {
        Text("Some CalorieCalc features use **Anthropic's Claude** AI to estimate nutrition from photos, text, and recipes. Here's exactly what gets sent so you can decide whether to enable them.")
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var whereCard: some View {
        cardShell(title: "Where it goes", icon: "paperplane.fill", iconTint: .accentColor) {
            Text(LocalizedStringKey("**Anthropic PBC** — the company behind Claude. Data travels through CalorieCalc's authenticated proxy server and then to Anthropic's commercial API. Under Anthropic's commercial terms, your input is not used to train AI models."))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sentCard: some View {
        cardShell(title: "What gets sent", icon: "arrow.up.right.circle.fill", iconTint: .blue) {
            bullet("**Photo** — the image you take or pick, plus any description you add.")
            bullet("**Describe with AI** — the text description you type.")
            bullet("**Recipe Analyzer** — the recipe name and ingredient list.")
            bullet("**Period Analysis** — summary totals (calories, macros, exercise) for the period you're viewing. No individual food entries or weigh-ins.")
        }
    }

    private var notSentCard: some View {
        cardShell(title: "Never sent", icon: "lock.fill", iconTint: .green) {
            bullet("Your name, email, or account information")
            bullet("Apple Health workouts, weight, or steps")
            bullet("Your full food log or individual entries")
        }
    }

    private var linksCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill").foregroundStyle(.tint)
                Text("Read more").font(.headline)
            }
            linkRow("CalorieCalc Privacy Policy", url: URL(string: "https://pjlawler.github.io/calorie-calc/privacy.html")!)
            linkRow("Anthropic Privacy Policy", url: URL(string: "https://www.anthropic.com/legal/privacy")!)
            linkRow("CalorieCalc Terms of Service", url: URL(string: "https://pjlawler.github.io/calorie-calc/terms.html")!)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
    }

    private func linkRow(_ title: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.tint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func cardShell<Content: View>(
        title: String,
        icon: String,
        iconTint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(iconTint)
                Text(title).font(.headline)
            }
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
    }

    private func bullet(_ markdown: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(LocalizedStringKey(markdown))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if aiConsent.isGranted {
            VStack(spacing: 8) {
                Button {
                    dismiss()
                } label: {
                    Text("Keep enabled")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(role: .destructive) {
                    aiConsent.revoke()
                    dismiss()
                } label: {
                    Text("Turn off AI features")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
        } else {
            VStack(spacing: 8) {
                Button {
                    aiConsent.grant()
                    onAllow?()
                    dismiss()
                } label: {
                    Text("Allow AI features")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    dismiss()
                } label: {
                    Text("Not now")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }
}
