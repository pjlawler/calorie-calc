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
    /// Per-day gross-eaten target. Used by the Eat Today blurb to decide whether the
    /// projected per-day budget is still big enough to eat normally.
    let dailyGrossGoal: Int
    /// Days remaining in the week (excludes today's logged-but-incomplete day count from
    /// past + today). Used as the divisor for projected-per-day budget math.
    let remainingDays: Int

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
    /// Toggle each section independently. The Calc tab now hides the variance card
    /// (it surfaces inline on today's day cell + on the day view); the day view
    /// hides the remaining card (it stays on the week summary).
    var includeVariance: Bool = true
    var includeRemaining: Bool = true

    @AppStorage("mathcard.varianceCollapsed") private var varianceCollapsed: Bool = false
    @AppStorage("mathcard.remainingCollapsed") private var remainingCollapsed: Bool = false

    private var remainingEyebrow: String {
        // One label across both states — same math, just less projection on the last day.
        "PROJECTED REMAINING"
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
            if includeVariance && !isLastDayOrPast {
                varianceCard
            }
            if includeRemaining {
                remainingCard
            }
        }
    }

    // MARK: - Variance card

    private var varianceCard: some View {
        cardShell(
            collapsed: $varianceCollapsed,
            eyebrow: "WEEK'S VARIANCE",
            heroText: varianceHeroText,
            heroColor: varianceColor(data.totalVariance),
            heroAnimationValue: Double(data.totalVariance)
        ) {
            VStack(spacing: 0) {
                varianceRow(label: "Consumption variance", value: data.consumedVariance)
                varianceRow(label: "Exercise variance", value: data.exerciseVariance)
                blurb(eatTodayBlurb, tint: varianceColor(data.totalVariance))
            }
        }
    }

    /// Dynamic copy that frames the variance number motivationally based on where the user
    /// stands: ahead of plan, behind but recoverable, or behind with a tight runway.
    private var eatTodayBlurb: String {
        let intro = "This is your current tracking on the plan based on your actual intake and exercise through today. Exercising more will increase this number."
        if data.totalVariance >= 0 {
            return intro + " You're on track to land on plan this week — keep going."
        }
        // Negative variance. Compare projected per-day budget to the daily gross goal — if
        // there's still room to eat normally for the rest of the week, reassure; otherwise
        // own it and aim to recover next week.
        let perDayProjected: Double
        if data.remainingDays > 0 {
            perDayProjected = Double(data.estimatedRemaining) / Double(data.remainingDays)
        } else {
            perDayProjected = Double(data.estimatedRemaining)
        }
        if perDayProjected >= Double(data.dailyGrossGoal) {
            return intro + " You're behind, but there's still room to make it a successful week. Stay tight today and you'll be fine."
        }
        return intro + " Things are tight. Do your best to minimize the damage today — anything you can't make up here, we'll catch on next week."
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
                inputRow(label: "Actual consumed",
                         value: data.alreadyEatenThisWeek,
                         sign: .minus,
                         color: .primary)
                inputRow(label: "Actual exercise",
                         value: data.workoutsCompleted,
                         sign: .plus,
                         color: .green)
                if !isLastDayOrPast {
                    inputRow(label: "Projected exercise",
                             value: data.plannedToWorkout,
                             sign: .plus,
                             color: .green)
                }
                if !isLastDayOrPast {
                    blurb(projectedRemainingBlurb, tint: remainingColor)
                }
            }
        }
    }

    /// Reads as a guidebook for the projected number — explains what the figure represents
    /// and reinforces that staying on plan today + tomorrow lands them here.
    private var projectedRemainingBlurb: String {
        if data.estimatedRemaining >= 0 {
            return "What's left in your weekly budget if you stay on your eating and exercise plan for the rest of the week. Hold the line and you'll land here."
        }
        return "If you keep going at the current pace, the week will finish over budget by this much. Add a workout, dial back tomorrow's gross, or accept it and reset Sunday — you've got time to swing it back."
    }

    // MARK: - Shared shell

    @ViewBuilder
    private func cardShell<Content: View>(
        collapsed: Binding<Bool>,
        eyebrow: String,
        heroText: String,
        heroColor: Color,
        heroAnimationValue: Double,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        CardShell(
            collapsed: collapsed,
            eyebrow: eyebrow,
            heroText: heroText,
            heroColor: heroColor,
            heroAnimationValue: heroAnimationValue,
            content: content
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.12))
            .frame(height: 0.5)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
    }

    /// Small motivational paragraph below the row content. A divider above visually separates
    /// it from the breakdown rows. Color is `.primary` with reduced opacity so it stands out
    /// from the secondary row labels but doesn't compete with the hero number.
    private func blurb(_ text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            divider
            Text(text)
                .font(.footnote)
                .foregroundStyle(Color.primary.opacity(0.85))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 4)
        }
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

// MARK: - CardShell

/// Expand/collapse shell with measured-height frame animation. Without measurement, animating
/// a `.frame(maxHeight:)` between 0 and `.infinity` interacts poorly with List row layout —
/// row resize and content fade can desync, producing the "text drops in" effect. Here we
/// render an off-screen measurer to capture the content's natural height, then animate a
/// real `.frame(height:)` between 0 and that exact value, which interpolates cleanly.
private struct CardShell<Content: View>: View {
    @Binding var collapsed: Bool
    let eyebrow: String
    let heroText: String
    let heroColor: Color
    let heroAnimationValue: Double
    @ViewBuilder let content: () -> Content

    private var disclosedBody: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.black.opacity(0.12))
                .frame(height: 0.5)
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
            content()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    collapsed.toggle()
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
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                        .animation(.easeInOut(duration: 0.2), value: collapsed)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !collapsed {
                disclosedBody
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
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
        consumeGoalSoFar: 5_400,
        dailyGrossGoal: 1_800,
        remainingDays: 3
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
        consumeGoalSoFar: 12_600,
        dailyGrossGoal: 1_800,
        remainingDays: 0
    )
    return ScrollView {
        MathCard(data: math, isLastDayOrPast: false)
            .padding()
    }
}
