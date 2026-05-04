import SwiftUI
import SwiftData
import UniformTypeIdentifiers

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

    /// Validation alert state. The user taps Done; if the plan has issues, we show this and
    /// only commit when they explicitly choose to proceed.
    @State private var pendingValidation: PlanValidator.Result?
    @State private var showValidationAlert = false

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
                    Button("Done") { handleDoneTap() }
                }
            }
            .task {
                if viewModel == nil {
                    viewModel = SettingsViewModel(healthKitService: healthKitService)
                }
                seedDraftIfNeeded()
            }
            .alert(validationAlertTitle, isPresented: $showValidationAlert, presenting: pendingValidation) { result in
                if result.severity == .error {
                    // Errors: math is broken. Default action is to go back and fix; allow
                    // "Save anyway" as a destructive escape hatch in case the user truly knows
                    // what they're doing.
                    Button("Go back", role: .cancel) { pendingValidation = nil }
                    Button("Save anyway", role: .destructive) { commitAndDismiss() }
                } else {
                    // Cautions: math works, just unusual. Save is the affirmative default.
                    Button("Cancel", role: .cancel) { pendingValidation = nil }
                    Button("Save") { commitAndDismiss() }
                }
            } message: { result in
                Text(result.issues.map(\.message).joined(separator: "\n\n"))
            }
        }
    }

    private var validationAlertTitle: String {
        guard let severity = pendingValidation?.severity else { return "" }
        return severity == .error ? "The math doesn't work" : "Heads up"
    }

    private func handleDoneTap() {
        guard let draft else { commitAndDismiss(); return }
        let result = PlanValidator.validate(draft: draft)
        if result.hasIssues {
            pendingValidation = result
            showValidationAlert = true
        } else {
            commitAndDismiss()
        }
    }

    private func commitAndDismiss() {
        commitDraft()
        try? modelContext.save()
        dismiss()
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

        // Lossless export: appends `native_unit` / `native_unit_grams` / `native_unit_ml` /
        // `selected_unit` columns. Older importers ignore unknown columns; the importer here
        // keys by header so column order is irrelevant for round-tripping.
        let header = [
            "record_type", "id", "day_log_id", "timestamp", "date", "name", "brand",
            "meal_type", "source", "calories", "protein", "carbs", "fat", "quantity",
            "duration_seconds", "calories_burned", "weight", "unit", "daily_net_goal",
            "daily_gross_goal", "daily_workout_goal", "bank_split", "week_start",
            "start_date", "end_date", "notes",
            "native_unit", "native_unit_grams", "native_unit_ml", "selected_unit"
        ]

        var rows: [[String]] = [header]

        // Helper for the trailing four serving columns — append them to a row that already has
        // the 26 base columns filled in.
        func append(_ row: [String], native: String? = nil, nativeGrams: Double? = nil, nativeMl: Double? = nil, selected: String? = nil) {
            var copy = row
            copy.append(native ?? "")
            copy.append(nativeGrams.map { String($0) } ?? "")
            copy.append(nativeMl.map { String($0) } ?? "")
            copy.append(selected ?? "")
            rows.append(copy)
        }

        for profile in profiles {
            append([
                "user_profile", profile.id.uuidString, "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
                String(profile.dailyNetCalorieGoal), String(profile.dailyGrossCalorieGoal), String(profile.dailyWorkoutCalorieGoal),
                profile.bankSplit.rawValue, "\(profile.weekStart.rawValue)", "", "", ""
            ])
        }

        for period in goalPeriods {
            append([
                "goal_period", period.id.uuidString, "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
                String(period.dailyNetCalorieGoal), String(period.dailyGrossCalorieGoal), String(period.dailyWorkoutCalorieGoal),
                period.bankSplit.rawValue, "\(period.weekStart.rawValue)", d(period.startDate), d(period.endDate), ""
            ])
        }

        for log in dayLogs {
            append([
                "day_log", log.id.uuidString, "", "", d(log.date), "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", ""
            ])
        }

        for entry in foodEntries {
            append([
                "food_entry", entry.id.uuidString, entry.dayLog?.id.uuidString ?? "", d(entry.timestamp), "",
                entry.name, entry.brand ?? "", entry.mealType.rawValue, entry.source.rawValue,
                String(entry.caloriesPerServing), String(entry.proteinPerServing), String(entry.carbsPerServing),
                String(entry.fatPerServing), String(entry.quantity), "", "", "", "", "", "", "", "", "", "", "", entry.notes ?? ""
            ],
            native: entry.nativeUnit,
            nativeGrams: entry.nativeUnitGrams,
            nativeMl: entry.nativeUnitMilliliters,
            selected: entry.selectedUnit)
        }

        for workout in manualWorkouts {
            append([
                "manual_workout", workout.id.uuidString, workout.dayLog?.id.uuidString ?? "", d(workout.timestamp), "",
                workout.name, "", "", "", "", "", "", "", "",
                String(workout.durationSeconds), String(workout.caloriesBurned), "", "", "", "", "", "", "", "", "", workout.notes ?? ""
            ])
        }

        for weight in weightEntries {
            append([
                "weight_entry", weight.id.uuidString, "", d(weight.timestamp), "", "", "", "", "", "", "", "", "", "", "", "",
                String(weight.weight), weight.unit.rawValue, "", "", "", "", "", "", "", weight.notes ?? ""
            ])
        }

        for cached in cachedFoods {
            append([
                "cached_food", cached.id.uuidString, "", d(cached.lastUsed), "", cached.name, cached.brand ?? "", "", cached.source.rawValue,
                String(cached.caloriesPerServing), String(cached.proteinPerServing), String(cached.carbsPerServing), String(cached.fatPerServing),
                "", "", "", "", "", "", "", "", "", "", "", "", cached.notes ?? ""
            ],
            native: cached.nativeUnit,
            nativeGrams: cached.nativeUnitGrams,
            nativeMl: cached.nativeUnitMilliliters,
            selected: cached.lastSelectedUnit)
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

    @Environment(\.modelContext) private var modelContext
    @State private var showImporter = false
    @State private var importStatusMessage: String?
    @State private var showWipeConfirm = false
    @State private var pendingImportURL: URL?

    @State private var snapshots: [BackupService.Snapshot] = []
    @State private var backupStatusMessage: String?
    @State private var pendingRestore: BackupService.Snapshot?
    @State private var showRestoreConfirm = false
    @State private var showRelaunchPrompt = false
    @State private var migrationStatusMessage: String?

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
                // Week shape comes first so the bank/bonus split is set before the user dials
                // in calorie targets — the targets only make sense once the shape is decided.
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

                Stepper(value: $draft.dailyNetCalorieGoal, in: 800...5000, step: 50) {
                    LabeledContent("Daily net") { Text("\(draft.dailyNetCalorieGoal) kcal").monospacedDigit() }
                }
                Stepper(value: $draft.dailyGrossCalorieGoal, in: 800...6000, step: 50) {
                    LabeledContent("Daily gross (bank days)") { Text("\(draft.dailyGrossCalorieGoal) kcal").monospacedDigit() }
                }
                Stepper(value: $draft.dailyWorkoutCalorieGoal, in: 0...3000, step: 25) {
                    LabeledContent("Daily workout goal") { Text("\(draft.dailyWorkoutCalorieGoal) kcal").monospacedDigit() }
                }
            } header: {
                Text("My Plan")
            } footer: {
                Text("Bank days are the first \(draft.bankSplit.bankingDayCount) days of your week — tighter targets so you build up calories. Bonus days are the rest, with a higher allowance so you can spend what you banked. Calorie changes apply to the current week and forward; past weeks keep the goals that were in effect at the time.")
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

            Section {
                Toggle("Track supplements & vitamins", isOn: $profile.tracksSupplements)
            } footer: {
                Text("Adds a Supplements section to the daily log between Snacks and Workouts. Doesn't affect calorie or macro totals.")
            }

            #if DEBUG
            Section {
                Button {
                    backupNow()
                } label: {
                    Label("Back up now", systemImage: "tray.and.arrow.down")
                }

                if !snapshots.isEmpty {
                    ForEach(snapshots) { snap in
                        BackupRow(snapshot: snap) {
                            pendingRestore = snap
                            showRestoreConfirm = true
                        } onDelete: {
                            deleteBackup(snap)
                        }
                    }
                }

                if let backupStatusMessage {
                    Text(backupStatusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Backups")
            } footer: {
                Text("A snapshot is taken automatically each time the app launches; the last 10 are kept. Restoring will close the app — relaunch to load the restored data. Visible only in debug builds; auto-snapshots still run in release.")
            }
            .onAppear { refreshSnapshots() }
            .confirmationDialog(
                "Restoring overwrites the current data with this backup. The app will close — relaunch to apply.",
                isPresented: $showRestoreConfirm,
                titleVisibility: .visible
            ) {
                Button("Restore + Close App", role: .destructive) {
                    if let snap = pendingRestore { restore(snap) }
                    pendingRestore = nil
                }
                Button("Cancel", role: .cancel) { pendingRestore = nil }
            }
            .alert("Restore complete — please relaunch the app", isPresented: $showRelaunchPrompt) {
                Button("Close app now") { exit(0) }
                Button("Later", role: .cancel) {}
            }

            Section {
                Button {
                    runMigration()
                } label: {
                    Label("Re-run unit migration", systemImage: "wand.and.stars")
                }

                Button {
                    showImporter = true
                } label: {
                    Label("Import from backup CSV", systemImage: "square.and.arrow.down")
                }

                if let migrationStatusMessage {
                    Text(migrationStatusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let importStatusMessage {
                    Text(importStatusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Migrate / Restore")
            } footer: {
                Text("Re-run the unit migration if entries are stuck on ‘ea’ — it parses any surviving legacy serving data first, then falls back to name-based inference (RX Bar → bar, etc.). Idempotent: rows that already have a real unit are left alone. Visible only in debug builds.")
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.commaSeparatedText, .text, .plainText, .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        pendingImportURL = url
                        showWipeConfirm = true
                    }
                case .failure(let error):
                    importStatusMessage = "Couldn't open file: \(error.localizedDescription)"
                }
            }
            .confirmationDialog(
                "This will erase your current data and replace it with the CSV.",
                isPresented: $showWipeConfirm,
                titleVisibility: .visible
            ) {
                Button("Replace data", role: .destructive) {
                    if let url = pendingImportURL { runImport(url: url) }
                    pendingImportURL = nil
                }
                Button("Cancel", role: .cancel) { pendingImportURL = nil }
            }
            #endif

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

    private func runImport(url: URL) {
        do {
            let summary = try CSVBackupImporter.importBackup(from: url, into: modelContext)
            var msg = "Imported \(summary.foodEntries) food entries, \(summary.dayLogs) day logs, \(summary.cachedFoods) cached foods, \(summary.weightEntries) weights, \(summary.manualWorkouts) workouts, \(summary.goalPeriods) goal periods, \(summary.profiles) profile."
            if !summary.skipped.isEmpty {
                msg += " Skipped \(summary.skipped.count) row(s)."
            }
            importStatusMessage = msg
            refreshSnapshots()
        } catch {
            importStatusMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func runMigration() {
        let summary = LegacyDataMigrator.forceRun(in: modelContext)
        var msg =
            "Food entries: \(summary.foodEntriesFromLegacy) from legacy data, " +
            "\(summary.foodEntriesFromInference) from name match, " +
            "\(summary.foodEntriesUntouched) unchanged.\n" +
            "Cached foods: \(summary.cachedFoodsFromLegacy) from legacy data, " +
            "\(summary.cachedFoodsFromInference) from name match, " +
            "\(summary.cachedFoodsUntouched) unchanged."
        if !summary.sampleDiagnostics.isEmpty {
            msg += "\n\nSample rows (BEFORE this run):\n" + summary.sampleDiagnostics.joined(separator: "\n")
        }
        migrationStatusMessage = msg
    }

    private func refreshSnapshots() {
        snapshots = BackupService.listSnapshots()
    }

    private func backupNow() {
        do {
            _ = try BackupService.snapshotNow(maxKeep: 10)
            backupStatusMessage = "Backup created."
            refreshSnapshots()
        } catch {
            backupStatusMessage = "Backup failed: \(error.localizedDescription)"
        }
    }

    private func restore(_ snapshot: BackupService.Snapshot) {
        do {
            try BackupService.restore(snapshot)
            backupStatusMessage = "Restored. Relaunch the app to load the restored data."
            showRelaunchPrompt = true
        } catch {
            backupStatusMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    private func deleteBackup(_ snapshot: BackupService.Snapshot) {
        do {
            try BackupService.delete(snapshot)
            refreshSnapshots()
        } catch {
            backupStatusMessage = "Couldn't delete backup: \(error.localizedDescription)"
        }
    }

}

private struct BackupRow: View {
    let snapshot: BackupService.Snapshot
    let onRestore: () -> Void
    let onDelete: () -> Void

    private var subtitle: String {
        let date = snapshot.timestamp.formatted(date: .abbreviated, time: .shortened)
        let kb = ByteCountFormatter.string(fromByteCount: snapshot.totalBytes, countStyle: .file)
        return "\(date) · \(kb)"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.id).font(.subheadline.monospaced())
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore", action: onRestore)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
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
            "Bank days: \(bankingDays.sorted { $0.rawValue < $1.rawValue }.map(\.fullName).joined(separator: ", "))"
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
