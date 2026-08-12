import SwiftUI
import SwiftData

/// Step 3 — the payoff for step 2. A real plan, computed on-device from Mifflin–St Jeor with no
/// network call, no consent prompt and no credit spent.
///
/// The plan is committed as soon as this screen appears, not when the user taps Continue. That
/// ordering matters: the AI refine sheet prefills from `UserProfile`, and if the user opens it and
/// closes it without applying, they still walk away with the deterministic plan rather than the
/// silent 2,000-kcal default.
struct OnboardingPlanStep: View {

    /// Persists biometrics and commits the deterministic plan. Returns the figures it used.
    let commit: () -> OnboardingPlanBuilder.Plan?
    let onContinue: () -> Void

    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]

    @State private var plan: OnboardingPlanBuilder.Plan?
    @State private var showRefine = false

    /// Reads back what actually landed on the profile, so an applied AI refinement is reflected
    /// here without this view needing to know the refine sheet exists.
    private var committed: GoalDraft? {
        profiles.first.map(GoalDraft.init(from:))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let committed {
                    planCard(committed)
                }

                if let plan {
                    if plan.netWasFloored {
                        note(
                            "We eased your target back to \(TDEECalculator.netFloor) kcal — the pace you picked would have gone below what's considered safe.",
                            icon: "info.circle.fill",
                            tint: .blue
                        )
                    }
                    Text("Estimated maintenance: \(plan.tdee) kcal/day (BMR \(plan.bmr)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                refineCard
                disclaimer
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                onContinue()
            } label: {
                Text("Start logging")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .task {
            if plan == nil { plan = commit() }
        }
        .sheet(isPresented: $showRefine) {
            // Reuses the shipping analyzer wholesale rather than duplicating the AI call: it
            // prefills from the profile this step just wrote, and applies through the same
            // PlanValidator + PlanCommitter path. Closing it without applying is a no-op.
            PlanAnalyzerSheet()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Here's your plan")
                .font(.largeTitle.bold())
            Text("Built from your height, weight, age and activity. Everything here is editable in Settings later.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func planCard(_ draft: GoalDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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

    private var refineCard: some View {
        Button {
            OnboardingAnalytics.track(.planRefineOpened)
            showRefine = true
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Refine with AI")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Tell Claude about your eating habits and it'll tune the split around them.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var disclaimer: some View {
        note(
            "These targets are an estimate and don't account for medical conditions that limiting your calories or setting a workout goal could affect. Talk to your primary care provider before starting any significant change to your diet or fitness routine.",
            icon: "exclamationmark.triangle.fill",
            tint: .orange
        )
    }

    private func note(_ text: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial))
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).monospacedDigit() }
    }
}
