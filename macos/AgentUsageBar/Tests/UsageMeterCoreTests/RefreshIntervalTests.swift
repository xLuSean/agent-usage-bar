import Foundation
import Testing
@testable import UsageMeterCore

@Suite("更新頻率")
struct RefreshIntervalTests {

    @Test("更新頻率可依 App 語言顯示")
    func localizedDisplayNames() {
        #expect(RefreshInterval.tenMinutes.displayName(locale: Locale(identifier: "en_US")) == "10 minutes")
        #expect(RefreshInterval.tenMinutes.displayName(locale: Locale(identifier: "zh_Hant_TW")) == "10 分鐘")
    }

    @Test("提供的選項與秒數")
    func options() {
        #expect(RefreshInterval.allCases.map(\.rawValue) == [60, 180, 300, 600, 1800, 3600])
        #expect(RefreshInterval.fiveMinutes.seconds == 300)
    }

    @Test("兩邊都建議 10 分鐘")
    func recommendationsAreProviderSpecific() {
        // Claude retains the conservative value required by its polling-only endpoint;
        // Codex can use a lower-frequency safety poll because it also receives pushes.
        #expect(RefreshInterval.recommended == .tenMinutes)
        #expect(RefreshInterval.recommended(for: .claude) == .tenMinutes)
        #expect(RefreshInterval.recommended(for: .codex) == .tenMinutes)
        #expect(RefreshInterval.tenMinutes.isRecommended(for: .claude))
        #expect(RefreshInterval.tenMinutes.isRecommended(for: .codex))
        #expect(!RefreshInterval.thirtyMinutes.isRecommended(for: .claude))
        #expect(RefreshInterval.recommended(for: .codex).refreshesPerDay == 144)
    }

    @Test("每天更新次數的換算")
    func refreshesPerDay() {
        #expect(RefreshInterval.oneMinute.refreshesPerDay == 1440)
        #expect(RefreshInterval.fiveMinutes.refreshesPerDay == 288)
        #expect(RefreshInterval.oneHour.refreshesPerDay == 24)
    }

    @Test("風險較高的選項會附上說明，建議值不會")
    func cautionsWhereItMatters() {
        #expect(RefreshInterval.oneMinute.caution != nil)
        #expect(RefreshInterval.threeMinutes.caution != nil)
        #expect(RefreshInterval.recommended(for: .claude).caution == nil)
        #expect(RefreshInterval.recommended(for: .codex).caution == nil)
        #expect(RefreshInterval.oneHour.caution == nil)
    }

    @Test("每個間隔都比一次退避的起點長，退避才不會被輪詢蓋過")
    func intervalsExceedInitialBackoff() {
        for interval in RefreshInterval.allCases {
            #expect(interval.seconds >= BackoffPolicy.claude.initial)
        }
    }

    @Test("設定值可往返序列化")
    func roundTrip() {
        for interval in RefreshInterval.allCases {
            #expect(RefreshInterval(rawValue: interval.rawValue) == interval)
        }
        #expect(RefreshInterval(rawValue: 12345) == nil)
    }
}
