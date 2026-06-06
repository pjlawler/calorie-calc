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

    // History filter — independent of Progress's `progress.timeframe` so the two
    // surfaces can scope to different ranges (you can view 90 days of weights
    // while the Progress chart is still on 7 days). We reuse the existing
    // ProgressTrendTimeframe enum but locally relabel `.custom` to "All dates"
    // and treat it as "no filter — show every entry."
    @AppStorage("weightLog.timeframe") private var timeframe: ProgressTrendTimeframe = .days30

    private var profile: UserProfile? { profiles.first }

    private var filteredEntries: [WeightEntry] {
        if timeframe == .custom { return entries }
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let endExclusive = cal.date(byAdding: .day, value: 1, to: today) ?? today
        let start: Date
        if timeframe == .thisWeek {
            let weekStart = profile?.weekStart ?? .monday
            start = weekStart.startOfWeek(containing: .now, calendar: cal)
        } else {
            let days = timeframe.daysBack ?? 30
            start = cal.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        }
        return entries.filter { $0.timestamp >= start && $0.timestamp < endExclusive }
    }

    private func timeframeLabel(_ tf: ProgressTrendTimeframe) -> String {
        tf == .custom ? "All dates" : tf.displayName
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
                        Picker("Range", selection: $timeframe) {
                            ForEach(ProgressTrendTimeframe.allCases) { tf in
                                Text(timeframeLabel(tf)).tag(tf)
                            }
                        }
                        .pickerStyle(.menu)

                        if filteredEntries.isEmpty {
                            Text("No weights logged in this range.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(filteredEntries) { entry in
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
            }
            .navigationTitle("Weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
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
        dismiss()
    }
}
