import SwiftUI
import SwiftData

struct SettingsView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(HealthKitService.self) private var healthKitService

    @Query private var profiles: [UserProfile]
    @Query(sort: \GoalPeriod.startDate) private var goalPeriods: [GoalPeriod]
    @Query(sort: \DayLog.date) private var dayLogs: [DayLog]
    @Query(sort: \FoodEntry.timestamp) private var foodEntries: [FoodEntry]
    @Query(sort: \ManualWorkout.timestamp) private var manualWorkouts: [ManualWorkout]
    @Query(sort: \WeightEntry.timestamp) private var weightEntries: [WeightEntry]
    @Query(sort: \CachedFood.lastUsed) private var cachedFoods: [CachedFood]

    @AppStorage(AppTab.defaultTabStorageKey) private var defaultTabRaw: String = AppTab.week.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage("settings.showSteps") private var showSteps: Bool = true

    @State private var viewModel: SettingsViewModel?
    @State private var draft: GoalDraft?
    @State private var isExportingCSV = false
    @State private var exportStatusMessage: String?
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            Group {
                if let profile = profiles.first, draft != nil {
                    SettingsForm(
                        profile: profile,
                        viewModel: viewModel,
                        draft: Binding(
                            get: { draft ?? GoalDraft(from: profile) },
                            set: { draft = $0 }
                        ),
                        defaultTabRaw: $defaultTabRaw,
                        appearanceRaw: $appearanceRaw,
                        showSteps: $showSteps,
                        onExportCSV: exportDatabaseCSV,
                        isExportingCSV: isExportingCSV,
                        exportStatusMessage: exportStatusMessage,
                        exportURL: exportURL
                    )
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        commitDraft()
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
            .task {
                if viewModel == nil {
                    viewModel = SettingsViewModel(healthKitService: healthKitService)
                }
                seedDraftIfNeeded()
            }
        }
    }

    private func seedDraftIfNeeded() {
        guard draft == nil else { return }
        // If Settings is the first view to run, bootstrap a period from the profile's *current*
        // values so subsequent commits can correctly split history from the edit going forward.
        // Without this, commitDraft's fallback would stamp the new draft over all of history.
        if let profile = profiles.first {
            GoalPeriod.ensureBootstrapped(in: modelContext, profile: profile, existing: goalPeriods)
        }
        if let current = GoalPeriod.current(in: goalPeriods) {
            draft = GoalDraft(from: current)
        } else if let profile = profiles.first {
            draft = GoalDraft(from: profile)
        }
    }

    /// If any of the five period-scoped fields changed, close the current period and open a new
    /// one starting at the first day of the current week (per the new `weekStart`). Also mirror
    /// the new values onto `UserProfile` so Dashboard bindings keep showing today's goals.
    private func commitDraft() {
        guard let draft, let profile = profiles.first else { return }
        // Fetch directly so we see any period bootstrapped in `seedDraftIfNeeded` — the `@Query`
        // may not have refreshed yet within the same render cycle.
        let latestPeriods = (try? modelContext.fetch(
            FetchDescriptor<GoalPeriod>(sortBy: [SortDescriptor(\.startDate)])
        )) ?? goalPeriods
        guard let current = GoalPeriod.current(in: latestPeriods) else {
            // Truly no current period — split immediately into a historical (pre-edit, from
            // profile) and a current (post-edit, from draft) so past weeks keep the old values
            // if the user ever gets here without an earlier bootstrap.
            let startOfWeek = Calendar.current.startOfWeek(for: .now, firstWeekday: draft.weekStart.calendarValue)
            if draft.differs(from: GoalDraft(from: profile)) {
                let historical = GoalPeriod(
                    startDate: profile.createdAt,
                    endDate: startOfWeek,
                    dailyNetCalorieGoal: profile.dailyNetCalorieGoal,
                    dailyGrossCalorieGoal: profile.dailyGrossCalorieGoal,
                    dailyWorkoutCalorieGoal: profile.dailyWorkoutCalorieGoal,
                    bankSplit: profile.bankSplit,
                    weekStart: profile.weekStart
                )
                modelContext.insert(historical)
            }
            let open = GoalPeriod(
                startDate: draft.differs(from: GoalDraft(from: profile)) ? startOfWeek : profile.createdAt,
                endDate: nil,
                dailyNetCalorieGoal: draft.dailyNetCalorieGoal,
                dailyGrossCalorieGoal: draft.dailyGrossCalorieGoal,
                dailyWorkoutCalorieGoal: draft.dailyWorkoutCalorieGoal,
                bankSplit: draft.bankSplit,
                weekStart: draft.weekStart
            )
            modelContext.insert(open)
            draft.mirror(onto: profile)
            return
        }
        guard draft.differs(from: current) else {
            // No goal changes — just mirror back in case pass-through was stale.
            draft.mirror(onto: profile)
            return
        }

        let startOfWeek = Calendar.current.startOfWeek(for: .now, firstWeekday: draft.weekStart.calendarValue)
        // If the user hasn't moved forward in time from the current period (edge case: changing
        // goals twice in one week), keep the same startDate and just overwrite the current
        // period's values. Otherwise close + open.
        if startOfWeek <= current.startDate {
            current.dailyNetCalorieGoal = draft.dailyNetCalorieGoal
            current.dailyGrossCalorieGoal = draft.dailyGrossCalorieGoal
            current.dailyWorkoutCalorieGoal = draft.dailyWorkoutCalorieGoal
            current.bankSplit = draft.bankSplit
            current.weekStart = draft.weekStart
        } else {
            current.endDate = startOfWeek
            let next = GoalPeriod(
                startDate: startOfWeek,
                endDate: nil,
                dailyNetCalorieGoal: draft.dailyNetCalorieGoal,
                dailyGrossCalorieGoal: draft.dailyGrossCalorieGoal,
                dailyWorkoutCalorieGoal: draft.dailyWorkoutCalorieGoal,
                bankSplit: draft.bankSplit,
                weekStart: draft.weekStart
            )
            modelContext.insert(next)
        }
        draft.mirror(onto: profile)
    }

    private func exportDatabaseCSV() {
        guard !isExportingCSV else { return }
        isExportingCSV = true
        defer { isExportingCSV = false }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func d(_ date: Date?) -> String {
            guard let date else { return "" }
            return formatter.string(from: date)
        }

        func csv(_ value: String) -> String {
            if value.contains(",") || value.contains("\"") || value.contains("\n") {
                return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
            return value
        }

        let header = [
            "record_type", "id", "day_log_id", "timestamp", "date", "name", "brand",
            "meal_type", "source", "calories", "protein", "carbs", "fat", "quantity",
            "duration_seconds", "calories_burned", "weight", "unit", "daily_net_goal",
            "daily_gross_goal", "daily_workout_goal", "bank_split", "week_start",
            "start_date", "end_date", "notes"
        ]

        var rows: [[String]] = [header]

        for profile in profiles {
            rows.append([
                "user_profile", profile.id.uuidString, "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
                String(profile.dailyNetCalorieGoal), String(profile.dailyGrossCalorieGoal), String(profile.dailyWorkoutCalorieGoal),
                profile.bankSplit.rawValue, "\(profile.weekStart.rawValue)", "", "", ""
            ])
        }

        for period in goalPeriods {
            rows.append([
                "goal_period", period.id.uuidString, "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
                String(period.dailyNetCalorieGoal), String(period.dailyGrossCalorieGoal), String(period.dailyWorkoutCalorieGoal),
                period.bankSplit.rawValue, "\(period.weekStart.rawValue)", d(period.startDate), d(period.endDate), ""
            ])
        }

        for log in dayLogs {
            rows.append([
                "day_log", log.id.uuidString, "", "", d(log.date), "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", ""
            ])
        }

        for entry in foodEntries {
            rows.append([
                "food_entry", entry.id.uuidString, entry.dayLog?.id.uuidString ?? "", d(entry.timestamp), "",
                entry.name, entry.brand ?? "", entry.mealType.rawValue, entry.source.rawValue,
                String(entry.caloriesPerServing), String(entry.proteinPerServing), String(entry.carbsPerServing),
                String(entry.fatPerServing), String(entry.quantity), "", "", "", "", "", "", "", "", "", "", "", entry.notes ?? ""
            ])
        }

        for workout in manualWorkouts {
            rows.append([
                "manual_workout", workout.id.uuidString, workout.dayLog?.id.uuidString ?? "", d(workout.timestamp), "",
                workout.name, "", "", "", "", "", "", "", "",
                String(workout.durationSeconds), String(workout.caloriesBurned), "", "", "", "", "", "", "", "", "", workout.notes ?? ""
            ])
        }

        for weight in weightEntries {
            rows.append([
                "weight_entry", weight.id.uuidString, "", d(weight.timestamp), "", "", "", "", "", "", "", "", "", "", "", "",
                String(weight.weight), weight.unit.rawValue, "", "", "", "", "", "", "", weight.notes ?? ""
            ])
        }

        for cached in cachedFoods {
            rows.append([
                "cached_food", cached.id.uuidString, "", d(cached.lastUsed), "", cached.name, cached.brand ?? "", "", cached.source.rawValue,
                String(cached.caloriesPerServing), String(cached.proteinPerServing), String(cached.carbsPerServing), String(cached.fatPerServing),
                "", "", "", "", "", "", "", "", "", "", "", "", cached.notes ?? ""
            ])
        }

        let text = rows.map { $0.map(csv).joined(separator: ",") }.joined(separator: "\n")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CalorieCalc-export-\(Int(Date().timeIntervalSince1970)).csv")

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            exportURL = url
            exportStatusMessage = "CSV generated. Tap Share CSV to save a copy."
        } catch {
            exportStatusMessage = "CSV export failed: \(error.localizedDescription)"
        }
    }
}

