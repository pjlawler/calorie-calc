import SwiftUI
import SwiftData

/// Daily-log section listing supplements/vitamins logged on this day. Sits between Snacks
/// and Workouts when `UserProfile.tracksSupplements` is true. Swipe-to-delete removes the
/// entry entirely (different semantics from the picker's hide-from-recents swipe).
struct SupplementSectionView: View {
    let entries: [SupplementEntry]
    let onAdd: () -> Void
    let onDelete: (SupplementEntry) -> Void

    var body: some View {
        Section {
            ForEach(entries) { entry in
                SupplementRow(entry: entry)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            onDelete(entry)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
            Button {
                onAdd()
            } label: {
                Label("Add supplement", systemImage: "plus.circle")
            }
        } header: {
            Label("Supplements", systemImage: "pills.fill")
                .font(.headline)
        }
    }
}

private struct SupplementRow: View {
    let entry: SupplementEntry

    var body: some View {
        HStack {
            Image(systemName: "pills.fill")
                .foregroundStyle(.purple)
            Text(entry.name)
            Spacer()
            Text(entry.doseDisplay)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}
