import SwiftUI

/// One-time "What's New" announcement shown on the first launch after updating. Lists the new
/// AI planning features (the Settings-buried "Ask about my plan" being the headline). Presented
/// from `RootView`, gated on a per-announcement `@AppStorage` flag so it appears only once.
struct WhatsNewSheet: View {

    @Environment(\.dismiss) private var dismiss

    private struct Feature: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        let title: String
        let detail: String
    }

    private let features: [Feature] = [
        Feature(
            icon: "questionmark.bubble.fill",
            tint: .blue,
            title: "Ask about your plan",
            detail: "Ask Claude anything about your plan — like “why am I not losing weight?” — and get a clear, personal answer based on your progress. Find it in Settings → My Plan."
        ),
        Feature(
            icon: "sparkles",
            tint: .purple,
            title: "Build your plan with AI",
            detail: "Get a tailored calorie plan from your height, weight, activity, and goals — then apply it in one tap."
        )
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Two new AI tools to help you get the most out of your plan.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(features) { feature in
                        featureRow(feature)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("What's New")
            .navigationBarTitleDisplayMode(.large)
            .safeAreaInset(edge: .bottom) {
                Button {
                    dismiss()
                } label: {
                    Text("Continue")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
    }

    private func featureRow(_ feature: Feature) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: feature.icon)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(feature.tint.gradient))

            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.headline)
                Text(feature.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
