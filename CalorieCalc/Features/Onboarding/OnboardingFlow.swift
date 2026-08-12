import SwiftUI
import SwiftData

/// First-run flow: goal → about you → your plan → log your first meal.
///
/// The shape is deliberate. Everything before the last step is setup that earns the right to ask
/// for the last step, which is the one that matters — a user who logs a meal with AI in their
/// first session has met the thing that makes this app different from a spreadsheet.
///
/// Store writes are centralised here rather than in the step views so there is exactly one place
/// that touches `UserProfile` / `GoalPeriod`, and it always goes through `ProfileBootstrap` +
/// `PlanCommitter` like every other plan edit in the app.
struct OnboardingFlow: View {

    /// Called when the flow is over — finished or skipped. The presenter stamps completion.
    let onFinish: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(AIConsentService.self) private var aiConsent

    // Canonical profile resolved the same way every other view does (earliest createdAt) — see
    // the CloudKit singleton-duplication note in DataDeduplicator.
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(sort: \GoalPeriod.startDate) private var goalPeriods: [GoalPeriod]
    /// Existence check only — limited to one row so a returning user's full log never loads here.
    @Query private var anyFoodEntry: [FoodEntry]

    @State private var state = OnboardingState()
    @State private var step: Step = .goal
    @State private var didSeed = false

    enum Step: Int, CaseIterable, Comparable {
        case goal, profile, plan, firstLog
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        var descriptor = FetchDescriptor<FoodEntry>()
        descriptor.fetchLimit = 1
        _anyFoodEntry = Query(descriptor)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressBar
                content
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step > .goal {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            withAnimation { goBack() }
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                }
                // An escape hatch, but a quiet one — and only before the plan is committed. After
                // that the remaining step already offers "I'll log later".
                if step < .plan {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Skip") { finish(reason: .skipped) }
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            guard !didSeed else { return }
            didSeed = true
            state.seedDefaultsFromLocale()
            if let profile = profiles.first { state.weightUnit = profile.weightUnit }
            OnboardingAnalytics.track(.started)
        }
        // A returning user's CloudKit data can land seconds after launch, well after the gate
        // decided this looked like a fresh install. Bow out rather than walk them through setup
        // on top of history they already have. Skipped during the logging step, where the user
        // creating their own first entry would otherwise look identical to a sync.
        .onChange(of: anyFoodEntry.isEmpty) { _, isEmpty in
            guard step != .firstLog, !isEmpty else { return }
            OnboardingAnalytics.track(.supersededBySync)
            finish(reason: .superseded)
        }
    }

    // MARK: - Chrome

    private var progressBar: some View {
        HStack(spacing: 4) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s <= step ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(height: 4)
            }
        }
        .padding(.horizontal)
        // Clears the toolbar's Back/Skip buttons, which float over the bar on an inline title.
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.25), value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .goal:
            OnboardingGoalStep(state: state) {
                OnboardingAnalytics.track(.goalChosen, ["pace": state.pace?.rawValue ?? "none"])
                advance(to: .profile)
            }
        case .profile:
            OnboardingProfileStep(state: state) {
                OnboardingAnalytics.track(.profileCompleted)
                advance(to: .plan)
            }
        case .plan:
            OnboardingPlanStep(
                commit: { commitPlan() },
                onContinue: { advance(to: .firstLog) }
            )
        case .firstLog:
            OnboardingFirstLogStep(
                onLogged: {
                    OnboardingAnalytics.track(.firstLogSucceeded)
                    finish(reason: .completed)
                },
                onSkip: {
                    OnboardingAnalytics.track(.firstLogSkipped)
                    finish(reason: .completed)
                }
            )
            .environment(aiConsent)
        }
    }

    // MARK: - Navigation

    private func advance(to next: Step) {
        withAnimation { step = next }
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private enum FinishReason: String {
        case completed, skipped, superseded
    }

    private func finish(reason: FinishReason) {
        OnboardingAnalytics.track(.completed, ["reason": reason.rawValue])
        onFinish()
    }

    // MARK: - Store writes

    /// Persists the collected biometrics and commits the deterministic plan. Called when the plan
    /// step appears — *before* the user has a chance to open the AI refine sheet — so a plan
    /// always exists even if they close the refine sheet without applying, and so the refine
    /// sheet's own prefill (which reads the profile) has something to read.
    ///
    /// Idempotent: re-running with the same answers overwrites the same open `GoalPeriod`.
    @discardableResult
    private func commitPlan() -> OnboardingPlanBuilder.Plan? {
        guard let inputs = state.planInputs else { return nil }
        guard let profile = ProfileBootstrap.ensure(
            in: modelContext,
            profiles: profiles,
            goalPeriods: goalPeriods
        ) else { return nil }

        profile.weightUnit = state.weightUnit
        profile.biologicalSex = inputs.sex
        profile.birthYear = Calendar.current.component(.year, from: .now) - state.age
        profile.heightCm = inputs.heightCm
        profile.nonExerciseActivity = inputs.activity
        profile.weightGoalPace = inputs.pace
        profile.updatedAt = .now

        // Give Progress a baseline from day one instead of waiting for the user to find the
        // weight screen. Guarded so backing up and re-committing doesn't stack weigh-ins.
        if profile.startingWeight == nil {
            profile.startingWeight = state.weight
            profile.startingWeightLoggedAt = .now
        }
        if state.goalWeight > 0 { profile.goalWeight = state.goalWeight }
        if (try? modelContext.fetchCount(FetchDescriptor<WeightEntry>())) == 0 {
            modelContext.insert(WeightEntry(weight: state.weight, unit: state.weightUnit))
        }

        let plan = OnboardingPlanBuilder.plan(for: inputs)
        var draft = GoalDraft(from: profile)
        OnboardingPlanBuilder.apply(plan, to: &draft)
        PlanCommitter.commit(draft: draft, profile: profile, in: modelContext)
        try? modelContext.save()

        OnboardingAnalytics.track(.planCommitted, [
            "net": String(plan.dailyNetCalorieGoal),
            "floored": String(plan.netWasFloored)
        ])
        return plan
    }
}
