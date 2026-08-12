import Foundation

/// Everything the first-run flow collects, held in one place so stepping backwards never loses an
/// answer. Deliberately holds no SwiftData objects — nothing is written to the store until the
/// plan step commits, so abandoning the flow leaves no half-built profile behind.
@MainActor
@Observable
final class OnboardingState {

    // MARK: Step 1 — goal

    var pace: WeightGoalPace?

    // MARK: Step 2 — about you

    var sex: BiologicalSex?
    var age = 35
    /// Height is entered in whichever system the user picked; both representations are kept so
    /// toggling units mid-flow doesn't round-trip the value into nonsense.
    var heightCm = 175.0
    var heightTotalInches = 69
    var weight = 0.0
    var goalWeight = 0.0
    var activity: NonExerciseActivityLevel = .sedentary
    var workoutGoal = 150

    /// Mirrors `UserProfile.weightUnit`; seeded from the device locale on first appearance.
    var weightUnit: WeightUnit = .pounds

    var isMetric: Bool { weightUnit == .kilograms }

    // MARK: Derived

    var resolvedHeightCm: Double {
        isMetric ? heightCm : Double(heightTotalInches) * 2.54
    }

    var weightKg: Double {
        weightUnit.convert(weight, to: .kilograms)
    }

    var profileIsComplete: Bool {
        sex != nil && weight > 0
    }

    /// `nil` until the user has answered enough to compute a plan.
    var planInputs: OnboardingPlanBuilder.Inputs? {
        guard let sex, let pace, weight > 0 else { return nil }
        return OnboardingPlanBuilder.Inputs(
            sex: sex,
            weightKg: weightKg,
            heightCm: resolvedHeightCm,
            age: age,
            activity: activity,
            pace: pace,
            workoutCalorieGoal: workoutGoal
        )
    }

    /// Seeds units and a plausible starting weight from the device locale, so the very first
    /// screen a user sees is already in their measurement system. Called once, on appear.
    func seedDefaultsFromLocale(_ locale: Locale = .current) {
        weightUnit = locale.measurementSystem == .metric ? .kilograms : .pounds
        if weight <= 0 { weight = isMetric ? 75 : 170 }
    }
}
