import SwiftUI
import SwiftData

/// Settings → Manage Tags. Lists every `FoodTag` the user has created with the
/// number of foods currently carrying it. Tap a row to rename / recolor; swipe
/// to delete (always allowed — the relationship is auto-cleared from every
/// food via SwiftData's inverse handling, so deletion is non-destructive to the
/// food rows themselves).
struct TagManagementView: View {

    @Environment(\.modelContext) private var modelContext

    @Query(sort: \FoodTag.name) private var allTags: [FoodTag]

    @State private var editingTag: FoodTag?
    @State private var creatingTag: Bool = false
    @State private var pendingDelete: FoodTag?
    @State private var showDeleteConfirm: Bool = false

    var body: some View {
        List {
            if allTags.isEmpty {
                ContentUnavailableView(
                    "No tags yet",
                    systemImage: "tag",
                    description: Text("Tap + to create your first tag.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(allTags) { tag in
                    Button {
                        editingTag = tag
                    } label: {
                        HStack {
                            TagChipView(name: tag.name, color: tag.color)
                            Spacer()
                            Text("\(tag.foodsList.count)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            if tag.foodsList.isEmpty {
                                delete(tag)
                            } else {
                                pendingDelete = tag
                                showDeleteConfirm = true
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("Manage Tags")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    creatingTag = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New tag")
            }
        }
        .sheet(item: $editingTag) { tag in
            TagEditSheet(
                tag: tag,
                existingNames: allTags.map(\.name)
            ) { _ in }
        }
        .sheet(isPresented: $creatingTag) {
            TagEditSheet(
                tag: nil,
                existingNames: allTags.map(\.name)
            ) { _ in }
        }
        .confirmationDialog(
            confirmTitle,
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { tag in
            Button("Delete tag", role: .destructive) { delete(tag) }
            Button("Cancel", role: .cancel) { }
        } message: { tag in
            Text("\"\(tag.name)\" is on \(tag.foodsList.count) food\(tag.foodsList.count == 1 ? "" : "s"). Deleting it removes it from those foods. The foods themselves won't be deleted.")
        }
    }

    private var confirmTitle: String {
        guard let tag = pendingDelete else { return "Delete tag?" }
        return "Delete \"\(tag.name)\"?"
    }

    private func delete(_ tag: FoodTag) {
        // Detach from every food first so the inverse relationship is consistent
        // before SwiftData/CloudKit observes the delete. This avoids any stale
        // references on the food side mid-sync.
        for food in tag.foodsList {
            food.tags = food.tagsList.filter { $0.id != tag.id }
        }
        modelContext.delete(tag)
        try? modelContext.save()
    }
}
