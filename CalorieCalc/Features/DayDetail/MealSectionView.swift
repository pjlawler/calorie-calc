import SwiftUI
import SwiftData

struct MealSectionView: View {

    let mealType: MealType
    let entries: [FoodEntry]
    let onEdit: (FoodEntry) -> Void
    let onDelete: (FoodEntry) -> Void

    var body: some View {
        Section {
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
        } header: {
            HStack {
                Label(mealType.displayName, systemImage: mealType.symbolName)
                    .font(.headline)
                Spacer()
                Text("\(CalorieFormatter.whole(totalCalories)) kcal")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var totalCalories: Double {
        entries.reduce(0) { $0 + $1.totalCalories }
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
