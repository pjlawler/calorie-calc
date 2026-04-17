import Foundation
import Testing
@testable import calorie_calc

@Suite("CalorieBankCalculator")
struct CalorieBankCalculatorTests {

    private let plan = WeeklyPlan(
        dailyNetCalorieGoal: 1_600,
        dailyGrossCalorieGoal: 1_800,
        dailyWorkoutCalorieGoal: 500
    )

    private func banking(_ day: Weekday, status: DayStatus, consumed: Double = 0, burned: Double = 0) -> DayInput {
        DayInput(
            weekday: day,
            isBankingDay: true,
            status: status,
            consumedCalories: consumed,
            burnedCalories: burned,
            hasLoggedData: consumed > 0 || burned > 0
        )
    }

    private func off(_ day: Weekday, status: DayStatus, consumed: Double = 0, burned: Double = 0) -> DayInput {
        DayInput(
            weekday: day,
            isBankingDay: false,
            status: status,
            consumedCalories: consumed,
            burnedCalories: burned,
            hasLoggedData: consumed > 0 || burned > 0
        )
    }

    @Test("Exact-plan week: all 7 days future, no actuals yet — matches the prompt's worked example")
    func exactPlanAllFuture() {
        let days: [DayInput] = [
            banking(.monday, status: .future),
            banking(.tuesday, status: .future),
            banking(.wednesday, status: .future),
            banking(.thursday, status: .future),
            banking(.friday, status: .future),
            off(.saturday, status: .future),
            off(.sunday, status: .future),
        ]

        let result = CalorieBankCalculator.calculate(plan: plan, days: days)

        #expect(result.weeklyNetTarget == 11_200)
        #expect(result.weeklyGrossAllowance == 14_700)
        #expect(result.caloriesAlreadyEaten == 0)
        #expect(result.committedToBankingDays == 9_000)
        #expect(result.offDayBank == 5_700)
        #expect(result.totalOffDaysInWeek == 2)
        #expect(result.perOffDayBudget == 2_850)
        #expect(result.plannedPerOffDayBudget == 2_850)
        #expect(result.runningWeeklyNetActual == 0)
    }

    @Test("Overeating on a banking day shrinks the off-day bank 1:1")
    func overeatingOnBankingDay() {
        let days: [DayInput] = [
            banking(.monday, status: .past, consumed: 1_800, burned: 500),
            banking(.tuesday, status: .past, consumed: 2_000, burned: 500),
            banking(.wednesday, status: .future),
            banking(.thursday, status: .future),
            banking(.friday, status: .future),
            off(.saturday, status: .future),
            off(.sunday, status: .future),
        ]

        let result = CalorieBankCalculator.calculate(plan: plan, days: days)

        #expect(result.weeklyGrossAllowance == 14_700)
        #expect(result.caloriesAlreadyEaten == 3_800)
        #expect(result.committedToBankingDays == 5_400)
        #expect(result.offDayBank == 5_500)
        #expect(result.perOffDayBudget == 2_750)
    }

    @Test("Undereating on a banking day grows the off-day bank 1:1")
    func undereatingOnBankingDay() {
        let days: [DayInput] = [
            banking(.monday, status: .past, consumed: 1_800, burned: 500),
            banking(.tuesday, status: .past, consumed: 1_600, burned: 500),
            banking(.wednesday, status: .future),
            banking(.thursday, status: .future),
            banking(.friday, status: .future),
            off(.saturday, status: .future),
            off(.sunday, status: .future),
        ]

        let result = CalorieBankCalculator.calculate(plan: plan, days: days)

        #expect(result.caloriesAlreadyEaten == 3_400)
        #expect(result.offDayBank == 5_900)
        #expect(result.perOffDayBudget == 2_950)
    }

    @Test("Skipping a workout shrinks the allowance and bank by the workout goal")
    func skippedWorkout() {
        let days: [DayInput] = [
            banking(.monday, status: .past, consumed: 1_800, burned: 500),
            banking(.tuesday, status: .past, consumed: 1_800, burned: 0),
            banking(.wednesday, status: .future),
            banking(.thursday, status: .future),
            banking(.friday, status: .future),
            off(.saturday, status: .future),
            off(.sunday, status: .future),
        ]

        let result = CalorieBankCalculator.calculate(plan: plan, days: days)

        #expect(result.weeklyGrossAllowance == 14_200)
        #expect(result.offDayBank == 5_200)
        #expect(result.perOffDayBudget == 2_600)
    }

