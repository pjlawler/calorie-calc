import SwiftUI
import SwiftData

struct MealSectionView: View {

    let mealType: MealType
    let entries: [FoodEntry]
    let onAdd: () -> Void
    let onEdit: (FoodEntry) -> Void
    let onDelete: (FoodEntry) -> Void

    var body: some View {
        Section {
            if entries.isEmpty {
                Button(action: onAdd) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.tint)
                        Text("Add food")
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            } else {
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
                Button(action: onAdd) {
                    Label("Add food", systemImage: "plus.circle")
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
