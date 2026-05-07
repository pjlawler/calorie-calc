import SwiftUI

struct DayCellView: View {
    let date: Date
    let budget: DailyBudget
    /// When non-nil, shows a bordered magnitude box in the Remaining column. Wired to
    /// today's cell only — surfaces the same number the day view's variance card shows.
    var varianceValue: Int? = nil

    private let exerciseColor = Color.cyan

    private var dayNumber: String {
        date.formatted(.dateTime.day())
    }

    private var isToday: Bool { budget.status == .today }

    var body: some View {
        HStack(alignment: .center, spacing: DayCellLayout.columnSpacing) {
            dayStack
            Divider()
            Text(CalorieFormatter.whole(budget.consumed))
                .font(DayCellLayout.dataFont)
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity)
            Text(CalorieFormatter.whole(budget.burned))
                .font(DayCellLayout.dataFont)
                .foregroundStyle(exerciseColor)
                .frame(maxWidth: .infinity)
            remainingCell
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, DayCellLayout.horizontalPadding)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(budget.isBankingDay ? 0 : 0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            isToday ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.15),
                            lineWidth: isToday ? 1.5 : 1
                        )
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var dayStack: some View {
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
        .frame(width: DayCellLayout.dayColumnWidth)
    }

    @ViewBuilder
    private var remainingCell: some View {
        if let variance = varianceValue {
            let magnitude = abs(variance).formatted(.number)
            let color: Color = variance >= 0 ? .green : .red
            Text(magnitude)
                .font(DayCellLayout.dataFont)
                .foregroundStyle(color)
        } else {
            // Reserve column space on non-today rows so the header stays aligned.
            Color.clear.frame(height: 1)
        }
    }

    private var accessibilityLabel: String {
        var parts: [String] = [
            budget.weekday.fullName,
            "\(CalorieFormatter.whole(budget.consumed)) calories consumed",
            "exercise \(CalorieFormatter.whole(budget.burned))",
        ]
        if let variance = varianceValue {
            parts.append(variance >= 0
                ? "\(abs(variance)) kcal remaining today"
                : "\(abs(variance)) kcal over today")
        }
        return parts.joined(separator: ", ")
    }
}

/// Shared layout constants so `DayCellHeader` lines up exactly with each `DayCellView` column.
enum DayCellLayout {
    static let dayColumnWidth: CGFloat = 44
    static let columnSpacing: CGFloat = 12
    static let horizontalPadding: CGFloat = 14
    static let dataFont: Font = .system(size: 20, weight: .semibold).monospacedDigit()
}

/// Column-label header rendered above the week's day cells. Mirrors `DayCellView`'s HStack
/// structure (44-pt day slot + divider + three flex columns) so labels align with the
/// numbers below.
struct DayCellHeader: View {
    var body: some View {
        HStack(alignment: .center, spacing: DayCellLayout.columnSpacing) {
            Color.clear.frame(width: DayCellLayout.dayColumnWidth, height: 1)
            Divider().hidden()
            Text("Consumed")
                .frame(maxWidth: .infinity)
            Text("Exercise")
                .frame(maxWidth: .infinity)
            Text("Remaining")
                .frame(maxWidth: .infinity)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.horizontal, DayCellLayout.horizontalPadding)
    }
}
