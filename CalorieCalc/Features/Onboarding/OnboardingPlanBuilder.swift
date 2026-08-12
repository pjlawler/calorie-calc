import Foundation

/// Turns onboarding's answers into a concrete plan with no AI in the loop.
///
/// This is the path that must *always* be able to finish the flow. Consent refused, offline,
/// request failed, out of credits — the user still lands on a real plan instead of a dead end.
/// The AI refine step layers on top of this; it never replaces it.
nonisolated enum OnboardingPlanBuilder {

    /// How far the banking-day eating goal sits below the average daily allowance
    /// (`net + workout`). Everything held back across the banking days funds the off day, so this
    /// constant is what makes the bonus day meaningful instead of the plan being a flat seven-day
    /// target. 350 reproduces the shape of the app's shipped default profile (2,000 net / 1,800
    /// gross / 150 workout on a 6/1 split).
    static let bankingReserve = 350

    struct Inputs: Equatable, Sendable {
        var sex: BiologicalSex
        var weightKg: Double
        var heightCm: Double
        var age: Int
        var activity: NonExerciseActivityLevel
        var pace: WeightGoalPace
        var workoutCalorieGoal: Int
    }

    struct Plan: Equatable, Sendable {
        var bmr: Int
        var tdee: Int
        var dailyNetCalorieGoal: Int
        var dailyGrossCalorieGoal: Int
        var dailyWorkoutCalorieGoal: Int
        /// True when `TDEECalculator.netFloor` clamped the pace the user asked for, so the UI can
        /// say why the plan is gentler than the option they picked.
        var netWasFloored: Bool
    }

    static func plan(for inputs: Inputs) -> Plan {
        let bmr = TDEECalculator.bmr(
            sex: inputs.sex,
            weightKg: inputs.weightKg,
            heightCm: inputs.heightCm,
            age: inputs.age
        )
        let tdee = TDEECalculator.tdee(bmr: bmr, activity: inputs.activity)
        let net = TDEECalculator.suggestedNet(tdee: tdee, pace: inputs.pace)
        let requestedNet = Int((tdee - Double(inputs.pace.dailyDeficit)).rounded())
        let workout = max(0, inputs.workoutCalorieGoal)
        // Hold the eating goal at the same safety floor the net target respects. Without this, a
        // net that was already floored would have the full reserve subtracted from it and
        // prescribe an unsafe day on every banking day.
        let gross = max(TDEECalculator.netFloor, net + workout - bankingReserve)

        return Plan(
            bmr: Int(bmr.rounded()),
            tdee: Int(tdee.rounded()),
            dailyNetCalorieGoal: net,
            dailyGrossCalorieGoal: gross,
            dailyWorkoutCalorieGoal: workout,
            netWasFloored: net > requestedNet
        )
    }

    /// Writes the computed figures onto a draft, leaving `bankSplit` / `weekStart` at whatever the
    /// profile already carries so onboarding never silently overrides a split the user picked.
    static func apply(_ plan: Plan, to draft: inout GoalDraft) {
        draft.dailyNetCalorieGoal = plan.dailyNetCalorieGoal
        draft.dailyGrossCalorieGoal = plan.dailyGrossCalorieGoal
        draft.dailyWorkoutCalorieGoal = plan.dailyWorkoutCalorieGoal
    }
}
