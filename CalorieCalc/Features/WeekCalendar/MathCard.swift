import SwiftUI

// MARK: - Data

struct MathCardData: Equatable {
    let weeklyCalorieBudget: Int
    let alreadyEatenThisWeek: Int
    let workoutsCompleted: Int
    let plannedToWorkout: Int
    /// Sum of daily workout goals from day 1 of the week through end of today —
    /// what we should have burned by now. Compared against `workoutsCompleted` to
    /// surface a running exercise variance.
    let exerciseGoalSoFar: Int
    /// Sum of daily gross-calorie goals from day 1 of the week through end of today —
    /// what we should have eaten by now. Compared against `alreadyEatenThisWeek` to
    /// surface a running consumption variance (how much more we can eat to stay on plan).
    let consumeGoalSoFar: Int

    var estimatedRemaining: Int {
        weeklyCalorieBudget
        - alreadyEatenThisWeek
        + workoutsCompleted
        + plannedToWorkout
    }

    /// Positive = ahead of the cumulative exercise plan, negative = behind.
    var exerciseVariance: Int {
        workoutsCompleted - exerciseGoalSoFar
    }

    /// Positive = under the cumulative eating plan (headroom to eat more), negative = over plan.
    var consumedVariance: Int {
        consumeGoalSoFar - alreadyEatenThisWeek
    }

    /// Positive = ahead of plan overall (deficit better than expected), negative = behind.
    /// Both component signs use "good direction = positive", so they sum directly.
    var totalVariance: Int {
        consumedVariance + exerciseVariance
    }
}

// MARK: - Shared

private enum RowSign {
    case none, plus, minus
}

private func formatRowValue(_ value: Int, sign: RowSign) -> String {
    let magnitude = abs(value).formatted(.number)
    switch sign {
    case .none: return magnitude
    case .plus: return "+" + magnitude
    case .minus: return "−" + magnitude
    }
}

// MARK: - MathCard

struct MathCard: View {
    let data: MathCardData
    let isLastDayOrPast: Bool
    var isLoading: Bool = false

    @AppStorage("mathcard.varianceCollapsed") private var varianceCollapsed: Bool = false
    @AppStorage("mathcard.remainingCollapsed") private var remainingCollapsed: Bool = false

    private var remainingEyebrow: String {
        isLastDayOrPast ? "REMAINING THIS WEEK" : "PROJECTED REMAINING"
    }

    private var remainingIsPositive: Bool { data.estimatedRemaining >= 0 }

    private var remainingColor: Color {
        if isLoading { return .secondary }
        return remainingIsPositive ? .green : .red
    }

    private var remainingHeroText: String {
        if isLoading { return "—" }
        let magnitude = abs(data.estimatedRemaining).formatted(.number)
        return remainingIsPositive ? magnitude : "−" + magnitude
    }

    private var varianceHeroText: String {
        if isLoading { return "—" }
        return abs(data.totalVariance).formatted(.number)
    }

    private func rowValueText(value: Int, sign: RowSign) -> String {
        isLoading ? "— kCal" : "\(formatRowValue(value, sign: sign)) kCal"
    }

    private func varianceText(_ value: Int) -> String {
        if isLoading { return "— kCal" }
        let sign = value >= 0 ? "+" : "−"
        return "\(sign)\(abs(value).formatted(.number)) kCal"
    }

    private func varianceColor(_ value: Int) -> Color {
        if isLoading { return .secondary }
        return value >= 0 ? .green : .red
    }

    var body: some View {
        VStack(spacing: 12) {
            if !isLastDayOrPast {
                varianceCard
            }
            remainingCard
        }
    }

    // MARK: - Variance card

    private var varianceCard: some View {
        cardShell(
            collapsed: $varianceCollapsed,
            eyebrow: "OVERALL VARIANCE",
            heroText: varianceHeroText,
            heroColor: varianceColor(data.totalVariance),
            heroAnimationValue: Double(data.totalVariance)
        ) {
            VStack(spacing: 0) {
                varianceRow(label: "Consumed", value: data.consumedVariance)
                varianceRow(label: "Exercise", value: data.exerciseVariance)
            }
        }
    }

    // MARK: - Remaining card

    private var remainingCard: some View {
        cardShell(
            collapsed: $remainingCollapsed,
            eyebrow: remainingEyebrow,
            heroText: remainingHeroText,
            heroColor: remainingColor,
            heroAnimationValue: Double(data.estimatedRemaining)
        ) {
            VStack(spacing: 0) {
                inputRow(label: "Allocated net calories",
                         value: data.weeklyCalorieBudget,
                         sign: .none,
                         color: .primary)
                inputRow(label: "Calories consumed",
                         value: data.alreadyEatenThisWeek,
                         sign: .minus,
                         color: .primary)
                inputRow(label: "Completed exercise",
                         value: data.workoutsCompleted,
                         sign: .plus,
                         color: .green)
                if !isLastDayOrPast {
                    inputRow(label: "Projected exercise",
                             value: data.plannedToWorkout,
                             sign: .plus,
                             color: .green)
                }
            }
        }
    }

    // MARK: - Shared shell

    @ViewBuilder
    private func cardShell<Content: View>(
        collapsed: Binding<Bool>,
        eyebrow: String,
        heroText: String,
        heroColor: Color,
        heroAnimationValue: Double,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    collapsed.wrappedValue.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    Text(eyebrow)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 8)
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(heroText)
                            .font(.system(size: 24, weight: .regular, design: .rounded).monospacedDigit())
                            .foregroundStyle(heroColor)
                            .contentTransition(.numericText(value: heroAnimationValue))
                        Text("kCal")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(heroColor)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed.wrappedValue ? -90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !collapsed.wrappedValue {
                divider
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.12))
            .frame(height: 0.5)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
    }

    private func varianceRow(label: String, value: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(varianceText(value))
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(varianceColor(value))
                .contentTransition(.numericText(value: Double(value)))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
    }

    private func inputRow(label: String, value: Int, sign: RowSign, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(rowValueText(value: value, sign: sign))
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(isLoading ? .secondary : color)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
    }
}

// MARK: - Previews

#Preview("Mid-week — ahead of plan") {
    let math = MathCardData(
        weeklyCalorieBudget: 11_200,
        alreadyEatenThisWeek: 5_200,
        workoutsCompleted: 2_000,
        plannedToWorkout: 1_350,
        exerciseGoalSoFar: 2_000,
        consumeGoalSoFar: 5_400
    )
    return ScrollView {
        MathCard(data: math, isLastDayOrPast: false)
            .padding()
    }
}

#Preview("Negative — over plan") {
    let math = MathCardData(
        weeklyCalorieBudget: 11_200,
        alreadyEatenThisWeek: 13_947,
        workoutsCompleted: 3_742,
        plannedToWorkout: 0,
        exerciseGoalSoFar: 3_500,
        consumeGoalSoFar: 12_600
    )
    return ScrollView {
        MathCard(data: math, isLastDayOrPast: false)
            .padding()
    }
}
