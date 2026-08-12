import SwiftUI

/// Step 4 — the activation moment, and the reason the other three steps exist.
///
/// Everything routes through the shipping flow: `FoodPhotoSheet` produces a `FoodSearchResult`,
/// `FoodPortionSheet` logs it. Nothing here is an onboarding-only imitation of logging, so the
/// meal the user creates is a real entry and the gesture they learn is the one they'll repeat.
struct OnboardingFirstLogStep: View {

    let onLogged: () -> Void
    let onSkip: () -> Void

    @Environment(AIConsentService.self) private var aiConsent

    @State private var showPhotoAnalyzer = false
    @State private var showAIConsent = false
    @State private var pendingAIAction: (() -> Void)?
    @State private var portionTarget: FoodSearchResult?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                steps
            }
            .padding()
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button {
                    OnboardingAnalytics.track(.firstLogAttempted)
                    requestAI { showPhotoAnalyzer = true }
                } label: {
                    Label("Take a photo of your food", systemImage: "camera.fill")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    onSkip()
                } label: {
                    Text("I'll log something later")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .sheet(isPresented: $showPhotoAnalyzer) {
            FoodPhotoSheet { result in
                portionTarget = result
            }
        }
        .sheet(item: $portionTarget) { target in
            FoodPortionSheet(
                result: target,
                mealType: MealType.quickAddDefaultForCurrentTime(),
                date: Calendar.current.startOfDay(for: .now),
                addToMyFoods: true
            ) {
                onLogged()
            }
        }
        .sheet(isPresented: $showAIConsent, onDismiss: { pendingAIAction = nil }) {
            AIConsentSheet(onAllow: {
                let action = pendingAIAction
                pendingAIAction = nil
                action?()
            })
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Log your first meal")
                .font(.largeTitle.bold())
            Text("Point your camera at whatever you're eating next. Claude reads the plate and fills in the calories and macros for you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 14) {
            bullet("camera.fill", "Snap a photo", "Or pick one from your library.")
            bullet("sparkles", "Claude estimates it", "Calories, protein, carbs and fat — with a portion you can adjust.")
            bullet("checkmark.circle.fill", "It lands on today", "And it's saved to My Foods so logging it again is one tap.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
    }

    private func bullet(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Same consent gate every other AI entry point uses — the photo sheet never opens before the
    /// user has explicitly allowed sharing with Anthropic.
    private func requestAI(_ action: @escaping () -> Void) {
        if aiConsent.isGranted {
            action()
        } else {
            pendingAIAction = action
            showAIConsent = true
        }
    }
}