    @Test("Extra workout grows the allowance and bank")
    func extraWorkout() {
        let days: [DayInput] = [
            banking(.monday, status: .past, consumed: 1_800, burned: 500),
            banking(.tuesday, status: .past, consumed: 1_800, burned: 700),
            banking(.wednesday, status: .future),
            banking(.thursday, status: .future),
            banking(.friday, status: .future),
            off(.saturday, status: .future),
            off(.sunday, status: .future),
        ]

        let result = CalorieBankCalculator.calculate(plan: plan, days: days)

        #expect(result.weeklyGrossAllowance == 14_900)
        #expect(result.offDayBank == 5_900)
        #expect(result.perOffDayBudget == 2_950)
    }

    @Test("Mid-week recalc: Wed today with Mon/Tue actuals; today burn floored at workout goal")
    func midWeekRecalculation() {
        let days: [DayInput] = [
            banking(.monday, status: .past, consumed: 1_800, burned: 500),
            banking(.tuesday, status: .past, consumed: 1_800, burned: 500),
            banking(.wednesday, status: .today, consumed: 1_000, burned: 200),
            banking(.thursday, status: .future),
            banking(.friday, status: .future),
            off(.saturday, status: .future),
            off(.sunday, status: .future),
        ]

        let result = CalorieBankCalculator.calculate(plan: plan, days: days)

        // Today's actual burn is 200, less than the 500 workout goal — the calculator uses max(actual, goal)
        // for today so the bank doesn't collapse mid-day while the user still has time to finish the workout.
        // Burn: 500(Mon) + 500(Tue) + 500(Wed-floor) + 500×4(future) = 3,500 → allowance 14,700.
        #expect(result.weeklyGrossAllowance == 14_700)
        #expect(result.caloriesAlreadyEaten == 4_600)
        #expect(result.committedToBankingDays == 4_400)
        #expect(result.offDayBank == 5_700)
        #expect(result.perOffDayBudget == 2_850)
        // Running-net uses real actuals (not the max floor) so the weekly summary reflects reality.
        #expect(result.runningWeeklyNetActual == 3_400)
    }

    @Test("7/0 split — no off days means no per-off-day budget")
    func sevenZeroSplit() {
        let days: [DayInput] = [
            banking(.monday, status: .future),
            banking(.tuesday, status: .future),
            banking(.wednesday, status: .future),
            banking(.thursday, status: .future),
            banking(.friday, status: .future),
            banking(.saturday, status: .future),
            banking(.sunday, status: .future),
        ]

        let result = CalorieBankCalculator.calculate(plan: plan, days: days)

        #expect(result.totalOffDaysInWeek == 0)
        #expect(result.perOffDayBudget == nil)
        #expect(result.plannedPerOffDayBudget == nil)
        #expect(result.committedToBankingDays == 12_600)
        #expect(result.offDayBank == 2_100)
    }

    @Test("Zero workouts all week — past burn is zero, allowance collapses")
    func zeroWorkoutsAllWeek() {
        let days: [DayInput] = [
            banking(.monday, status: .past, consumed: 1_800, burned: 0),
            banking(.tuesday, status: .past, consumed: 1_800, burned: 0),
            banking(.wednesday, status: .past, consumed: 1_800, burned: 0),
            banking(.thursday, status: .past, consumed: 1_800, burned: 0),
            banking(.friday, status: .past, consumed: 1_800, burned: 0),
            off(.saturday, status: .past, consumed: 1_800, burned: 0),
            off(.sunday, status: .past, consumed: 1_800, burned: 0),
        ]

        let result = CalorieBankCalculator.calculate(plan: plan, days: days)

        #expect(result.weeklyGrossAllowance == 11_200)
        #expect(result.caloriesAlreadyEaten == 12_600)
        #expect(result.committedToBankingDays == 0)
        #expect(result.offDayBank == -1_400)
        // Divisor is now total off-days in the week (fixed 2), not remaining off-days.
        #expect(result.perOffDayBudget == -700)
    }

