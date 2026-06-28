import Foundation

/// Deterministic calorie-needs math for the AI Plan Analyzer. Pure functions, no I/O — the
/// AI narrates and tunes the plan *around* these numbers but never computes them, so the
/// core figures stay reproducible and unit-testable.
///
/// BMR uses the Mifflin–St Jeor equation. Maintenance (TDEE) multiplies BMR by the user's
/// NON-EXERCISE activity level only; deliberate workouts are tracked separately by the plan's
/// workout goal, so folding them in here would double-count exercise. In this app
/// Net = consumed − exercise, and weight is neutral when Net equals non-exercise TDEE — which
/// is why the suggested net is anchored to TDEE rather than to a higher all-in expenditure.
nonisolated enum TDEECalculator {

    /// Basal metabolic rate (kcal/day), Mifflin–St Jeor.
    static func bmr(sex: BiologicalSex, weightKg: Double, heightCm: Double, age: Int) -> Double {
        let base = 10 * weightKg + 6.25 * heightCm - 5 * Double(age)
        switch sex {
        case .male: return base + 5
        case .female: return base - 161
        }
    }

    /// Maintenance energy from everyday (non-exercise) movement.
    static func tdee(bmr: Double, activity: NonExerciseActivityLevel) -> Double {
        bmr * activity.palMultiplier
    }

    /// Hard minimum for a daily NET target. Net excludes workout burn, so this isn't a "below
    /// BMR" floor (that would conflate net with gross intake and wipe out a sane deficit for
    /// sedentary people, whose BMR ≈ TDEE) — it's the widely-used "don't target below 1,200
    /// kcal" safety floor applied to the net figure.
    static let netFloor = 1_200

    /// Suggested daily NET calorie target for a pace: TDEE minus the pace's deficit, floored at
    /// `netFloor`. The caller compares the returned value against `tdee - pace.dailyDeficit` to
    /// tell whether the floor clamped an aggressive pace, and surfaces that in the narrative.
    static func suggestedNet(tdee: Double, pace: WeightGoalPace) -> Int {
        let target = Int((tdee - Double(pace.dailyDeficit)).rounded())
        return max(netFloor, target)
    }
}
