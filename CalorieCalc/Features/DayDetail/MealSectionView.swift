import SwiftUI
import SwiftData

struct MealSectionView: View {

    let mealType: MealType
    let entries: [FoodEntry]
    let totalProtein: Double
    let totalCarbs: Double
    let totalFat: Double
    let isCollapsed: Bool
    let showTopDivider: Bool
    let onToggleCollapse: () -> Void
    let onEdit: (FoodEntry) -> Void
    let onDelete: (FoodEntry) -> Void

    var body: some View {
        Section {
            // Title row sits inline (not in `header:`) so we control top/bottom insets
            // ourselves — SwiftUI's default section header adds asymmetric padding we
            // can't override.
            Button {
                withAnimation(.snappy) { onToggleCollapse() }
            } label: {
                VStack(spacing: 0) {
                    if showTopDivider {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.3))
                            .frame(height: 1)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        Image(systemName: mealType.symbolName)
                            .font(.headline)
                            .foregroundStyle(entries.isEmpty ? Color.secondary : Color.accentColor)
                            .frame(width: 22, alignment: .center)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mealType.displayName)
                                .font(.headline)
                                .foregroundStyle(entries.isEmpty ? .secondary : .primary)
                            HStack(spacing: 10) {
                                macroBadge(letter: "P", grams: totalProtein, color: HistoryMetric.protein.color, isEmpty: entries.isEmpty)
                                macroBadge(letter: "C", grams: totalCarbs, color: HistoryMetric.carbs.color, isEmpty: entries.isEmpty)
                                macroBadge(letter: "F", grams: totalFat, color: HistoryMetric.fat.color, isEmpty: entries.isEmpty)
                            }
                        }
                        Spacer()
                        Text("\(CalorieFormatter.whole(totalCalories)) kcal")
                            .font(.subheadline.monospacedDigit().bold())
                            .foregroundStyle(entries.isEmpty ? .secondary : .primary)
                    }
                    .padding(.vertical, 14)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(mealType.displayName), \(isCollapsed ? "collapsed" : "expanded")")
            .accessibilityHint("Double-tap to \(isCollapsed ? "expand" : "collapse")")

            if !isCollapsed {
                ForEach(entries) { entry in
                    Button { onEdit(entry) } label: {
                        FoodEntryRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            onDelete(entry)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private var totalCalories: Double {
        entries.reduce(0) { $0 + $1.totalCalories }
    }

    private func macroBadge(letter: String, grams: Double, color: Color, isEmpty: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isEmpty ? color.opacity(0.35) : color)
                .frame(width: 8, height: 8)
            Text("\(letter) \(Int(grams.rounded()))g")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(isEmpty ? .secondary : .primary)
        }
    }
}

private struct FoodEntryRow: View {
    let entry: FoodEntry

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.body)
                    .lineLimit(1)
                if let brand = entry.brand, !brand.isEmpty {
                    Text(brand)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(CalorieFormatter.whole(entry.totalCalories)) kcal")
                    .font(.subheadline.monospacedDigit())
                Text(entry.consumedDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
