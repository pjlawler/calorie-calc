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

    private var eyebrowText: String {
        isLastDayOrPast ? "REMAINING THIS WEEK" : "ESTIMATED CALORIES REMAINING"
    }

    private var totalIsPositive: Bool { data.estimatedRemaining >= 0 }

    private var totalColor: Color {
        if isLoading { return .secondary }
        return totalIsPositive ? .green : .red
    }

    private var heroText: String {
        if isLoading { return "—" }
        let magnitude = abs(data.estimatedRemaining).formatted(.number)
        return totalIsPositive ? magnitude : "−" + magnitude
    }

    private var totalValueText: String {
        if isLoading { return "— kCal" }
        let magnitude = abs(data.estimatedRemaining).formatted(.number)
        let signed = totalIsPositive ? magnitude : "−" + magnitude
        return signed + " kCal"
    }

    private func rowValueText(value: Int, sign: RowSign) -> String {
        isLoading ? "— kCal" : "\(formatRowValue(value, sign: sign)) kCal"
    }

    private var varianceValueText: String {
        if isLoading { return "— kCal" }
        let v = data.exerciseVariance
        let sign = v >= 0 ? "+" : "−"
        return "\(sign)\(abs(v).formatted(.number)) kCal"
    }

    private var varianceColor: Color {
        if isLoading { return .secondary }
        return data.exerciseVariance >= 0 ? .green : .red
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(eyebrowText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)

            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(heroText)
                    .font(.system(size: 48, weight: .regular, design: .rounded).monospacedDigit())
                    .foregroundStyle(totalColor)
                    .contentTransition(.numericText(value: Double(data.estimatedRemaining)))
                Text("kCal")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(totalColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 20)

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

            Rectangle()
                .fill(Color.black.opacity(0.12))
                .frame(height: 0.5)
                .padding(.horizontal, 4)
                .padding(.vertical, 8)

            HStack(alignment: .firstTextBaseline) {
                Text("Remaining")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(totalValueText)
                    .font(.system(size: 16, weight: .medium).monospacedDigit())
                    .foregroundStyle(totalColor)
                    .contentTransition(.numericText(value: Double(data.estimatedRemaining)))
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)

            HStack(alignment: .firstTextBaseline) {
                Text("Exercise variance")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(varianceValueText)
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(varianceColor)
                    .contentTransition(.numericText(value: Double(data.exerciseVariance)))
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
        }
        .padding(.top, 24)
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
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
        exerciseGoalSoFar: 2_000
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
        exerciseGoalSoFar: 3_500
    )
    return ScrollView {
        MathCard(data: math, isLastDayOrPast: false)
            .padding()
    }
}
