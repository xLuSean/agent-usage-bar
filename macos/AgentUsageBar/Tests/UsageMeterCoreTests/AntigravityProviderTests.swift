import Foundation
import Testing
@testable import UsageMeterCore

/// Tests for the Antigravity provider, decoder, multi-group selection, and single-slot
/// gauge behavior using synthetic payloads only.
struct AntigravityProviderTests {

    final class RecordingRunner: AntigravityCommandRunning, @unchecked Sendable {
        private(set) var executable: URL?
        private(set) var arguments: [String] = []
        private(set) var timeout: TimeInterval = 0
        private(set) var runCount = 0
        let result: Result<AntigravityCommandOutput, any Error>

        init(result: Result<AntigravityCommandOutput, any Error>) {
            self.result = result
        }

        func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> AntigravityCommandOutput {
            self.executable = executable
            self.arguments = arguments
            self.timeout = timeout
            runCount += 1
            return try result.get()
        }
    }

    static let now = Date(timeIntervalSince1970: 1_795_000_000)

    static func futureISO(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: now.addingTimeInterval(offset))
    }

    static func locator() -> AntigravityExecutableLocator {
        AntigravityExecutableLocator(configuredPath: "/bin/echo", environment: [:])
    }

    static func makePayload(
        status: String = "SUCCESS",
        numTurns: Any = 0,
        groups: [[String: Any]]
    ) -> Data {
        let obj: [String: Any] = [
            "conversation_id": "",
            "status": status,
            "response": "synthetic",
            "duration_seconds": 0,
            "num_turns": numTurns,
            "usage": [
                "input_tokens": 0,
                "output_tokens": 0,
                "thinking_tokens": 0,
                "cache_read_tokens": 0,
                "total_tokens": 0,
            ],
            "command": [
                "name": "usage",
                "data": [
                    "groups": groups,
                ],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    static func sampleMultiGroupPayload() -> Data {
        makePayload(groups: [
            [
                "name": "Gemini Models",
                "buckets": [
                    [
                        "id": "gemini-weekly",
                        "name": "Weekly Limit Remaining",
                        "window": "weekly",
                        "remaining_fraction": 0.72,
                        "reset_time": futureISO(3_600 * 100),
                    ],
                    [
                        "id": "gemini-5h",
                        "name": "Five Hour Limit Remaining",
                        "window": "5h",
                        "remaining_fraction": 0.80,
                        "reset_time": futureISO(3_600 * 3),
                    ],
                ],
            ],
            [
                "name": "Claude and GPT models",
                "buckets": [
                    [
                        "id": "3p-weekly",
                        "name": "Weekly Limit Remaining",
                        "window": "weekly",
                        "remaining_fraction": 0.40,
                        "reset_time": futureISO(3_600 * 120),
                    ],
                    [
                        "id": "3p-5h",
                        "name": "Five Hour Limit Remaining",
                        "window": "5h",
                        "remaining_fraction": 0.15,
                        "reset_time": futureISO(3_600 * 4),
                    ],
                ],
            ],
            [
                "name": "Gemini 4 Argon",
                "buckets": [
                    [
                        "id": "gemini-argon-weekly",
                        "name": "Gemini 4 Argon Weekly Limit",
                        "window": "weekly",
                        "remaining_fraction": 1.0,
                        "reset_time": futureISO(3_600 * 120),
                    ],
                ],
            ],
        ])
    }

    // MARK: - Fixed command & locator

    @Test func runsExactlyTheApprovedArguments() async throws {
        let runner = RecordingRunner(result: .success(AntigravityCommandOutput(
            exitCode: 0,
            standardOutput: Self.sampleMultiGroupPayload()
        )))
        let provider = AntigravityUsageProvider(locator: Self.locator(), runner: runner, now: { Self.now })

        let snapshot = try await provider.fetch()

        #expect(runner.arguments == ["-p", "/usage", "--output-format", "json", "--print-timeout", "15s"])
        #expect(runner.arguments == AntigravityUsageCommand.arguments)
        #expect(runner.timeout == AntigravityUsageCommand.timeout)
        #expect(runner.runCount == 1)
        #expect(snapshot.provider == .antigravity)
        #expect(snapshot.sourcePath == .antigravityCLI)
        #expect(snapshot.windows.count == 5)
    }

    @Test func neverContainsNonReadOnlyArguments() {
        let forbidden = [
            "login", "logout", "mcp", "plugin", "plugins", "update", "install",
            "remote-control", "mic-serve", "-c", "--continue", "--conversation",
            "--dangerously-skip-permissions",
        ]
        for argument in AntigravityUsageCommand.arguments {
            #expect(!forbidden.contains(argument))
        }
        #expect(AntigravityUsageCommand.arguments.contains("/usage"))
    }

    @Test func locatorRejectsInvalidExplicitPath() {
        let locator = AntigravityExecutableLocator(
            configuredPath: "/nonexistent/path/to/agy",
            environment: [:],
            commonCandidatePaths: []
        )
        #expect(throws: UsageError.antigravityExecutableInvalid("/nonexistent/path/to/agy")) {
            _ = try locator.locate()
        }
    }

    // MARK: - Decoding & fail-closed validation

    @Test func decodesMultiGroupQuotasAndPreservesGroupOrder() throws {
        let snapshot = try AntigravityUsageDecoder.decode(Self.sampleMultiGroupPayload(), now: Self.now)

        #expect(snapshot.antigravityGroupNames == [
            "Gemini Models",
            "Claude and GPT models",
            "Gemini 4 Argon",
        ])

        let defaultSession = snapshot.quotaWindow(for: .session, antigravityGroup: .default)
        let defaultWeekly = snapshot.quotaWindow(for: .weeklyAll, antigravityGroup: .default)
        #expect(defaultSession?.used.usedPercent == 20)
        #expect(defaultSession?.modelDisplayName == "Gemini Models")
        #expect(defaultWeekly?.used.usedPercent == 28)

        let highestSession = snapshot.quotaWindow(for: .session, antigravityGroup: .highestUsed)
        let highestWeekly = snapshot.quotaWindow(for: .weeklyAll, antigravityGroup: .highestUsed)
        #expect(highestSession?.used.usedPercent == 85)
        #expect(highestSession?.modelDisplayName == "Claude and GPT models")
        #expect(highestWeekly?.used.usedPercent == 60)
        #expect(highestWeekly?.modelDisplayName == "Claude and GPT models")

        let argonSession = snapshot.quotaWindow(for: .session, antigravityGroup: .group("Gemini 4 Argon"))
        let argonWeekly = snapshot.quotaWindow(for: .weeklyAll, antigravityGroup: .group("Gemini 4 Argon"))
        #expect(argonSession == nil)
        #expect(argonWeekly?.used.usedPercent == 0)
    }

    @Test func missingSelectedGroupFallsBackPredictably() throws {
        let multi = try AntigravityUsageDecoder.decode(Self.sampleMultiGroupPayload(), now: Self.now)
        let missing = AntigravityToolbarGroupSelection.group("Retired Pool")
        #expect(multi.resolvedAntigravityToolbarGroup(selection: missing) == "Gemini Models")
        #expect(multi.quotaWindow(for: .session, antigravityGroup: missing)?.modelDisplayName == "Gemini Models")
        #expect(multi.quotaWindow(for: .weeklyAll, antigravityGroup: missing)?.modelDisplayName == "Gemini Models")

        let noDefaultPayload = Self.makePayload(groups: [
            [
                "name": "Alpha Pool",
                "buckets": [
                    ["window": "5h", "remaining_fraction": 0.50, "reset_time": Self.futureISO(3_600)],
                    ["window": "weekly", "remaining_fraction": 0.70, "reset_time": Self.futureISO(3_600 * 72)],
                ],
            ],
            [
                "name": "Beta Pool",
                "buckets": [
                    ["window": "weekly", "remaining_fraction": 0.25, "reset_time": Self.futureISO(3_600 * 72)],
                ],
            ],
        ])
        let noDefault = try AntigravityUsageDecoder.decode(noDefaultPayload, now: Self.now)
        #expect(noDefault.resolvedAntigravityToolbarGroup(selection: missing) == "Alpha Pool")
        #expect(noDefault.quotaWindow(for: .session, antigravityGroup: missing)?.used.usedPercent == 50)
        #expect(noDefault.quotaWindow(for: .weeklyAll, antigravityGroup: missing)?.used.usedPercent == 30)

        // A present weekly-only group must stay on that group and never borrow another group's 5h meter.
        let betaSelection = AntigravityToolbarGroupSelection.group("Beta Pool")
        #expect(noDefault.resolvedAntigravityToolbarGroup(selection: betaSelection) == "Beta Pool")
        #expect(noDefault.quotaWindow(for: .session, antigravityGroup: betaSelection) == nil)
        #expect(noDefault.quotaWindow(for: .weeklyAll, antigravityGroup: betaSelection)?.used.usedPercent == 75)
        #expect(
            GaugeStyleResolver.effectiveDisplayedWindows(
                provider: .antigravity,
                state: .current(noDefault),
                requested: .both,
                antigravityToolbarGroup: betaSelection
            ) == .weeklyOnly
        )
    }

    @Test func tinyPositiveRemainingFractionNeverRoundsToExhausted() {
        #expect(AntigravityUsageDecoder.usedPercent(fromRemainingFraction: 0.0).usedPercent == 100)
        #expect(AntigravityUsageDecoder.usedPercent(fromRemainingFraction: 0.002).usedPercent == 99)
        #expect(AntigravityUsageDecoder.usedPercent(fromRemainingFraction: 0.002).remainingPercent == 1)
        #expect(AntigravityUsageDecoder.usedPercent(fromRemainingFraction: 1.0).usedPercent == 0)
    }

    @Test func rejectsNonZeroModelTurn() {
        let data = Self.makePayload(numTurns: 1, groups: [
            [
                "name": "Gemini Models",
                "buckets": [
                    ["window": "weekly", "remaining_fraction": 0.5, "reset_time": Self.futureISO(3_600)],
                ],
            ],
        ])
        #expect(throws: UsageError.schemaChanged("Antigravity /usage response executed a model turn")) {
            _ = try AntigravityUsageDecoder.decode(data, now: Self.now)
        }
    }

    @Test func rejectsBooleanOrOutOfRangeRemainingFraction() {
        for bad in [true as Any, -0.01 as Any, 1.01 as Any, "0.5" as Any] {
            let data = Self.makePayload(groups: [
                [
                    "name": "Gemini Models",
                    "buckets": [
                        ["window": "weekly", "remaining_fraction": bad, "reset_time": Self.futureISO(3_600)],
                    ],
                ],
            ])
            #expect(throws: UsageError.schemaChanged("Antigravity /usage bucket remaining_fraction is invalid")) {
                _ = try AntigravityUsageDecoder.decode(data, now: Self.now)
            }
        }
    }

    @Test func rejectsExpiredResetPastGraceWindow() {
        let past = Self.futureISO(-120)
        let data = Self.makePayload(groups: [
            [
                "name": "Gemini Models",
                "buckets": [
                    ["window": "5h", "remaining_fraction": 0.5, "reset_time": past],
                ],
            ],
        ])
        do {
            _ = try AntigravityUsageDecoder.decode(data, now: Self.now)
            Issue.record("Expected antigravityUsageOutdated")
        } catch UsageError.antigravityUsageOutdated {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func rejectsDuplicateWindowWithinSameGroup() {
        let data = Self.makePayload(groups: [
            [
                "name": "Gemini Models",
                "buckets": [
                    ["window": "5h", "remaining_fraction": 0.5, "reset_time": Self.futureISO(3_600)],
                    ["window": "5h", "remaining_fraction": 0.7, "reset_time": Self.futureISO(3_600)],
                ],
            ],
        ])
        #expect(throws: UsageError.schemaChanged("Antigravity /usage contains duplicate quota buckets")) {
            _ = try AntigravityUsageDecoder.decode(data, now: Self.now)
        }
    }

    @Test func classifiesFailuresWithoutLeakingRawOutput() {
        let secret = "SECRET_TOKEN_SHOULD_NOT_APPEAR"
        let notSignedIn = AntigravityUsageProvider.classify(output: AntigravityCommandOutput(
            exitCode: 1,
            standardOutput: Data(),
            standardErrorPrefix: "Error: not logged in \(secret)"
        ))
        #expect(notSignedIn == .antigravityNotSignedIn)

        let unsupported = AntigravityUsageProvider.classify(output: AntigravityCommandOutput(
            exitCode: 2,
            standardOutput: Data(),
            standardErrorPrefix: "flag provided but not defined: --print-timeout \(secret)"
        ))
        if case .antigravityVersionUnsupported(let detail) = unsupported {
            #expect(!detail.contains(secret))
        } else {
            Issue.record("Expected antigravityVersionUnsupported, got \(unsupported)")
        }

        let offline = AntigravityUsageProvider.classify(output: AntigravityCommandOutput(
            exitCode: 1,
            standardOutput: Data(),
            standardErrorPrefix: "dial tcp: lookup example: no such host \(secret)"
        ))
        #expect(offline == .offline)

        let generic = AntigravityUsageProvider.classify(output: AntigravityCommandOutput(
            exitCode: 42,
            standardOutput: Data(),
            standardErrorPrefix: "internal failure \(secret)"
        ))
        if case .antigravityCommandFailed(let detail) = generic {
            #expect(!detail.contains(secret))
        } else {
            Issue.record("Expected antigravityCommandFailed, got \(generic)")
        }
    }

    // MARK: - Free plan single-slot gauge & disclosure defaults

    @Test func freePlanWeeklyOnlyCollapsesGaugeToSingleWeeklySlot() throws {
        let freePayload = Self.makePayload(groups: [
            [
                "name": "Gemini Models",
                "buckets": [
                    ["window": "weekly", "remaining_fraction": 0.65, "reset_time": Self.futureISO(3_600 * 96)],
                ],
            ],
        ])
        let snapshot = try AntigravityUsageDecoder.decode(freePayload, now: Self.now)
        let model = GaugeStyleResolver.renderModel(
            provider: .antigravity,
            state: .current(snapshot),
            displayedWindows: .both,
            antigravityToolbarGroup: .default,
            now: Self.now,
            locale: Locale(identifier: "en_US")
        )

        #expect(model.displayedWindows == .weeklyOnly)
        #expect(model.weekly.availability == .reported)
        #expect(model.weekly.fillLevel == .ok)
        #expect(model.accessibilityLabel.contains("7 days (Gemini Models)"))
        #expect(!model.accessibilityLabel.contains("5 hours"))
    }

    @Test func disclosureExpandsPrimaryAntigravityGroupAndFoldsSecondaryGroups() throws {
        let snapshot = try AntigravityUsageDecoder.decode(Self.sampleMultiGroupPayload(), now: Self.now)
        let disclosure = WindowDisclosure()

        let geminiWindows = snapshot.orderedWindows.filter { $0.modelDisplayName == "Gemini Models" }
        let thirdPartyWindows = snapshot.orderedWindows.filter { $0.modelDisplayName == "Claude and GPT models" }
        let argonWindows = snapshot.orderedWindows.filter { $0.modelDisplayName == "Gemini 4 Argon" }

        #expect(geminiWindows.allSatisfy { !disclosure.isCollapsed($0, provider: .antigravity) })
        #expect(thirdPartyWindows.allSatisfy { disclosure.isCollapsed($0, provider: .antigravity) })
        #expect(argonWindows.allSatisfy { disclosure.isCollapsed($0, provider: .antigravity) })
    }

    @Test func snapshotStorePersistsValidAntigravityReadingAndRejectsCrossProviderSource() throws {
        let suite = "AgentUsageBar.tests.antigravity-store.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageSnapshotStore(defaults: defaults)

        let snapshot = try AntigravityUsageDecoder.decode(Self.sampleMultiGroupPayload(), now: Self.now)
        store.save(snapshot)
        let restored = store.load(.antigravity, now: Self.now.addingTimeInterval(30))
        #expect(restored == snapshot)

        let mismatched = UsageSnapshot(
            provider: .claude,
            sourcePath: .antigravityCLI,
            windows: snapshot.windows,
            fetchedAt: Self.now
        )
        store.save(mismatched)
        #expect(store.load(.claude, now: Self.now) == nil)
    }

    @Test func diagnosticLogReducesAntigravityErrorsToClosedCategories() {
        let detail = DiagnosticErrorDetail(
            provider: .antigravity,
            error: .schemaChanged("Antigravity /usage response executed a model turn")
        )
        #expect(detail == .antigravityUnexpectedModelTurn)

        let unknown = DiagnosticErrorDetail(
            provider: .antigravity,
            error: .schemaChanged("raw provider text with /secret/path")
        )
        #expect(unknown == .unrecognizedResponse)
    }
}
