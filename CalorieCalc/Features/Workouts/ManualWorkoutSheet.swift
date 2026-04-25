import SwiftUI
import SwiftData

struct ManualWorkoutSheet: View {

    let date: Date

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var dayLogs: [DayLog]

    @State private var name: String = ""
    @State private var durationMinutes: Int = 30
    @State private var caloriesBurned: Double = 250
    @State private var notes: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Activity") {
                    TextField("Name (e.g., Running)", text: $name)
                        .textInputAutocapitalization(.words)
                }
                Section("Duration") {
                    Stepper(value: $durationMinutes, in: 1...600, step: 5) {
                        HStack { Text("Minutes"); Spacer(); Text("\(durationMinutes)").monospacedDigit() }
                    }
                }
                Section("Calories burned") {
                    HStack {
                        Slider(value: $caloriesBurned, in: 0...2000, step: 10)
                        Text("\(CalorieFormatter.whole(caloriesBurned))")
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Log Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let log = ensureDayLog()
        let workout = ManualWorkout(
            name: name.trimmingCharacters(in: .whitespaces),
            durationSeconds: durationMinutes * 60,
            caloriesBurned: caloriesBurned,
            notes: notes.isEmpty ? nil : notes,
            timestamp: date,
            dayLog: log
        )
        modelContext.insert(workout)
        try? modelContext.save()
        dismiss()
    }

    private func ensureDayLog() -> DayLog {
        let day = Calendar.current.startOfDay(for: date)
        if let existing = DayLog.preferredForDay(dayLogs, on: day) {
            return existing
        }
        let new = DayLog(date: day)
        modelContext.insert(new)
        return new
    }
}
