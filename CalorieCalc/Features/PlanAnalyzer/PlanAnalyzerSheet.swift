import SwiftUI
import SwiftData

/// AI Plan Analyzer. Collects basic biometrics + preferences, asks Claude to recommend the
/// app's plan settings (daily net, eating goal, workout goal, week split) with a narrative
/// explaining them, and offers a one-tap Apply that runs through `PlanValidator` and the same
/// `PlanCommitter` path the Settings screen uses.
struct PlanAnalyzerSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PlanAnalyzerEnvironment.self) private var env
    @Environment(AIConsentService.self) private var aiConsent

    // Canonical profile resolved the same way every other view does (earliest createdAt) so we
    // read/write the row the rest of the app uses — see the CloudKit singleton-duplication note.
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(sort: \WeightEntry.timestamp) private var weightEntries: [WeightEntry]

    private enum Phase {
        case input
        case loading
        case result(RecommendedPlan)
        case failed(String)
    }

    @State private var phase: Phase = .input
    @State private var didPrefill = false

    // Inputs
    @State private var sex: BiologicalSex?
    @State private var age = 35
    @State private var heightTotalInches = 69   // imperial entry, in whole inches
    @State private var heightCm = 175.0
    @State private var weight = 0.0
    @State private var activity: NonExerciseActivityLevel = .sedentary
    @State private var workoutGoal = 150
    @State private var pace: WeightGoalPace = .moderate
    @State private var preferences = ""

    // Consent + paywall + validation
    @State private var showConsent = false
    @State private var showPaywall = false
    @State private var pendingValidation: PlanValidator.Result?
    @State private var pendingDraft: GoalDraft?
    @State private var showValidationAlert = false

    private var isMetric: Bool { profiles.first?.weightUnit == .kilograms }
    private var weightSuffix: String { (profiles.first?.weightUnit ?? .pounds).suffix }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Build my plan with AI")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { dismiss() }
                    }
                    if case .result = phase {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                phase = .input
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                            }
                            .accessibilityLabel("Edit inputs")
                        }
                    }
                }
                .sheet(isPresented: $showConsent, onDismiss: { /* user can retry */ }) {
                    AIConsentSheet(onAllow: { runAnalysis() })
                }
                .sheet(isPresented: $showPaywall) { PaywallSheet() }
                .alert(validationAlertTitle, isPresented: $showValidationAlert, presenting: pendingValidation) { result in
                    if result.severity == .error {
                        Button("OK", role: .cancel) { clearPendingValidation() }
                    } else {
                        Button("Cancel", role: .cancel) { clearPendingValidation() }
                        Button("Apply anyway") { commitPendingDraft() }
                    }
                } message: { result in
                    Text(result.issues.map(\.message).joined(separator: "\n\n"))
                }
        }
        .task { prefillIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .input:
            inputForm
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Claude is building your plan…")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .result(let plan):
            resultView(plan)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label("Couldn't build your plan", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Try again") { phase = .input }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    // MARK: - Input form

    private var inputForm: some View {
        Form {
            Section {
                Picker("Sex", selection: $sex) {
                    Text("Select").tag(BiologicalSex?.none)
                    ForEach(BiologicalSex.allCases) { s in
                        Text(s.displayName).tag(BiologicalSex?.some(s))
                    }
                }
                Stepper(value: $age, in: 13...100) {
                    LabeledContent("Age") { Text("\(age)").monospacedDigit() }
                }
                if isMetric {
                    Stepper(value: $heightCm, in: 120...230, step: 1) {
                        LabeledContent("Height") { Text("\(Int(heightCm)) cm").monospacedDigit() }
                    }
                } else {
                    Stepper(value: $heightTotalInches, in: 48...96) {
                        LabeledContent("Height (\(heightTotalInches / 12)' \(heightTotalInches % 12)\")") {
                            Text("\(heightTotalInches)\"").monospacedDigit()
                        }
                    }
                }
                Stepper(value: $weight, in: weightRange, step: isMetric ? 0.5 : 1) {
                    LabeledContent("Weight") {
                        Text("\(weight.formatted(.number.precision(.fractionLength(isMetric ? 1 : 0)))) \(weightSuffix)").monospacedDigit()
                    }
                }
            } header: {
                Text("About you")
            } footer: {
                Text("Sex and age are used only to estimate your calorie needs.")
            }

            Section {
                Picker("Daily activity", selection: $activity) {
                    ForEach(NonExerciseActivityLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                Text(activity.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Everyday activity")
            } footer: {
                Text("How much you move during a normal day — NOT your workouts. An office job is still “Sedentary” even if you exercise.")
            }

            Section {
                Stepper(value: $workoutGoal, in: 0...3000, step: 25) {
                    LabeledContent("Workout goal") { Text("\(workoutGoal) kcal/day").monospacedDigit() }
                }
            } header: {
                Text("Workout goal")
            } footer: {
                Text("Your target average daily burn from deliberate exercise.")
            }

            Section {
                Picker("Goal", selection: $pace) {
                    ForEach(WeightGoalPace.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                Text(pace.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Weight goal")
            }

            Section {
                TextField("e.g. I love big weekends, I’m vegetarian, mornings are busy…", text: $preferences, axis: .vertical)
                    .lineLimit(3...6)
            } header: {
                Text("Anything else?")
            } footer: {
                Text("Optional. Tell the coach about your eating habits and preferences so the plan fits your life.")
            }

            Section {
                Button {
                    generate()
                } label: {
                    Label("Generate my plan", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!inputsValid)
            }
        }
    }

    private var weightRange: ClosedRange<Double> {
        isMetric ? 35...250 : 70...550
    }

    private var inputsValid: Bool {
        sex != nil && weight > 0
    }

    // MARK: - Result

    private func resultView(_ plan: RecommendedPlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MarkdownText(text: plan.narrative)

                recommendedCard(plan)

                if let notes = plan.notes {
                    Text(notes)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("Estimated maintenance: \(plan.estimatedTDEE) kcal/day (BMR \(plan.estimatedBMR)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                medicalDisclaimer
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                apply(plan)
            } label: {
                Text("Apply these settings")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private var medicalDisclaimer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("This plan is AI-generated and doesn't account for any medical conditions that limiting your calories or setting a workout goal could affect. Talk to your primary care provider before starting any significant change to your diet or fitness routine.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial))
    }

    private func recommendedCard(_ plan: RecommendedPlan) -> some View {
        let draft = draft(from: plan)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Recommended settings")
                .font(.headline)
            row("Daily net", "\(draft.dailyNetCalorieGoal) kcal")
            row("Daily eating goal", "\(draft.dailyGrossCalorieGoal) kcal")
            row("Workout goal", "\(draft.dailyWorkoutCalorieGoal) kcal")
            row("Week split", draft.bankSplit.displayName)
            if draft.bankSplit.offDayCount > 0 {
                row("Bonus day(s)", "\(draft.bonusDayTarget) kcal")
            }
            row("Week starts on", draft.weekStart.fullName)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).monospacedDigit() }
    }

    // MARK: - Actions

    private func generate() {
        if aiConsent.isGranted {
            runAnalysis()
        } else {
            showConsent = true
        }
    }

    private func runAnalysis() {
        guard let input = buildInput() else { return }
        persistInputs()
        phase = .loading
        Task {
            do {
                let plan = try await env.service.recommend(input)
                phase = .result(plan)
            } catch NutritionAnalysisError.outOfCredits {
                phase = .input
                showPaywall = true
            } catch {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func buildInput() -> PlanAnalysisInput? {
        guard let sex, let profile = profiles.first else { return nil }
        let unit = profile.weightUnit
        let weightKg = unit.convert(weight, to: .kilograms)
        let cm = isMetric ? heightCm : Double(heightTotalInches) * 2.54
        return PlanAnalysisInput(
            heightCm: cm,
            weightKg: weightKg,
            age: age,
            sex: sex,
            activity: activity,
            workoutCalorieGoal: workoutGoal,
            pace: pace,
            preferencesNote: preferences,
            weightUnitSuffix: unit.suffix,
            currentWeekStart: profile.weekStart
        )
    }

    /// Persist the entered biometrics onto the profile so a re-run prefills them. Saved on
    /// generate (before the network call) so they survive even if the call fails.
    private func persistInputs() {
        guard let profile = profiles.first else { return }
        profile.biologicalSex = sex
        profile.birthYear = Calendar.current.component(.year, from: .now) - age
        profile.heightCm = isMetric ? heightCm : Double(heightTotalInches) * 2.54
        profile.nonExerciseActivity = activity
        profile.weightGoalPace = pace
        profile.planPreferencesNote = preferences.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.updatedAt = .now
        try? modelContext.save()
    }

    private func draft(from plan: RecommendedPlan) -> GoalDraft {
        guard let profile = profiles.first else {
            // Unreachable in practice (the sheet only opens with a profile), but keep a sane value.
            var d = GoalDraft(from: UserProfile())
            applyPlan(plan, to: &d)
            return d
        }
        var d = GoalDraft(from: profile)
        applyPlan(plan, to: &d)
        return d
    }

    private func applyPlan(_ plan: RecommendedPlan, to draft: inout GoalDraft) {
        draft.dailyNetCalorieGoal = clamp(plan.dailyNetCalorieGoal, 800, 5000)
        draft.dailyGrossCalorieGoal = clamp(plan.dailyGrossCalorieGoal, 800, 6000)
        draft.dailyWorkoutCalorieGoal = clamp(plan.dailyWorkoutCalorieGoal, 0, 3000)
        draft.bankSplit = plan.bankSplit
        draft.weekStart = plan.weekStart
    }

    private func apply(_ plan: RecommendedPlan) {
        let draft = draft(from: plan)
        let result = PlanValidator.validate(draft: draft)
        switch result.severity {
        case .error:
            pendingValidation = result
            pendingDraft = nil
            showValidationAlert = true
        case .caution:
            pendingValidation = result
            pendingDraft = draft
            showValidationAlert = true
        case nil:
            commit(draft)
        }
    }

    private func commit(_ draft: GoalDraft) {
        guard let profile = profiles.first else { return }
        PlanCommitter.commit(draft: draft, profile: profile, in: modelContext)
        try? modelContext.save()
        dismiss()
    }

    private func commitPendingDraft() {
        if let draft = pendingDraft { commit(draft) }
        clearPendingValidation()
    }

    private func clearPendingValidation() {
        pendingValidation = nil
        pendingDraft = nil
    }

    private var validationAlertTitle: String {
        guard let severity = pendingValidation?.severity else { return "" }
        return severity == .error ? "The math doesn’t work" : "Heads up"
    }

    private func clamp(_ value: Int, _ lo: Int, _ hi: Int) -> Int {
        min(max(value, lo), hi)
    }

    // MARK: - Prefill

    private func prefillIfNeeded() {
        guard !didPrefill, let profile = profiles.first else { return }
        didPrefill = true

        if let s = profile.biologicalSex { sex = s }
        if let by = profile.birthYear {
            age = max(13, min(100, Calendar.current.component(.year, from: .now) - by))
        }
        if let level = profile.nonExerciseActivity { activity = level }
        if let p = profile.weightGoalPace { pace = p }
        if let note = profile.planPreferencesNote { preferences = note }
        workoutGoal = profile.dailyWorkoutCalorieGoal

        if let cm = profile.heightCm {
            heightCm = cm
            heightTotalInches = max(48, min(96, Int((cm / 2.54).rounded())))
        }

        // Weight: latest logged weigh-in, else the profile's starting weight, converted to the
        // user's display unit.
        let unit = profile.weightUnit
        if let latest = weightEntries.last {
            weight = latest.weight(in: unit)
        } else if let start = profile.startingWeight {
            weight = start
        }
        if weight <= 0 { weight = isMetric ? 75 : 170 }
    }
}
