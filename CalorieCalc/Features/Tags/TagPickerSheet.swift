import SwiftUI
import SwiftData

/// Sheet for selecting which `FoodTag`s are attached to a target. Operates on a
/// `Set<UUID>` binding so callers can use it both for live editing of an existing
/// `CachedFood` (binding mutates `food.tags` directly) and for staging selections
/// that will be applied later when a `CachedFood` is finally upserted (binding
/// mutates a `@State` set in the host sheet).
struct TagPickerSheet: View {

    @Binding var selectedIds: Set<UUID>

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \FoodTag.name) private var allTags: [FoodTag]

    @State private var query: String = ""
    @State private var creatingTag: Bool = false
    @State private var newTagSeed: String = ""

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredTags: [FoodTag] {
        guard !trimmedQuery.isEmpty else { return allTags }
        let lower = trimmedQuery.lowercased()
        return allTags.filter { $0.name.lowercased().contains(lower) }
    }

    private var hasExactMatch: Bool {
        let lower = trimmedQuery.lowercased()
        return allTags.contains { $0.name.lowercased() == lower }
    }

    var body: some View {
        NavigationStack {
            List {
                if !trimmedQuery.isEmpty && !hasExactMatch {
                    Section {
                        Button {
                            newTagSeed = trimmedQuery
                            creatingTag = true
                        } label: {
                            Label("Create \u{201C}\(trimmedQuery)\u{201D}", systemImage: "plus.circle.fill")
                        }
                    }
                }

                if filteredTags.isEmpty && trimmedQuery.isEmpty {
                    ContentUnavailableView(
                        "No tags yet",
                        systemImage: "tag",
                        description: Text("Create your first tag to start grouping foods.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(filteredTags) { tag in
                            tagRow(tag)
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search tags")
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newTagSeed = ""
                        creatingTag = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New tag")
                }
            }
            .sheet(isPresented: $creatingTag) {
                TagEditSheet(
                    tag: nil,
                    initialName: newTagSeed,
                    existingNames: allTags.map(\.name)
                ) { created in
                    selectedIds.insert(created.id)
                    query = ""
                }
            }
        }
    }

    @ViewBuilder
    private func tagRow(_ tag: FoodTag) -> some View {
        let attached = selectedIds.contains(tag.id)
        Button {
            if attached {
                selectedIds.remove(tag.id)
            } else {
                selectedIds.insert(tag.id)
            }
        } label: {
            HStack {
                TagChipView(name: tag.name, color: tag.color, isSelected: attached)
                Spacer()
                if attached {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
