import SwiftUI
import SwiftData

struct SettingsView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(HealthKitService.self) private var healthKitService

    @Query private var profiles: [UserProfile]
    @Query(sort: \GoalPeriod.startDate) private var goalPeriods: [GoalPeriod]

    @AppStorage(AppTab.defaultTabStorageKey) private var defaultTabRaw: String = AppTab.week.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue

    @State private var viewModel: SettingsViewModel?
    @State private var draft: GoalDraft?

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
                        appearanceRaw: $appearanceRaw
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
