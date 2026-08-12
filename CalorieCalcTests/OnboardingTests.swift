import Foundation
import Testing
@testable import CalorieCalc

@Suite("OnboardingGate")
struct OnboardingGateTests {

    private let launch = Date(timeIntervalSince1970: 1_700_000_000)

    private func signals(
        completedAt: Date? = nil,
        profileCreatedAt: Date? = nil,
        hasLoggedFood: Bool = false,
        hasPlanHistory: Bool = false
    ) -> OnboardingGate.Signals {
        OnboardingGate.Signals(
            completedAt: completedAt,
            firstLaunchedAt: launch,
            earliestProfileCreatedAt: profileCreatedAt,
            hasLoggedFood: hasLoggedFood,
            hasPlanHistory: hasPlanHistory
        )
    }

    @Test("Opens on a genuinely fresh install")
    func freshInstall() {
        #expect(OnboardingGate.shouldPresent(signals()))
    }

    @Test("Stays shut once completed")
    func alreadyCompleted() {
        #expect(!OnboardingGate.shouldPresent(signals(completedAt: launch)))
    }

    @Test("Stays open when the profile was created by this launch's own bootstrap")
    func locallyBootstrappedProfileStillOnboards() {
        // WeekCalendarView / Dashboard can win the race and insert the default profile before the
        // gate runs. That must not read as "returning user".
        let justNow = launch.addingTimeInterval(0.4)
        #expect(OnboardingGate.shouldPresent(signals(profileCreatedAt: justNow)))
    }

    @Test("Stays shut for a profile synced in from another device")
    func syncedProfileSkipsOnboarding() {
        let monthsAgo = launch.addingTimeInterval(-60 * 60 * 24 * 90)
        #expect(!OnboardingGate.shouldPresent(signals(profileCreatedAt: monthsAgo)))
    }

    @Test("Grace boundary: just inside stays open, just outside stays shut")
    func graceBoundary() {
        let inside = launch.addingTimeInterval(-OnboardingGate.syncedProfileGrace + 1)
        let outside = launch.addingTimeInterval(-OnboardingGate.syncedProfileGrace - 1)
        #expect(OnboardingGate.shouldPresent(signals(profileCreatedAt: inside)))
        #expect(!OnboardingGate.shouldPresent(signals(profileCreatedAt: outside)))
    }

    @Test("Stays shut when CloudKit has already delivered a food log")
    func existingFoodLogSkipsOnboarding() {
        #expect(!OnboardingGate.shouldPresent(signals(hasLoggedFood: true)))
    }

    @Test("Stays shut when plan history exists")
    func planHistorySkipsOnboarding() {
        #expect(!OnboardingGate.shouldPresent(signals(hasPlanHistory: true)))
    }
}

@Suite("OnboardingPlanBuilder")
@MainActor
struct OnboardingPlanBuilderTests {

    /// 80 kg / 180 cm / 30 / male → BMR 1780, sedentary TDEE 2136.
    private func inputs(
        pace: WeightGoalPace = .moderate,
        activity: NonExerciseActivityLevel = .sedentary,
        workout: Int = 150,
        weightKg: Double = 80
    ) -> OnboardingPlanBuilder.Inputs {
        OnboardingPlanBuilder.Inputs(
            sex: .male,
            weightKg: weightKg,
            heightCm: 180,
            age: 30,
            activity: activity,
            pace: pace,
            workoutCalorieGoal: workout
        )
    }

    @Test("Net target is TDEE minus the pace deficit")
    func netMatchesTDEE() {
        let plan = OnboardingPlanBuilder.plan(for: inputs())
        #expect(plan.bmr == 1780)
        #expect(plan.tdee == 2136)
        #expect(plan.dailyNetCalorieGoal == 2136 - WeightGoalPace.moderate.dailyDeficit)
        #expect(!plan.netWasFloored)
    }

    @Test("Eating goal sits one banking reserve below the daily allowance")
    func grossReservesForTheBonusDay() {
        let plan = OnboardingPlanBuilder.plan(for: inputs())
        let allowance = plan.dailyNetCalorieGoal + plan.dailyWorkoutCalorieGoal
        #expect(plan.dailyGrossCalorieGoal == allowance - OnboardingPlanBuilder.bankingReserve)
        // The whole point of holding calories back: the off day has to come out ahead.
        #expect(plan.dailyGrossCalorieGoal < allowance)
    }

    @Test("Maintain pace leaves the net at maintenance")
    func maintainPace() {
        let plan = OnboardingPlanBuilder.plan(for: inputs(pace: .maintain))
        #expect(plan.dailyNetCalorieGoal == plan.tdee)
    }

