import SwiftUI

struct DayCellView: View {
    let date: Date
    let budget: DailyBudget
    let macros: Macros
    let workoutGoal: Int

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
        HStack(spacing: 12) {
            dayStack
            Spacer(minLength: 0)
            consumedStack
            Spacer(minLength: 0)
            exerciseStack
        }
        .padding(.vertical, 10)
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
        VStack(alignment: .leading, spacing: 2) {
            Text(budget.weekday.shortName.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(isToday ? Color.accentColor : .secondary)
            Text(dayNumber)
                .font(.title3.weight(.bold))
                .monospacedDigit()
        }
        .frame(width: 44, alignment: .leading)
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
        }
    }

    private var macroBar: some View {
        let total = max(macros.protein + macros.carbs + macros.fat, 0.0001)
        let pFrac = macros.protein / total
        let cFrac = macros.carbs / total
        let fFrac = macros.fat / total
        return GeometryReader { geo in
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
    }

    private var accessibilityLabel: String {
        let gross = budget.grossBudget.map { "of \(CalorieFormatter.whole($0)) budget" } ?? "(no budget)"
        return "\(budget.weekday.fullName), \(CalorieFormatter.whole(budget.consumed)) calories consumed \(gross), exercise \(CalorieFormatter.whole(budget.burned)) of \(workoutGoal) goal"
    }
}
