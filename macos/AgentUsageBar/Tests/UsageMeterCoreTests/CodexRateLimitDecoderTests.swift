import Foundation
import Testing
@testable import UsageMeterCore

@Suite("Codex rate-limit 解碼")
struct CodexRateLimitDecoderTests {
    let now = Date(timeIntervalSince1970: 1_755_500_000)

    private var typical: Data {
        Data(#"""
        {
          "rateLimits": {
            "limitId": "codex",
            "primary": {"usedPercent": 99, "windowDurationMins": 5, "resetsAt": 1730000000}
          },
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "limitName": null,
              "primary": {"usedPercent": 25, "windowDurationMins": 15, "resetsAt": 1730947200},
              "secondary": {"usedPercent": 62, "windowDurationMins": 10080, "resetsAt": 1730950800},
              "credits": {"hasCredits": true, "unlimited": false, "balance": "12.50"},
              "planType": "plus",
              "rateLimitReachedType": null,
              "spendControlReached": false
            },
            "codex_other": {
              "limitId": "codex_other",
              "primary": {"usedPercent": 88, "windowDurationMins": 60, "resetsAt": 1730950800}
            }
          },
          "rateLimitResetCredits": {"availableCount": 2},
          "futureField": true
        }
        """#.utf8)
    }

    @Test("優先解析一般 codex bucket，保留 Credits 與診斷欄位")
    func typicalResponse() throws {
        let snapshot = try CodexRateLimitDecoder.decode(
            typical,
            fetchedAt: now,
            serverUserAgent: "codex-cli/0.148.0"
        )
        #expect(snapshot.provider == .codex)
        #expect(snapshot.sourcePath == .codexAppServer)
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.meteredLimitID == "codex")
        #expect(snapshot.planType == "plus")
        #expect(snapshot.credits?.balance == "12.50")
        #expect(snapshot.credits?.displayDescription == "12.50")
        #expect(snapshot.sourceVersion == "codex-cli/0.148.0")

        let primary = try #require(snapshot.windows.first { $0.isActive })
        #expect(primary.used.usedPercent == 25)
        #expect(primary.used.remainingPercent == 75)
        #expect(primary.displayName == "15 minutes")
        #expect(primary.resetsAt == Date(timeIntervalSince1970: 1_730_947_200))

        let secondary = try #require(snapshot.windows.first { $0.kind == .weeklyAll })
        #expect(secondary.used.usedPercent == 62)
        #expect(secondary.displayName == "7 days")
        #expect(snapshot.windows.allSatisfy { $0.used.usedPercent != 88 })
    }

    @Test("multi-bucket 缺少 codex 時退回單一 rateLimits")
    func backwardCompatibleFallback() throws {
        let data = Data(#"""
        {
          "rateLimits": {"primary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":1730947200}},
          "rateLimitsByLimitId": {"spark":{"primary":{"usedPercent":90}}}
        }
        """#.utf8)
        let snapshot = try CodexRateLimitDecoder.decode(data, fetchedAt: now)
        #expect(snapshot.representativeWindow?.used.usedPercent == 40)
        #expect(snapshot.representativeWindow?.displayName == "5 hours")
    }

    @Test("推播的 sparse params 也能解碼")
    func rollingNotification() throws {
        let data = Data(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":31,"windowDurationMins":15,"resetsAt":1730948100}}}"#.utf8)
        let snapshot = try CodexRateLimitDecoder.decode(data, fetchedAt: now)
        #expect(snapshot.representativeWindow?.used.usedPercent == 31)
        #expect(snapshot.credits == nil)
    }

    @Test("範圍外或非整數百分比一律拒絕，不 clamp 成可信數字")
    func invalidPercentagesFailClosed() {
        for invalid in [
            #"{"rateLimits":{"primary":{"usedPercent":-7}}}"#,
            #"{"rateLimits":{"primary":{"usedPercent":120}}}"#,
            #"{"rateLimits":{"primary":{"usedPercent":42.5}}}"#,
            #"{"rateLimits":{"primary":{"usedPercent":"25"}}}"#,
            #"{"rateLimits":{"primary":null}}"#,
            #"not-json"#,
        ] {
            #expect(throws: UsageError.self) {
                _ = try CodexRateLimitDecoder.decode(Data(invalid.utf8), fetchedAt: now)
            }
        }
    }

    @Test("格式錯誤不會把 provider 控制的 JSON key 顯示給使用者")
    func malformedResponseDoesNotExposeProviderControlledKeys() {
        let marker = "token-secret-marker"
        let data = Data("{\"\(marker)\":true}".utf8)

        do {
            _ = try CodexRateLimitDecoder.decode(data, fetchedAt: now)
            Issue.record("Expected a schema error")
        } catch let error as UsageError {
            #expect(error.remedy?.contains(marker) == false)
            #expect(error.remedy(locale: Locale(identifier: "zh_Hant_TW"))?.contains(marker) == false)
        } catch {
            Issue.record("Expected UsageError")
        }
    }

    @Test("宣告為整數的 optional 欄位不可截斷小數")
    func nonIntegralOptionalIntegersAreRejected() {
        for invalid in [
            #"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300.5}}}"#,
            #"{"rateLimits":{"primary":{"usedPercent":25,"resetsAt":1730947200.5}}}"#,
        ] {
            #expect(throws: UsageError.self) {
                _ = try CodexRateLimitDecoder.decode(Data(invalid.utf8), fetchedAt: now)
            }
        }
    }

    @Test("Credits 缺值、無上限、零餘額保持不同語意")
    func creditVariants() throws {
        let unlimited = Data(#"{"rateLimits":{"primary":{"usedPercent":1},"credits":{"hasCredits":true,"unlimited":true,"balance":null}}}"#.utf8)
        let none = Data(#"{"rateLimits":{"primary":{"usedPercent":1},"credits":{"hasCredits":false,"unlimited":false,"balance":null}}}"#.utf8)
        #expect(try CodexRateLimitDecoder.decode(unlimited, fetchedAt: now).credits?.displayDescription == "Unlimited")
        #expect(try CodexRateLimitDecoder.decode(none, fetchedAt: now).credits?.displayDescription == "No available Credits")
        #expect(try CodexRateLimitDecoder.decode(Data(#"{"rateLimits":{"primary":{"usedPercent":1}}}"#.utf8), fetchedAt: now).credits == nil)
    }

    @Test("供應商顯示文字過長或含控制方向的字元時不進入快照")
    func unsafeDisplayMetadataIsDiscarded() throws {
        let oversized = String(repeating: "x", count: 513)
        let object: [String: Any] = [
            "rateLimits": [
                "limitId": "codex",
                "primary": ["usedPercent": 25],
                "planType": oversized,
                "rateLimitReachedType": "primary\u{202E}hidden",
                "credits": [
                    "hasCredits": true,
                    "unlimited": false,
                    "balance": "12.50\nsecret",
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)

        let snapshot = try CodexRateLimitDecoder.decode(
            data,
            fetchedAt: now,
            serverUserAgent: oversized
        )

        #expect(snapshot.planType == nil)
        #expect(snapshot.rateLimitReachedType == nil)
        #expect(snapshot.credits?.balance == nil)
        #expect(snapshot.sourceVersion == nil)
    }

    @Test("limitId 是語意識別字，格式不安全時整份拒絕")
    func unsafeLimitIDFailsClosed() throws {
        let object: [String: Any] = [
            "rateLimits": [
                "limitId": "codex\nother",
                "primary": ["usedPercent": 25],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: UsageError.self) {
            _ = try CodexRateLimitDecoder.decode(data, fetchedAt: now)
        }
    }
}
