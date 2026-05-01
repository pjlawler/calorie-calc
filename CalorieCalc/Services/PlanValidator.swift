import Foundation

/// Sanity-checks a `GoalDraft` before the user commits it. Catches the two failure modes the
/// math is prone to:
///
/// 1. **Bonus day goes negative.** If you pile too much eating on bank days (high `gross`,
///    low `workout`), the week's calorie total runs over before bonus days even start. The
///    bonus-day net comes out negative — meaning you'd have to "un-eat" calories on the
///    weekend for the average to land.
/// 2. **7/0 with mismatched gross.** With no bonus days to absorb slack, the bank-day net
///    *must* equal the daily-net target exactly. Any deviation means the weekly average
///    won't land on the goal.
///
/// Plus low-but-not-impossible cases ("you'd be eating 600 kcal on bonus days") get flagged
/// as cautions so the user can keep going if they really want to.
enum PlanValidator {

    enum Severity {
        case caution
        case error
    }

    enum Issue: Hashable {
        /// Bonus-day net is negative — e.g. plan implies eating −400 kcal/day on bonus days.
        case bonusDayNetNegative(net: Int)
        /// Bonus-day gross is negative — even after adding the workout burn back, you'd need
        /// to eat negative calories.
        case bonusDayGrossNegative(gross: Int)
        /// 7/0 split where bank-day net doesn't equal the daily-net goal.
        case sevenZeroMismatch(impliedNet: Int, target: Int)
        /// Bank-day net falls below 1,000 kcal.
        case bankDayNetLow(net: Int)
        /// Bank-day gross falls below 1,000 kcal (user set this directly).
        case bankDayGrossLow(gross: Int)
        /// Bonus-day net falls below 1,000 kcal.
        case bonusDayNetLow(net: Int)
        /// Bonus-day gross falls below 1,000 kcal.
        case bonusDayGrossLow(gross: Int)

        var severity: Severity {
            switch self {
            case .bonusDayNetNegative, .bonusDayGrossNegative, .sevenZeroMismatch:
                return .error
            case .bankDayNetLow, .bankDayGrossLow, .bonusDayNetLow, .bonusDayGrossLow:
                return .caution
            }
        }

        /// One-line summary for the alert dialog.
        var message: String {
            switch self {
            case .bonusDayNetNegative(let net):
                return "Bonus-day net comes out to \(net) kcal — you'd have to un-eat calories. Lower bank-day gross or raise the daily-net goal."
            case .bonusDayGrossNegative(let gross):
                return "Bonus-day gross comes out to \(gross) kcal — math impossible. Lower bank-day gross or raise the daily-net goal."
            case .sevenZeroMismatch(let implied, let target):
                let direction = implied > target ? "over" : "under"
                return "With a 7/0 split, bank-day net (\(implied) kcal) must equal the daily-net goal (\(target) kcal). You're currently \(direction) by \(abs(implied - target)) kcal/day — the average won't land on target."
            case .bankDayNetLow(let net):
                return "Bank-day net is only \(net) kcal — that's a hard floor for energy and adherence."
            case .bankDayGrossLow(let gross):
                return "Bank-day gross is only \(gross) kcal — under 1,000 is hard to sustain."
            case .bonusDayNetLow(let net):
                return "Bonus-day net is only \(net) kcal — under 1,000 is hard to sustain."
            case .bonusDayGrossLow(let gross):
                return "Bonus-day gross is only \(gross) kcal — under 1,000 is hard to sustain."
            }
        }
    }

    /// Result bundle. `severity` is the highest-severity issue across all of them; `nil` when
    /// the draft is fine.
    struct Result {
        let issues: [Issue]
        var severity: Severity? {
            if issues.contains(where: { $0.severity == .error }) { return .error }
            if !issues.isEmpty { return .caution }
            return nil
        }
        var hasIssues: Bool { !issues.isEmpty }
    }

    static func validate(draft: GoalDraft) -> Result {
        var issues: [Issue] = []
        let dailyNet = Double(draft.dailyNetCalorieGoal)
        let bankGross = Double(draft.dailyGrossCalorieGoal)
        let workout = Double(draft.dailyWorkoutCalorieGoal)
        let bankDays = Double(draft.bankSplit.bankingDayCount)
        let bonusDays = 7 - bankDays

        let bankNet = bankGross - workout
        let weeklyTarget = dailyNet * 7

        // Bank-day cautions.
        if bankNet < 1000 {
            issues.append(.bankDayNetLow(net: Int(bankNet.rounded())))
        }
        if bankGross < 1000 {
            issues.append(.bankDayGrossLow(gross: Int(bankGross.rounded())))
        }

        if bonusDays == 0 {
            // 7/0: bank-day net must equal the daily-net target exactly. We allow ~1 kcal/day
            // of float for rounding, since the goals are integers.
            let weeklyImplied = bankDays * bankNet
            if abs(weeklyImplied - weeklyTarget) > 1 {
                issues.append(.sevenZeroMismatch(
                    impliedNet: Int(bankNet.rounded()),
                    target: Int(dailyNet.rounded())
                ))
            }
        } else {
            let bonusNet = (weeklyTarget - bankDays * bankNet) / bonusDays
            let bonusGross = bonusNet + workout
            if bonusNet < 0 {
                issues.append(.bonusDayNetNegative(net: Int(bonusNet.rounded())))
            }
            if bonusGross < 0 {
                issues.append(.bonusDayGrossNegative(gross: Int(bonusGross.rounded())))
            }
            if bonusNet >= 0 && bonusNet < 1000 {
                issues.append(.bonusDayNetLow(net: Int(bonusNet.rounded())))
            }
            if bonusGross >= 0 && bonusGross < 1000 {
                issues.append(.bonusDayGrossLow(gross: Int(bonusGross.rounded())))
            }
        }

        return Result(issues: issues)
    }
}
