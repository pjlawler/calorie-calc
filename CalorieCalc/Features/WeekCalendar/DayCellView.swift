import SwiftUI

struct DayCellView: View {
    let date: Date
    let budget: DailyBudget
    let macros: Macros
    let workoutGoal: Int
    /// When non-nil, shown inline next to "consumed / planned". Wired to today's cell only —
    /// surfaces the same number that the variance card on the day view shows.
    var varianceValue: Int? = nil

    struct Macros: Hashable {
        var protein: Double
        var carbs: Double
        var fat: Double
    }

    private let exerciseColor = Color(red: 0.25, green: 0.70, blue: 0.35)

    private var dayNumber: String {
        date.formatted(.dateTime.day())
    }

    private var isToday: Bool { budget.status == .today }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            dayStack
            Divider()
            consumedStack
                .padding(.leading, 20)
            Spacer(minLength: 0)
            exerciseStack
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(budget.isBankingDay ? 0 : 0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(isToday ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1.5)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var dayStack: some View {
        // Both labels fill the 44pt slot and center within it. Without `maxWidth: .infinity`
        // each Text would self-size to its glyph width, leaving a one-digit day ("1") sitting
        // at the natural baseline of the wider "FRI" instead of centered under it.
        VStack(spacing: 2) {
            Text(budget.weekday.shortName.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(isToday ? Color.accentColor : .secondary)
                .frame(maxWidth: .infinity)
            Text(dayNumber)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
        }
        .frame(width: 44)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var consumedStack: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(CalorieFormatter.whole(budget.consumed))
                    .font(.headline.monospacedDigit())
                if let gross = budget.grossBudget {
                    Text("/ \(CalorieFormatter.whole(gross))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            macroBar
            varianceRow
        }
    }

    /// Day-level variance shown only on today's cell (driven by `varianceValue` being non-nil).
    /// Sits below the progress + macro bar, left-aligned, with a "Plan Remaining" label.
    @ViewBuilder
    private var varianceRow: some View {
        if let variance = varianceValue {
            let magnitude = abs(variance).formatted(.number)
            let color: Color = variance >= 0 ? .green : .red
            HStack(spacing: 6) {
                Text(magnitude)
                    .font(.system(size: 16.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(color, lineWidth: 1)
                    )
                Text("Plan Remaining")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var macroBar: some View {
        if budget.status == .future {
            // Solid gray placeholder for future days — keeps the row's vertical rhythm matching
            // past/today cells without pretending to show a macro split that doesn't exist yet.
            Capsule()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 4)
                .frame(maxWidth: 120)
        } else {
            let total = max(macros.protein + macros.carbs + macros.fat, 0.0001)
            let pFrac = macros.protein / total
            let cFrac = macros.carbs / total
            let fFrac = macros.fat / total
            GeometryReader { geo in
                HStack(spacing: 1) {
                    Rectangle().fill(.tint).frame(width: geo.size.width * pFrac)
                    Rectangle().fill(Color.orange).frame(width: geo.size.width * cFrac)
                    Rectangle().fill(Color.pink).frame(width: geo.size.width * fFrac)
                }
                .clipShape(Capsule())
                .opacity(total > 0.001 ? 1 : 0.2)
            }
            .frame(height: 4)
            .frame(maxWidth: 120)
        }
    }

    private var exerciseStack: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("exercise")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(CalorieFormatter.whole(budget.burned))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(exerciseColor)
                Text("/ \(workoutGoal)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var accessibilityLabel: String {
        let gross = budget.grossBudget.map { "of \(CalorieFormatter.whole($0)) budget" } ?? "(no budget)"
        return "\(budget.weekday.fullName), \(CalorieFormatter.whole(budget.consumed)) calories consumed \(gross), exercise \(CalorieFormatter.whole(budget.burned)) of \(workoutGoal) goal"
    }
}