    @Test("Pre-logged workout on a future day credits calories remaining")
    func preLoggedFutureWorkoutCreditsRemaining() {
        let days: [DayInput] = [
            banking(.monday, status: .past, consumed: 1_800, burned: 500),
            banking(.tuesday, status: .future),
            banking(.wednesday, status: .future),
            banking(.thursday, status: .future),
            banking(.friday, status: .future),
            DayInput(weekday: .saturday, isBankingDay: false, status: .future,
                     consumedCalories: 0, burnedCalories: 250, hasLoggedData: true),
            off(.sunday, status: .future),
        ]

        let result = CalorieBankCalculator.calculate(plan: plan, days: days)

        // Running net = Mon (1800 − 500 = 1300) + Sat (0 − 250 = −250) = 1,050
        #expect(result.runningWeeklyNetActual == 1_050)
        #expect(result.daysWithLoggedData == 2)
        // Remaining = 11,200 − 1,050 = 10,150
        #expect(result.weeklyNetTarget - result.runningWeeklyNetActual == 10_150)
    }

    @Test("Workout-only day (exercise, no food) credits calories remaining")
    func workoutOnlyDayCreditsRemaining() {
        let days: [DayInput] = [
            DayInput(weekday: .monday, isBankingDay: true, status: .past,
                     consumedCalories: 0, burnedCalories: 500, hasLoggedData: true),
            banking(.tuesday, status: .future),
            banking(.wednesday, status: .future),
            banking(.thursday, status: .future),
            banking(.friday, status: .future),
            off(.saturday, status: .future),
            off(.sunday, status: .future),
        ]

        let result = CalorieBankCalculator.calculate(plan: plan, days: days)

        // Only logged day: Mon with 0 consumed, 500 burned. Net = -500.
        #expect(result.runningWeeklyNetActual == -500)
        #expect(result.daysWithLoggedData == 1)
        // Calories remaining = target − running net = 11,200 − (-500) = 11,700.
        #expect(result.weeklyNetTarget - result.runningWeeklyNetActual == 11_700)
    }

    @Test("Negative net day — burn exceeds consumption, arithmetic is straightforward")
    func negativeNetDay() {
        let days: [DayInput] = [
            banking(.monday, status: .past, consumed: 0, burned: 500),
            banking(.tuesday, status: .future),
            banking(.wednesday, status: .future),
            banking(.thursday, status: .future),
            banking(.friday, status: .future),
            off(.saturday, status: .future),
            off(.sunday, status: .future),
        ]

        let result = CalorieBankCalculator.calculate(plan: plan, days: days)

        #expect(result.runningWeeklyNetActual == -500)
        let mondayBudget = result.dailyBudgets.first { $0.weekday == .monday }
        #expect(mondayBudget?.net == -500)
    }

    @Test("Daily budgets: banking days show gross goal, off days show dynamic perOffDayBudget")
    func dailyBudgetGrossValues() {
        let days: [DayInput] = [
            banking(.monday, status: .future),
            banking(.tuesday, status: .future),
            banking(.wednesday, status: .future),
            banking(.thursday, status: .future),
            banking(.friday, status: .future),
            off(.saturday, status: .past, consumed: 2_500, burned: 0),
            off(.sunday, status: .future),
        ]

        let result = CalorieBankCalculator.calculate(plan: plan, days: days)

        let monday = result.dailyBudgets.first { $0.weekday == .monday }
        let saturday = result.dailyBudgets.first { $0.weekday == .saturday }
        let sunday = result.dailyBudgets.first { $0.weekday == .sunday }

        #expect(monday?.grossBudget == 1_800)
        // Saturday consumed 2,500 with 0 burn → bank shrinks → both off days reflect dynamic share.
        #expect(saturday?.grossBudget == result.perOffDayBudget)
        #expect(sunday?.grossBudget == result.perOffDayBudget)
        // Sanity: plan-only figure unchanged.
        #expect(result.plannedPerOffDayBudget == 2_850)
    }
}
