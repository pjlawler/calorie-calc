import SwiftUI

/// Reusable visual for a `FoodTag` — a small coloured dot followed by the tag
/// name. Used everywhere a tag is rendered: picker rows, food-edit chips,
/// filter bars, the tag-management list. Optional trailing close button is
/// provided by the call site (chip-removal in the edit sheet); the view here
/// keeps to read-only rendering so it composes into any context.
struct TagChipView: View {
    let name: String
    let color: FoodTagColor
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color.swiftUIColor)
                .frame(width: 10, height: 10)
            Text(name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(isSelected
                    ? color.swiftUIColor.opacity(0.18)
                    : Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    isSelected ? color.swiftUIColor.opacity(0.6) : Color.clear,
                    lineWidth: 1
                )
        )
    }
}
