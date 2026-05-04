import SwiftUI
import SwiftData

/// Modal for logging vitamins/supplements on a given day. Top section lists distinct
/// (name, dose, unit) triples from prior entries — tap to toggle a tick mark for batch
/// logging. Bottom section is the add-new form. The CTA logs every selected recent + the
/// new entry (when filled in). Swipe on a recent hides the triple from this list but
/// leaves historical entries intact.
struct SupplementPickerSheet: View {
    let date: Date
    let onLogged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var dayLogs: [DayLog]
    @Query(sort: \SupplementEntry.timestamp, order: .reverse) private var allEntries: [SupplementEntry]

    @State private var newName: String = ""
    @State private var newAmountText: String = ""
    @State private var newUnit: String = "mg"
    @State private var selectedRecentKeys: Set<String> = []

    /// Distinct (name, dose, unit) triples drawn from past entries. Most-recent log per
    /// triple wins ordering and decides whether the row is hidden — re-logging a hidden
    /// supplement re-surfaces it in the recents list.
    private var recents: [Recent] {
        var seen: [String: Recent] = [:]
        var order: [String] = []
        for entry in allEntries {
            let key = recentKey(name: entry.name, dose: entry.dose, unit: entry.doseUnit)
            if seen[key] == nil {
                seen[key] = Recent(
                    key: key,
                    name: entry.name,
                    dose: entry.dose,
                    doseUnit: entry.doseUnit,
                    isHidden: entry.hiddenFromRecents
                )
                order.append(key)
            }
        }
        return order.compactMap { seen[$0] }.filter { !$0.isHidden }
    }

    private var newAmount: Double? {
        Double(newAmountText.replacingOccurrences(of: ",", with: "."))
    }

    /// New-entry form is fillable when name is non-empty AND amount > 0.
    private var canLogNew: Bool {
        !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (newAmount ?? 0) > 0
    }

    /// CTA enables when the user has either ticked a recent or filled out the new-entry form.
    private var canLog: Bool {
        !selectedRecentKeys.isEmpty || canLogNew
    }

    var body: some View {
        NavigationStack {
            Form {
                if !recents.isEmpty {
                    Section {
                        ForEach(recents) { recent in
                            Button {
                                toggleSelection(recent)
                            } label: {
                                HStack {
                                    Image(systemName: selectedRecentKeys.contains(recent.key) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedRecentKeys.contains(recent.key) ? Color.accentColor : Color.secondary)
                                    Text(recent.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(recent.doseDisplay)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    hideRecent(recent)
                                } label: {
                                    Label("Hide", systemImage: "eye.slash")
                                }
                            }
                        }
                    } header: {
                        Text("Recents")
                    } footer: {
                        Text("Tap to select one or more. Swipe to hide from this list — past entries are kept.")
                    }
                }

                Section {
                    TextField("Name (e.g. B12)", text: $newName)
                        .textInputAutocapitalization(.words)
                    LabeledContent("Dose") {
                        HStack(spacing: 8) {
                            TextField("Amount", text: $newAmountText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .frame(minWidth: 60)
                            Picker("Unit", selection: $newUnit) {
                                ForEach(SupplementEntry.unitOptions, id: \.self) { unit in
                                    Text(unit).tag(unit)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }
                } header: {
                    Text(recents.isEmpty ? "Add" : "Add new")
                }

                Section {
                    Button { logSelected() } label: {
                        Text("Log Supplement(s)")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canLog)
                }
            }
            .navigationTitle("Add Supplement(s)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Actions

    private func toggleSelection(_ recent: Recent) {
        if selectedRecentKeys.contains(recent.key) {
            selectedRecentKeys.remove(recent.key)
        } else {
            selectedRecentKeys.insert(recent.key)
        }
    }

    /// Log every ticked recent + the new-entry form (if filled). Inserts use the same
    /// timestamp so the day-log row order respects pick sequence rather than randomizing.
    private func logSelected() {
        guard canLog else { return }
        let recentsByKey = Dictionary(uniqueKeysWithValues: recents.map { ($0.key, $0) })
        for key in selectedRecentKeys {
            guard let recent = recentsByKey[key] else { continue }
            insertEntry(name: recent.name, dose: recent.dose, doseUnit: recent.doseUnit)
        }
        if canLogNew, let amount = newAmount {
            let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            insertEntry(name: trimmedName, dose: amount, doseUnit: newUnit)
        }
        dismiss()
        onLogged()
    }

    private func insertEntry(name: String, dose: Double, doseUnit: String) {
        let log = ensureDayLog()
        let entry = SupplementEntry(
            name: name,
            dose: dose,
            doseUnit: doseUnit,
            hiddenFromRecents: false,
            timestamp: .now,
            dayLog: log
        )
        modelContext.insert(entry)
        try? modelContext.save()
    }

    /// Flip `hiddenFromRecents` on every matching past entry so the triple stops surfacing.
    /// A future log with the same triple will land with the default `false`, making it
    /// reappear — that's why this hides ALL past entries, not just one.
    private func hideRecent(_ recent: Recent) {
        for entry in allEntries where recentKey(name: entry.name, dose: entry.dose, unit: entry.doseUnit) == recent.key {
            entry.hiddenFromRecents = true
        }
        try? modelContext.save()
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

    private func recentKey(name: String, dose: Double, unit: String) -> String {
        "\(name.lowercased())|\(dose)|\(unit.lowercased())"
    }
}

private struct Recent: Identifiable, Hashable {
    let key: String
    let name: String
    let dose: Double
    let doseUnit: String
    let isHidden: Bool

    var id: String { key }

    var doseDisplay: String {
        let amount: String = dose.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(dose))
            : dose.formatted(.number.precision(.fractionLength(0...2)))
        return "\(amount) \(doseUnit)"
    }
}