/// Transient copy of a `GoalPeriod`'s plan fields. The Settings sheet drives UI bindings against
/// this and only mutates the underlying model on Done — so a user can tweak several numbers in
/// one session without generating a new historical period for each tap.
struct GoalDraft: Equatable {
    var dailyNetCalorieGoal: Int
    var dailyGrossCalorieGoal: Int
    var dailyWorkoutCalorieGoal: Int
    var bankSplit: BankSplit
    var weekStart: Weekday

    init(from period: GoalPeriod) {
        dailyNetCalorieGoal = period.dailyNetCalorieGoal
        dailyGrossCalorieGoal = period.dailyGrossCalorieGoal
        dailyWorkoutCalorieGoal = period.dailyWorkoutCalorieGoal
        bankSplit = period.bankSplit
        weekStart = period.weekStart
    }

    init(from profile: UserProfile) {
        dailyNetCalorieGoal = profile.dailyNetCalorieGoal
        dailyGrossCalorieGoal = profile.dailyGrossCalorieGoal
        dailyWorkoutCalorieGoal = profile.dailyWorkoutCalorieGoal
        bankSplit = profile.bankSplit
        weekStart = profile.weekStart
    }

    func differs(from period: GoalPeriod) -> Bool {
        dailyNetCalorieGoal != period.dailyNetCalorieGoal
            || dailyGrossCalorieGoal != period.dailyGrossCalorieGoal
            || dailyWorkoutCalorieGoal != period.dailyWorkoutCalorieGoal
            || bankSplit != period.bankSplit
            || weekStart != period.weekStart
    }

