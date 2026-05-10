import SwiftUI
import SwiftData

/// Create-or-rename sheet for a single `FoodTag`. Used both for "+ New Tag"
/// (passing nil for `tag`) and for "edit existing" (passing the tag instance).
/// On save, calls `onSaved` with the persisted tag so the caller can attach it
/// or update its presentation immediately.
struct TagEditSheet: View {

    /// `nil` means create a new tag; non-nil means edit this one in place.
    let tag: FoodTag?
    /// Pre-populates the name field for the create flow — typed query from
    /// the picker's search box.
    var initialName: String = ""
    /// Disables Save when the trimmed name collides with an existing tag (other
    /// than `tag` itself). The caller supplies the existing names.
    let existingNames: [String]
    let onSaved: (FoodTag) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name: String = ""
    @State private var color: FoodTagColor = .blue

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameCollides: Bool {
        let lower = trimmedName.lowercased()
        return existingNames.contains { $0.lowercased() == lower && $0 != tag?.name }
    }
    private var canSave: Bool { !trimmedName.isEmpty && !nameCollides }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Thai Food", text: $name)
                        .textInputAutocapitalization(.words)
                    if nameCollides {
                        Text("A tag with that name already exists.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Section("Color") {
                    colorGrid
                        .padding(.vertical, 4)
                }
                Section {
                    TagChipView(name: trimmedName.isEmpty ? "Tag preview" : trimmedName, color: color)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                } header: {
                    Text("Preview")
                }
            }
            .navigationTitle(tag == nil ? "New Tag" : "Edit Tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear {
                if let tag {
                    name = tag.name
                    color = tag.color
                } else {
                    name = initialName
                }
            }
        }
    }

    /// 12-swatch grid; each swatch is tappable. The 4-column flow keeps the
    /// grid compact at any dynamic-type size without scrolling.
    private var colorGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(FoodTagColor.allCases, id: \.self) { swatch in
                Button { color = swatch } label: {
                    Circle()
                        .fill(swatch.swiftUIColor)
                        .frame(width: 32, height: 32)
                        .overlay(
                            Circle().strokeBorder(
                                color == swatch ? Color.primary : Color.clear,
                                lineWidth: 3
                            )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(swatch.rawValue))
            }
        }
    }

    private func save() {
        guard canSave else { return }
        if let tag {
            tag.name = trimmedName
            tag.color = color
            try? modelContext.save()
            onSaved(tag)
        } else {
            let newTag = FoodTag(name: trimmedName, color: color)
            modelContext.insert(newTag)
            try? modelContext.save()
            onSaved(newTag)
        }
        dismiss()
    }
}
