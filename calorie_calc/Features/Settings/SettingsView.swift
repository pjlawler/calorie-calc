import SwiftUI
import SwiftData

struct SettingsView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(HealthKitService.self) private var healthKitService

    @Query private var profiles: [UserProfile]

    @AppStorage(AppTab.defaultTabStorageKey) private var defaultTabRaw: String = AppTab.week.rawValue

    @State private var viewModel: SettingsViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let profile = profiles.first {
                    SettingsForm(profile: profile, viewModel: viewModel, defaultTabRaw: $defaultTabRaw)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
            .task {
                if viewModel == nil {
                    viewModel = SettingsViewModel(healthKitService: healthKitService)
                }
            }
        }
    }
}

private struct SettingsForm: View {
    @Bindable var profile: UserProfile
    let viewModel: SettingsViewModel?
    @Binding var defaultTabRaw: String

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
            } header: {
                Text("Default view")
            } footer: {
                Text("Which tab to show when you open the app.")
            }

            Section("Calorie goals") {
                Stepper(value: $profile.dailyNetCalorieGoal, in: 800...5000, step: 50) {
                    LabeledContent("Daily net") { Text("\(profile.dailyNetCalorieGoal) kcal").monospacedDigit() }
                }
                Stepper(value: $profile.dailyGrossCalorieGoal, in: 800...6000, step: 50) {
                    LabeledContent("Daily gross (plan days)") { Text("\(profile.dailyGrossCalorieGoal) kcal").monospacedDigit() }
                }
                Stepper(value: $profile.dailyWorkoutCalorieGoal, in: 0...3000, step: 25) {
                    LabeledContent("Daily workout goal") { Text("\(profile.dailyWorkoutCalorieGoal) kcal").monospacedDigit() }
                }
            }

            Section {
                Picker("Week split", selection: $profile.bankSplit) {
                    ForEach(BankSplit.allCases, id: \.self) { split in
                        Text(split.displayName).tag(split)
                    }
                }
                Picker("Week starts on", selection: $profile.weekStart) {
                    ForEach(Weekday.allCases) { day in
                        Text(day.shortName).tag(day)
                    }
                }
                BankingDaysPreview(profile: profile)
            } header: {
                Text("Week shape")
            } footer: {
                Text("Plan days are the first \(profile.bankSplit.bankingDayCount) days of your week. Flex days are the rest.")
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
                    Text("Log a weight on the Dashboard to set your starting weight.")
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
    let profile: UserProfile

    private var ordered: [Weekday] {
        Weekday.allCases.sorted { a, b in
            let normA = (a.rawValue - profile.weekStart.rawValue + 7) % 7
            let normB = (b.rawValue - profile.weekStart.rawValue + 7) % 7
            return normA < normB
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ordered) { day in
                let banking = profile.isBankingDay(day)
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
            "Plan days: \(profile.bankingWeekdays.sorted { $0.rawValue < $1.rawValue }.map(\.fullName).joined(separator: ", "))"
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
