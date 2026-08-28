import Foundation
import Testing
@testable import UsageMeterCore

@Suite("百分比與刻度")
struct UsedPercentTests {

    @Test("remainingPercent = clamp(100 - percent, 0, 100)", arguments: [
        (0.0, 0, 100), (1.0, 1, 99), (29.0, 29, 71), (50.0, 50, 50), (100.0, 100, 0),
    ])
    func remainingFormula(used: Double, expectedUsed: Int, expectedRemaining: Int) {
        let percent = UsedPercent(hundredScale: used)
        #expect(percent.usedPercent == expectedUsed)
        #expect(percent.remainingPercent == expectedRemaining)
    }

    @Test("超出範圍的值被夾住，不會產生負剩餘或 >100%")
    func clamping() {
        #expect(UsedPercent(hundredScale: 140).remainingPercent == 0)
        #expect(UsedPercent(hundredScale: -20).remainingPercent == 100)
    }

    @Test("非有限值不會產生越界結果（防禦性；解碼器不會讓它走到這裡）")
    func nonFiniteStaysInRange() {
        // The decoder rejects a non-finite percent outright, because clamping one
        // would have to invent a direction. This only guards the type itself.
        for value in [Double.nan, .infinity, -.infinity] {
            let percent = UsedPercent(hundredScale: value)
            #expect((0...100).contains(percent.remainingPercent))
            #expect((0...100).contains(percent.usedPercent))
        }
    }

    @Test("0–1 刻度換算後的浮點誤差在顯示前被吸收")
    func unitScaleRounding() {
        // 0.29 * 100 == 28.999999999999996 in binary floating point. The stored value
        // keeps the error; the displayed integer must not.
        let percent = UsedPercent(unitScale: 0.29)
        #expect(percent.normalized != 29.0)
        #expect(percent.usedPercent == 29)
        #expect(percent.remainingPercent == 71)
    }

    @Test("同一個數字在兩種刻度下得到相同結果")
    func scalesAgree() {
        #expect(UsedPercent(unitScale: 0.62).usedPercent == UsedPercent(hundredScale: 62).usedPercent)
        #expect(UsedPercent(unitScale: 0.0).remainingPercent == 100)
        #expect(UsedPercent(unitScale: 1.0).remainingPercent == 0)
    }

    @Test("刻度來源被保留，供診斷用")
    func scaleProvenance() {
        #expect(UsedPercent(hundredScale: 29).originalScale == .hundred)
        #expect(UsedPercent(unitScale: 0.29).originalScale == .unit)
    }

    @Test("填色高度與顯示的百分比永遠一致")
    func fillFractionMatchesDisplayedNumber() {
        let percent = UsedPercent(unitScale: 0.29)
        #expect(percent.usedFraction == Double(percent.usedPercent) / 100)
        #expect(percent.remainingFraction == Double(percent.remainingPercent) / 100)
    }

    @Test("已用與剩餘互補，加起來永遠是 100")
    func usedAndRemainingAreComplements() {
        for raw in stride(from: 0.0, through: 100.0, by: 7.0) {
            let percent = UsedPercent(hundredScale: raw)
            #expect(percent.usedPercent + percent.remainingPercent == 100)
        }
    }
}
