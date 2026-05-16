import SwiftUI
import SwiftData

/// Daily-log section listing supplements/vitamins logged on this day. Sits below Workouts
/// when `UserProfile.tracksSupplements` is true. Collapsible via a header card that mirrors
/// the Workouts section's style — chevron, icon, title, count. Swipe-to-delete removes the
/// entry entirely (different semantics from the picker's hide-from-recents swipe).
struct SupplementSectionView: View {
    let entries: [SupplementEntry]
    let collapsed: Bool
    let onToggleCollapse: () -> Void
    let onAdd: () -> Void
    let onDelete: (SupplementEntry) -> Void

    var body: some View {
        Section {
            headerRow
            if !collapsed {
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
            }
        }
    }

    private var headerRow: some View {
        Button {
            onToggleCollapse()
        } label: {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 1)
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Image(systemName: "pills.fill")
                        .font(.headline)
                        .foregroundStyle(entries.isEmpty ? Color.secondary : .purple)
                        .frame(width: 22, alignment: .center)
                    Text("Supplements")
                        .font(.headline)
                        .foregroundStyle(entries.isEmpty ? .secondary : .primary)
                    Spacer()
                    if !entries.isEmpty {
                        Text("\(entries.count)")
                            .font(.subheadline.monospacedDigit().bold())
                            .foregroundStyle(.primary)
                    }
                }
                .padding(.vertical, 14)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
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