    @Test("An aggressive pace on a small person is floored, and says so")
    func aggressivePaceIsFloored() {
        // 45 kg sedentary female-scale BMR keeps TDEE well under floor + 1000.
        let plan = OnboardingPlanBuilder.plan(for: inputs(pace: .aggressive, weightKg: 45))
        #expect(plan.dailyNetCalorieGoal == TDEECalculator.netFloor)
        #expect(plan.netWasFloored)
    }

    @Test("A floored net never drags the eating goal below the same floor")
    func flooredNetKeepsGrossSafe() {
        let plan = OnboardingPlanBuilder.plan(for: inputs(pace: .aggressive, workout: 0, weightKg: 45))
        #expect(plan.dailyGrossCalorieGoal >= TDEECalculator.netFloor)
    }

    @Test("A negative workout goal can't sneak through")
    func workoutGoalIsClamped() {
        let plan = OnboardingPlanBuilder.plan(for: inputs(workout: -500))
        #expect(plan.dailyWorkoutCalorieGoal == 0)
    }

    @Test("Higher activity raises the target")
    func activityRaisesTarget() {
        let sedentary = OnboardingPlanBuilder.plan(for: inputs(activity: .sedentary))
        let active = OnboardingPlanBuilder.plan(for: inputs(activity: .high))
        #expect(active.dailyNetCalorieGoal > sedentary.dailyNetCalorieGoal)
    }

    @Test("Applying a plan leaves the split and week start alone")
    func applyPreservesSplit() {
        let profile = UserProfile(bankSplit: .fourThree, weekStart: .sunday)
        var draft = GoalDraft(from: profile)
        let plan = OnboardingPlanBuilder.plan(for: inputs())
        OnboardingPlanBuilder.apply(plan, to: &draft)

        #expect(draft.dailyNetCalorieGoal == plan.dailyNetCalorieGoal)
        #expect(draft.dailyGrossCalorieGoal == plan.dailyGrossCalorieGoal)
        #expect(draft.dailyWorkoutCalorieGoal == plan.dailyWorkoutCalorieGoal)
        #expect(draft.bankSplit == .fourThree)
        #expect(draft.weekStart == .sunday)
    }

    @Test("The committed plan passes the app's own plan validation")
    func planIsInternallyConsistent() {
        // A plan onboarding hands a brand-new user must not immediately trip the same validator
        // that guards the Settings screen.
        for pace in WeightGoalPace.allCases {
            for activity in NonExerciseActivityLevel.allCases {
                let profile = UserProfile()
                var draft = GoalDraft(from: profile)
                OnboardingPlanBuilder.apply(
                    OnboardingPlanBuilder.plan(for: inputs(pace: pace, activity: activity)),
                    to: &draft
                )
                let result = PlanValidator.validate(draft: draft)
                #expect(
                    result.severity != .error,
                    "\(pace.rawValue)/\(activity.rawValue) produced an invalid plan"
                )
            }
        }
    }
}

@Suite("OnboardingState")
@MainActor
struct OnboardingStateTests {

    @Test("Metric locale seeds kilograms and a metric starting weight")
    func metricSeed() {
        let state = OnboardingState()
        state.seedDefaultsFromLocale(Locale(identifier: "fr_FR"))
        #expect(state.weightUnit == .kilograms)
        #expect(state.weight == 75)
    }

    @Test("US locale seeds pounds")
    func imperialSeed() {
        let state = OnboardingState()
        state.seedDefaultsFromLocale(Locale(identifier: "en_US"))
        #expect(state.weightUnit == .pounds)
        #expect(state.weight == 170)
    }

    @Test("Imperial height converts to centimetres for the calorie math")
    func heightConversion() {
        let state = OnboardingState()
        state.weightUnit = .pounds
        state.heightTotalInches = 70
        #expect(abs(state.resolvedHeightCm - 177.8) < 0.001)
    }

    @Test("Plan inputs stay nil until the flow has enough to compute one")
    func planInputsRequireAnswers() {
        let state = OnboardingState()
        state.seedDefaultsFromLocale(Locale(identifier: "en_US"))
        #expect(state.planInputs == nil)          // no goal, no sex

        state.pace = .moderate
        #expect(state.planInputs == nil)          // still no sex

        state.sex = .female
        #expect(state.planInputs != nil)
    }

    @Test("Weight is converted to kilograms for the calorie math")
    func weightConversion() {
        let state = OnboardingState()
        state.weightUnit = .pounds
        state.weight = 170
        #expect(abs(state.weightKg - 77.1107) < 0.001)
    }
}