    func differs(from other: GoalDraft) -> Bool { self != other }

    /// Mirrors the draft onto `UserProfile` so views that still bind to the profile (Dashboard
    /// planCard, legacy readers) see today's goals without needing to know about periods.
    func mirror(onto profile: UserProfile) {
        profile.dailyNetCalorieGoal = dailyNetCalorieGoal
        profile.dailyGrossCalorieGoal = dailyGrossCalorieGoal
        profile.dailyWorkoutCalorieGoal = dailyWorkoutCalorieGoal
        profile.bankSplit = bankSplit
        profile.weekStart = weekStart
        profile.updatedAt = .now
    }
}

private struct SettingsForm: View {
    @Bindable var profile: UserProfile
    let viewModel: SettingsViewModel?
    @Binding var draft: GoalDraft
    @Binding var defaultTabRaw: String
    @Binding var appearanceRaw: String
    @Binding var showSteps: Bool
    let onExportCSV: () -> Void
    let isExportingCSV: Bool
    let exportStatusMessage: String?
    let exportURL: URL?

    private var defaultTab: AppTab {
        get { AppTab(rawValue: defaultTabRaw) ?? .week }
    }

    var body: some View {
        Form {
            Section {
                Picker("Launch to", selection: Binding(
                    get: { AppTab(rawValue: defaultTabRaw) ?? .week },
                    set: { defaultTabRaw = $0.rawValue }
                )) {
                    ForEach(AppTab.allCases) { tab in
                        Label(tab.displayName, systemImage: tab.systemImage).tag(tab)
                    }
                }
                Picker("Appearance", selection: Binding(
                    get: { AppAppearance(rawValue: appearanceRaw) ?? .system },
                    set: { newValue in
                        appearanceRaw = newValue.rawValue
                        AppAppearance.apply(newValue)
                    }
                )) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Launch tab and light/dark mode.")
            }

            Section {
                Stepper(value: $draft.dailyNetCalorieGoal, in: 800...5000, step: 50) {
                    LabeledContent("Daily net") { Text("\(draft.dailyNetCalorieGoal) kcal").monospacedDigit() }
                }
                Stepper(value: $draft.dailyGrossCalorieGoal, in: 800...6000, step: 50) {
                    LabeledContent("Daily gross (plan days)") { Text("\(draft.dailyGrossCalorieGoal) kcal").monospacedDigit() }
                }
                Stepper(value: $draft.dailyWorkoutCalorieGoal, in: 0...3000, step: 25) {
                    LabeledContent("Daily workout goal") { Text("\(draft.dailyWorkoutCalorieGoal) kcal").monospacedDigit() }
                }
            } header: {
                Text("Calorie goals")
            } footer: {
                Text("Changes apply to the current week and going forward. Historical weeks keep the goals that were in effect at the time.")
            }

            Section {
                Picker("Week split", selection: $draft.bankSplit) {
                    ForEach(BankSplit.allCases, id: \.self) { split in
                        Text(split.displayName).tag(split)
                    }
                }
                Picker("Week starts on", selection: $draft.weekStart) {
                    ForEach(Weekday.allCases) { day in
                        Text(day.shortName).tag(day)
                    }
                }
                BankingDaysPreview(weekStart: draft.weekStart, bankSplit: draft.bankSplit)
            } header: {
                Text("Week shape")
            } footer: {
                Text("Plan days are the first \(draft.bankSplit.bankingDayCount) days of your week. Flex days are the rest.")
            }

            Section("Units") {
                Picker("Weight", selection: $profile.weightUnit) {
                    ForEach(WeightUnit.allCases, id: \.self) { unit in
                        Text(unit.suffix).tag(unit)
                    }
                }
                LabeledContent("Energy") { Text(profile.energyUnit.suffix) }
            }

            Section("Weight") {
                if let weight = profile.startingWeight {
                    LabeledContent("Starting") {
                        Text(CalorieFormatter.weight(weight, unit: profile.weightUnit))
                            .monospacedDigit()
                    }
                    Button("Clear starting weight", role: .destructive) {
                        profile.startingWeight = nil
                        profile.startingWeightLoggedAt = nil
                    }
                } else {
                    Text("Log a weight on My Plan to set your starting weight.")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }

                GoalWeightField(profile: profile)
            }

            Section("Apple Health") {
                switch viewModel?.healthKitStatus {
                case .authorized:
                    Label("Authorized", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .denied:
                    Label("Denied — enable in Settings", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                case .unavailable:
                    Label("Not available on this device", systemImage: "heart.slash")
                        .foregroundStyle(.secondary)
                default:
                    Button {
                        Task { await viewModel?.requestHealthKit() }
                    } label: {
                        Label("Request access", systemImage: "heart")
                    }
                }
                if let error = viewModel?.healthKitError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }

                Toggle("Show step count", isOn: $showSteps)
            }

            #if DEBUG
            Section {
                Button {
                    onExportCSV()
                } label: {
                    HStack {
                        if isExportingCSV {
                            ProgressView().controlSize(.small)
                        }
                        Text("Generate CSV export")
                    }
                }
                .disabled(isExportingCSV)

                if let exportURL {
                    ShareLink("Share CSV", item: exportURL)
                }

                if let exportStatusMessage {
                    Text(exportStatusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Debug")
            } footer: {
                Text("Visible only in debug builds.")
            }
            #endif
        }
    }

}

private struct BankingDaysPreview: View {
    let weekStart: Weekday
    let bankSplit: BankSplit

    private var ordered: [Weekday] {
        Weekday.allCases.sorted { a, b in
            let normA = (a.rawValue - weekStart.rawValue + 7) % 7
            let normB = (b.rawValue - weekStart.rawValue + 7) % 7
            return normA < normB
        }
    }

    private func isBanking(_ day: Weekday) -> Bool {
        let offset = (day.rawValue - weekStart.rawValue + 7) % 7
        return offset < bankSplit.bankingDayCount
    }

    private var bankingDays: [Weekday] {
        Weekday.allCases.filter(isBanking)
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ordered) { day in
                let banking = isBanking(day)
                Text(day.shortName.prefix(1))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(banking ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
                    )
                    .foregroundStyle(banking ? Color.accentColor : .secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityLabel(
            "Plan days: \(bankingDays.sorted { $0.rawValue < $1.rawValue }.map(\.fullName).joined(separator: ", "))"
        )
    }
}

private struct GoalWeightField: View {
    @Bindable var profile: UserProfile
    @State private var text: String = ""

    var body: some View {
        HStack {
            Text("Goal")
            Spacer()
            TextField("e.g., 170", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(maxWidth: 100)
            Text(profile.weightUnit.suffix)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            if let goal = profile.goalWeight {
                text = goal.formatted(.number.precision(.fractionLength(0...1)))
            }
        }
        .onChange(of: text) { _, newValue in
            profile.goalWeight = Double(newValue)
        }
    }
}
