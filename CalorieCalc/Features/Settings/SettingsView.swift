import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(HealthKitService.self) private var healthKitService

    // Sort by createdAt so `profiles.first` resolves the same canonical row every other view
    // uses — otherwise edits here could write to a different duplicate than the one displayed.
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
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
    /// Shared with the AI Plan Analyzer's Apply path — see `PlanCommitter`.
    private func commitDraft() {
        guard let draft, let profile = profiles.first else { return }
        PlanCommitter.commit(draft: draft, profile: profile, in: modelContext)
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

    /// What each bonus day allows once the week's math averages out: the weekly gross
    /// allowance (7 × (net + workout)) minus everything spoken-for on bank days, divided
    /// across the remaining off days. Same formula `CalorieBankCalculator` uses for the
    /// at-plan per-off-day budget; mirrored here so Settings can preview it live.
    /// Returns 0 for a 7/0 split (no off days). May go negative if Target × bank days
    /// already exceeds the weekly allowance — that's a signal the plan is inconsistent.
    var bonusDayTarget: Int {
        let offCount = bankSplit.offDayCount
        guard offCount > 0 else { return 0 }
        let weeklyAllowance = (dailyNetCalorieGoal + dailyWorkoutCalorieGoal) * 7
        let bankingCommit = bankSplit.bankingDayCount * dailyGrossCalorieGoal
        return (weeklyAllowance - bankingCommit) / offCount
    }

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
    @Environment(AIConsentService.self) private var aiConsent
    @Environment(\.openURL) private var openURL
    @AppStorage(AIResponseLanguage.storageKey) private var aiResponseLanguageRaw = AIResponseLanguage.deviceLanguage.rawValue
    @State private var showAIConsentSheet = false
    @State private var showPlanAnalyzer = false
    @State private var showPlanQuestion = false
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
    @State private var showClearDataConfirm = false
    @State private var clearDataErrorMessage: String?

    private var defaultTab: AppTab {
        get { AppTab(rawValue: defaultTabRaw) ?? .week }
    }

    /// Next multiple of `step` strictly above `value` (clamped to `max`). For a value already on
    /// the grid this is `value + step`; for an off-grid value it snaps up to the grid (2076 → 2100
    /// at step 50). Assumes non-negative values.
    private func snappedUp(_ value: Int, step: Int, max: Int) -> Int {
        Swift.min((value / step + 1) * step, max)
    }

    /// Nearest multiple of `step` strictly below `value` (clamped to `min`). On-grid → `value - step`;
    /// off-grid → snaps down to the grid (2076 → 2050 at step 50).
    private func snappedDown(_ value: Int, step: Int, min: Int) -> Int {
        let lower = value % step == 0 ? value - step : (value / step) * step
        return Swift.max(lower, min)
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
                GoalWeightField(profile: profile)
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Goal pace", selection: Binding(
                        get: { profile.weightGoalPace },
                        set: { profile.weightGoalPace = $0 }
                    )) {
                        Text("Not set").tag(WeightGoalPace?.none)
                        ForEach(WeightGoalPace.allCases) { pace in
                            Text(pace.displayName).tag(WeightGoalPace?.some(pace))
                        }
                    }
                    if let pace = profile.weightGoalPace {
                        Text(pace.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                // Week shape comes next so the bank/bonus split is set before the user dials
                // in calorie targets — the targets only make sense once the shape is decided.
                Picker("Week starts on", selection: $draft.weekStart) {
                    ForEach(Weekday.allCases) { day in
                        Text(day.shortName).tag(day)
                    }
                }
                Picker("Week split", selection: $draft.bankSplit) {
                    ForEach(BankSplit.allCases, id: \.self) { split in
                        Text(split.displayName).tag(split)
                    }
                }
                BankingDaysPreview(weekStart: draft.weekStart, bankSplit: draft.bankSplit)

                // Snap to the step grid rather than adding the raw step, so an odd value (e.g.
                // 2076 from an applied AI plan) lands on a clean multiple: 2076 + → 2100, − → 2050.
                Stepper {
                    LabeledContent("Target Daily Net") { Text("\(draft.dailyNetCalorieGoal) kcal").monospacedDigit() }
                } onIncrement: {
                    draft.dailyNetCalorieGoal = snappedUp(draft.dailyNetCalorieGoal, step: 50, max: 5000)
                } onDecrement: {
                    draft.dailyNetCalorieGoal = snappedDown(draft.dailyNetCalorieGoal, step: 50, min: 800)
                }
                Stepper {
                    LabeledContent("Daily workout goal") { Text("\(draft.dailyWorkoutCalorieGoal) kcal").monospacedDigit() }
                } onIncrement: {
                    draft.dailyWorkoutCalorieGoal = snappedUp(draft.dailyWorkoutCalorieGoal, step: 25, max: 3000)
                } onDecrement: {
                    draft.dailyWorkoutCalorieGoal = snappedDown(draft.dailyWorkoutCalorieGoal, step: 25, min: 0)
                }
                Stepper {
                    LabeledContent("Daily eating goal") { Text("\(draft.dailyGrossCalorieGoal) kcal").monospacedDigit() }
                } onIncrement: {
                    draft.dailyGrossCalorieGoal = snappedUp(draft.dailyGrossCalorieGoal, step: 50, max: 6000)
                } onDecrement: {
                    draft.dailyGrossCalorieGoal = snappedDown(draft.dailyGrossCalorieGoal, step: 50, min: 800)
                }
                if draft.bankSplit.offDayCount > 0 {
                    LabeledContent("Bonus day(s)") {
                        Text("\(draft.bonusDayTarget) kcal").monospacedDigit()
                    }
                }

                Button {
                    showPlanAnalyzer = true
                } label: {
                    Label("Build my plan with AI", systemImage: "sparkles")
                }
                Button {
                    showPlanQuestion = true
                } label: {
                    Label("Ask about my plan", systemImage: "questionmark.bubble")
                }
            } header: {
                Text("My Plan")
            } footer: {
                Text("Set your Target Daily Net based on how fast you want to drop weight — at a healthy pace. Set your workout goal to your average daily burn (for example, walking 3 miles 3× a week burns about 140 kcal a day). Then adjust your Daily eating goal to see how many calories you can eat on your bonus day(s).")
            }

            Section("Units") {
                Picker("Height/Weight", selection: $profile.weightUnit) {
                    ForEach(WeightUnit.allCases, id: \.self) { unit in
                        Text(unit.systemName).tag(unit)
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

            Section {
                NavigationLink {
                    TagManagementView()
                } label: {
                    Label("Manage Tags", systemImage: "tag")
                }
            } footer: {
                Text("Custom labels you can attach to foods (e.g. \"Thai\", \"Vegan\", \"Low Calorie\") to filter your saved catalog and recents.")
            }

            if aiConsent.isGranted {
                Section {
                    Toggle(isOn: Binding(
                        get: { aiResponseLanguageRaw == AIResponseLanguage.english.rawValue },
                        set: { aiResponseLanguageRaw = ($0 ? AIResponseLanguage.english : .deviceLanguage).rawValue }
                    )) {
                        Label("Reply in English", systemImage: "character.bubble")
                    }
                } header: {
                    Text("AI Reply Language")
                } footer: {
                    Text("Off (default) replies in the app's language. Turn it on to always get AI replies in English.")
                }
            }

            Section {
                Button {
                    showAIConsentSheet = true
                } label: {
                    HStack {
                        Label("AI features", systemImage: "sparkles")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(aiConsent.isGranted ? "On" : "Off")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                Button {
                    openURL(URL(string: "https://pjlawler.github.io/calorie-calc/privacy.html")!)
                } label: {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                Button {
                    openURL(URL(string: "https://pjlawler.github.io/calorie-calc/terms.html")!)
                } label: {
                    Label("Terms of Service", systemImage: "doc.text")
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("AI features (Photo, Describe, Recipe Analyzer, Period Analysis) send your input to Anthropic's Claude. Tap AI features for the full disclosure or to revoke access.")
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

            Section {
                Button("Clear all data", role: .destructive) {
                    showClearDataConfirm = true
                }
            } footer: {
                Text("Permanently deletes everything you've entered — food logs, weights, workouts, supplements, saved foods, tags, and goals — from this device and every iCloud device on your account. This can't be undone. Your Apple Health data is not affected and will remain.")
            }
            .confirmationDialog(
                "Are you sure you want to permanently delete all of your entered data?",
                isPresented: $showClearDataConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete all data", role: .destructive) { clearAllData() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This can't be undone, and the app will close so it can reload from a clean slate. Apple Health data will remain.")
            }
            .alert(
                "Couldn't clear data",
                isPresented: Binding(
                    get: { clearDataErrorMessage != nil },
                    set: { if !$0 { clearDataErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { clearDataErrorMessage = nil }
            } message: {
                Text(clearDataErrorMessage ?? "")
            }
        }
        .sheet(isPresented: $showAIConsentSheet) {
            AIConsentSheet()
        }
        .sheet(isPresented: $showPlanAnalyzer) {
            // Sync the committed plan back into this screen's draft so the steppers update and
            // tapping Done doesn't re-commit the pre-analyzer values over the AI's change.
            PlanAnalyzerSheet(onApplied: { draft = $0 })
        }
        .sheet(isPresented: $showPlanQuestion) {
            PlanQuestionSheet()
        }
    }

    /// Permanently deletes all user-entered, CloudKit-synced data, then terminates the app so it
    /// relaunches against the empty store. The local HealthKit cache (CachedWorkout /
    /// CachedDailySteps) is left alone — it mirrors Apple Health, which we promise to preserve,
    /// and rebuilds itself on the next sync.
    ///
    /// Two deliberate choices here:
    /// - We delete each object individually rather than using `modelContext.delete(model:)`. The
    ///   bulk form issues an `NSBatchDeleteRequest` that bypasses SwiftData's change tracking, so
    ///   the CloudKit mirror never learns about the deletions — the records stay on the server and
    ///   the sync engine re-downloads them right back. Per-object deletes register as tombstones
    ///   that export to CloudKit, so the data stays gone across devices.
    /// - We `exit(0)` synchronously right after the save instead of letting the view re-render.
    ///   This screen is bound to a `UserProfile` we just deleted; any subsequent body evaluation
    ///   (e.g. the Units picker reading `$profile.weightUnit`) would dereference a deleted model
    ///   and crash. Terminating in the same call stack means SwiftUI never re-renders the stale
    ///   binding, and relaunch rebootstraps a fresh profile cleanly.
    private func clearAllData() {
        do {
            try deleteAll(FoodEntry.self)
            try deleteAll(SupplementEntry.self)
            try deleteAll(ManualWorkout.self)
            try deleteAll(DayLog.self)
            try deleteAll(WeightEntry.self)
            try deleteAll(CachedFood.self)
            try deleteAll(FoodTag.self)
            try deleteAll(GoalPeriod.self)
            try deleteAll(UserProfile.self)
            try modelContext.save()
            exit(0)
        } catch {
            clearDataErrorMessage = error.localizedDescription
        }
    }

    /// Fetches and deletes every instance of `type` one at a time so each deletion is tracked by
    /// SwiftData and exported to CloudKit (unlike the bulk `delete(model:)` batch form).
    private func deleteAll<T: PersistentModel>(_ type: T.Type) throws {
        let items = try modelContext.fetch(FetchDescriptor<T>())
        for item in items {
            modelContext.delete(item)
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
            "Regular days: \(bankingDays.sorted { $0.rawValue < $1.rawValue }.map(\.fullName).joined(separator: ", "))"
        )
    }
}

private struct GoalWeightField: View {
    @Bindable var profile: UserProfile
    @State private var text: String = ""

    var body: some View {
        HStack {
            Text("Goal weight")
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
