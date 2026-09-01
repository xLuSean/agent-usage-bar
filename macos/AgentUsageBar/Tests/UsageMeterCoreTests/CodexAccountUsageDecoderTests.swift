import Foundation
import Testing
@testable import UsageMeterCore

@Suite("Codex 帳號 Token 用量解碼")
struct CodexAccountUsageDecoderTests {
    @Test("保留官方總量並依日期排序每日資料")
    func decodesDocumentedResponse() throws {
        let data = Data(#"""
        {
          "summary": {
            "lifetimeTokens": 6012800208,
            "peakDailyTokens": 412649517,
            "currentStreakDays": 61
          },
          "dailyUsageBuckets": [
            {"startDate":"2026-08-31","tokens":120},
            {"startDate":"2026-08-29","tokens":80},
            {"startDate":"2026-08-30","tokens":0}
          ],
          "threadUsage": null
        }
        """#.utf8)

        let usage = try CodexAccountUsageDecoder.decode(data)

        #expect(usage.lifetimeTokens == 6_012_800_208)
        #expect(usage.peakDailyTokens == 412_649_517)
        #expect(usage.dailyUsageBuckets.map(\.startDate) == [
            "2026-08-29", "2026-08-30", "2026-08-31",
        ])
        #expect(usage.dailyUsageBuckets.map(\.tokens) == [80, 0, 120])
        #expect(usage.updatedThrough == "2026-08-31")
        #expect(usage.isValid)
    }

    @Test("文件允許的 null 不會被假裝成零")
    func preservesNullAsUnavailable() throws {
        let usage = try CodexAccountUsageDecoder.decode(Data(
            #"{"summary":{"lifetimeTokens":null,"peakDailyTokens":null},"dailyUsageBuckets":null}"#.utf8
        ))

        #expect(usage.lifetimeTokens == nil)
        #expect(usage.peakDailyTokens == nil)
        #expect(usage.dailyUsageBuckets.isEmpty)
        #expect(usage.updatedThrough == nil)
    }

    @Test("圖表範圍只取最新資料，不修改完整帳號歷史")
    func returnsMostRecentDisplaySlice() throws {
        let usage = try CodexAccountUsageDecoder.decode(Data(#"""
        {
          "dailyUsageBuckets": [
            {"startDate":"2026-08-29","tokens":10},
            {"startDate":"2026-08-30","tokens":20},
            {"startDate":"2026-08-31","tokens":30}
          ]
        }
        """#.utf8))

        #expect(usage.mostRecentDailyBuckets(limit: 2).map(\.tokens) == [20, 30])
        #expect(usage.mostRecentDailyBuckets(limit: 0).isEmpty)
        #expect(usage.mostRecentDailyBuckets(limit: 20) == usage.dailyUsageBuckets)
        #expect(usage.dailyUsageBuckets.count == 3)
    }

    @Test("今天依這台 Mac 的日曆日期查找，缺值不假裝成零")
    func findsTodayWithoutInventingMissingUsage() throws {
        let usage = try CodexAccountUsageDecoder.decode(Data(#"""
        {
          "dailyUsageBuckets": [
            {"startDate":"2026-08-31","tokens":31},
            {"startDate":"2026-09-01","tokens":91}
          ]
        }
        """#.utf8))
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-09-01T00:30:00Z"))

        #expect(usage.tokens(on: instant, timeZone: TimeZone(secondsFromGMT: 0)!) == 91)
        #expect(usage.tokens(on: instant, timeZone: TimeZone(identifier: "America/Los_Angeles")!) == 31)
        #expect(usage.tokens(
            on: instant.addingTimeInterval(86_400),
            timeZone: TimeZone(secondsFromGMT: 0)!
        ) == nil)
    }

    @Test(
        "負數、小數、無效日期與重複日期一律拒絕",
        arguments: [
            #"{"summary":{"lifetimeTokens":-1},"dailyUsageBuckets":[]}"#,
            #"{"summary":{"peakDailyTokens":1.5},"dailyUsageBuckets":[]}"#,
            #"{"summary":{},"dailyUsageBuckets":[{"startDate":"2026-02-30","tokens":1}]}"#,
            #"{"summary":{},"dailyUsageBuckets":[{"startDate":"2026-08-01","tokens":1},{"startDate":"2026-08-01","tokens":2}]}"#,
            #"{"summary":{},"dailyUsageBuckets":[{"startDate":"2026-08-01","tokens":-1}]}"#,
        ]
    )
    func rejectsMalformedValues(json: String) {
        #expect(throws: UsageError.self) {
            try CodexAccountUsageDecoder.decode(Data(json.utf8))
        }
    }

    @Test("沒有文件欄位的物件不是空白用量")
    func rejectsUnrelatedObject() {
        #expect(throws: UsageError.self) {
            try CodexAccountUsageDecoder.decode(Data(#"{"threadUsage":null}"#.utf8))
        }
    }
}
