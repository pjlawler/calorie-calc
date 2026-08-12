import SwiftUI

/// Step 1 — what are you here to do. One tap, no typing: the cheapest possible first question,
/// asked before anything that feels like data entry.
///
/// The options map 1:1 onto `WeightGoalPace`, which is what `TDEECalculator` already consumes, so
/// this screen adds no new plan concepts. Weight *gain* is intentionally absent — the calorie math
/// only models a deficit (`pace.dailyDeficit` is never negative), and inventing a surplus path
/// here would mean a plan the rest of the app can't honestly evaluate.
struct OnboardingGoalStep: View {

    @Bindable var state: OnboardingState
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                VStack(spacing: 10) {
                    ForEach(orderedPaces) { pace in
                        optionRow(pace)
                    }
                }
            }
            .padding()
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            Button {
                onContinue()
            } label: {
                Text("Continue")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(state.pace == nil)
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    /// Losing leads. `WeightGoalPace.allCases` starts at `maintain`, which is the right order for
    /// the Settings picker but buries the reason almost everyone installs a calorie tracker.
    private var orderedPaces: [WeightGoalPace] {
        [.slow, .moderate, .aggressive, .maintain]
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What's your goal?")
                .font(.largeTitle.bold())
            Text("This sets your daily calorie target. You can change it any time in Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func optionRow(_ pace: WeightGoalPace) -> some View {
        let isSelected = state.pace == pace
        return Button {
            state.pace = pace
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(pace.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(pace.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                    .font(.title3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
