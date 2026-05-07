import SwiftUI
import SwiftData

struct WeightLogView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\WeightEntry.timestamp, order: .reverse)])
    private var entries: [WeightEntry]

    @Query private var profiles: [UserProfile]

    @State private var inputText: String = ""
    @State private var selectedUnit: WeightUnit = .pounds
    @State private var selectedDate: Date = .now

    private var profile: UserProfile? { profiles.first }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WeightHistoryView(entries: entries, displayUnit: profile?.weightUnit ?? .pounds)
                    .frame(height: 220)
                    .padding(.horizontal)
                    .padding(.top, 8)

                Form {
                    Section("New entry") {
                        HStack {
                            TextField("Weight", text: $inputText)
                                .keyboardType(.decimalPad)
                                .monospacedDigit()
                            Picker("Unit", selection: $selectedUnit) {
                                ForEach(WeightUnit.allCases, id: \.self) { unit in
                                    Text(unit.suffix).tag(unit)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 120)
                        }
                        DatePicker(
                            "Date",
                            selection: $selectedDate,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                        Button {
                            save()
                        } label: {
                            Text("Log weight")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(Double(inputText) == nil)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }

                    Section("History") {
                        ForEach(entries) { entry in
                            HStack {
                                Text(entry.timestamp.formatted(.dateTime.month().day().year()))
                                Spacer()
                                Text(CalorieFormatter.weight(entry.weight(in: profile?.weightUnit ?? entry.unit), unit: profile?.weightUnit ?? entry.unit))
                                    .monospacedDigit()
                            }
                            .font(.subheadline)
                            .swipeActions {
                                Button(role: .destructive) {
                                    modelContext.delete(entry)
                                    try? modelContext.save()
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if let profile { selectedUnit = profile.weightUnit }
            }
        }
    }

    private func save() {
        guard let value = Double(inputText) else { return }
        let entry = WeightEntry(weight: value, unit: selectedUnit, timestamp: selectedDate)
        modelContext.insert(entry)
        if profile?.startingWeight == nil {
            profile?.startingWeight = profile?.weightUnit == selectedUnit
                ? value
                : selectedUnit.convert(value, to: profile?.weightUnit ?? selectedUnit)
            profile?.startingWeightLoggedAt = selectedDate
        }
        try? modelContext.save()
        inputText = ""
        selectedDate = .now
    }
}
