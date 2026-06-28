import Foundation
import Testing
@testable import CalorieCalc

@Suite("TDEECalculator")
struct TDEECalculatorTests {

    @Test("BMR matches Mifflin–St Jeor for a male")
    func bmrMale() {
        // 10*80 + 6.25*180 - 5*30 + 5 = 800 + 1125 - 150 + 5 = 1780
        let bmr = TDEECalculator.bmr(sex: .male, weightKg: 80, heightCm: 180, age: 30)
        #expect(abs(bmr - 1780) < 0.0001)
    }

    @Test("BMR matches Mifflin–St Jeor for a female")
    func bmrFemale() {
        // 10*60 + 6.25*165 - 5*30 - 161 = 600 + 1031.25 - 150 - 161 = 1320.25
        let bmr = TDEECalculator.bmr(sex: .female, weightKg: 60, heightCm: 165, age: 30)
        #expect(abs(bmr - 1320.25) < 0.0001)
    }

    @Test("TDEE applies the activity multiplier")
    func tdeeMultiplier() {
        let bmr = 1780.0
        #expect(abs(TDEECalculator.tdee(bmr: bmr, activity: .sedentary) - 1780 * 1.2) < 0.0001)
        #expect(abs(TDEECalculator.tdee(bmr: bmr, activity: .veryHigh) - 1780 * 1.9) < 0.0001)
    }

    @Test("Suggested net subtracts the pace deficit when above the floor")
    func suggestedNetNormal() {
        // moderate deficit 500 from a 2500 TDEE → 2000, well above the 1200 floor
        #expect(TDEECalculator.suggestedNet(tdee: 2500, pace: .moderate) == 2000)
        // maintain keeps TDEE
        #expect(TDEECalculator.suggestedNet(tdee: 2500, pace: .maintain) == 2500)
    }

    @Test("Suggested net is floored at 1,200 for an aggressive pace on a small person")
    func suggestedNetFloored() {
        // small person: TDEE 1800, aggressive deficit 1000 → 800, clamped up to the 1200 floor
        let net = TDEECalculator.suggestedNet(tdee: 1800, pace: .aggressive)
        #expect(net == TDEECalculator.netFloor)
        #expect(net == 1200)
    }
}
