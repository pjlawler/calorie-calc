import SwiftUI
import SwiftData

/// Edit a `CachedFood`'s name, brand, and per-native-unit macros directly. Used from the
/// Foods tab's My Foods list — lets users curate their saved catalog without re-logging
/// or re-saving from a search result.
struct EditCachedFoodSheet: View {

    @Bindable var food: CachedFood

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var nameText: String = ""
    @State private var brandText: String = ""
    @State private var caloriesText: String = ""
    @State private var proteinText: String = ""
    @State private var carbsText: String = ""
    @State private var fatText: String = ""
    @State private var notesText: String = ""

    private var canSave: Bool {
        !nameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && (Double(caloriesText) ?? -1) >= 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Food") {
                    TextField("Name", text: $nameText)
                        .textInputAutocapitalization(.words)
                    TextField("Brand (optional)", text: $brandText)
                        .textInputAutocapitalization(.words)
                }

                Section {
                    macroField(label: "Calories", text: $caloriesText, suffix: "kcal")
                    macroField(label: "Protein", text: $proteinText, suffix: "g")
                    macroField(label: "Carbs", text: $carbsText, suffix: "g")
                    macroField(label: "Fat", text: $fatText, suffix: "g")
                } header: {
                    Text("Per 1 \(food.nativeUnit)")
                } footer: {
                    Text("Edits the per-serving values used everywhere this food is logged in the future. Already-logged entries are unchanged.")
                }

                Section("Notes") {
                    TextField("Notes — prep, source, tweaks…", text: $notesText, axis: .vertical)
                        .lineLimit(2...6)
                }
            }
            .navigationTitle("Edit Food")
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
                nameText = food.name
                brandText = food.brand ?? ""
                caloriesText = trimmed(food.caloriesPerServing)
                proteinText = trimmed(food.proteinPerServing)
                carbsText = trimmed(food.carbsPerServing)
                fatText = trimmed(food.fatPerServing)
                notesText = food.notes ?? ""
            }
        }
    }

    private func macroField(label: String, text: Binding<String>, suffix: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(maxWidth: 100)
            Text(suffix)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
        }
    }

    private func save() {
        let trimmedName = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        food.name = trimmedName
        let trimmedBrand = brandText.trimmingCharacters(in: .whitespacesAndNewlines)
        food.brand = trimmedBrand.isEmpty ? nil : trimmedBrand
        food.caloriesPerServing = Double(caloriesText) ?? 0
        food.proteinPerServing = Double(proteinText) ?? 0
        food.carbsPerServing = Double(carbsText) ?? 0
        food.fatPerServing = Double(fatText) ?? 0
        let trimmedNotes = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
        food.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        try? modelContext.save()
        dismiss()
    }

    private func trimmed(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }
}
