import Foundation
import XCTest
@testable import SquishCore

final class CompactAlertPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testStartupBaselineNeverNotifies() {
        let session = makeSession(lastUserMessageAt: now.addingTimeInterval(-1))

        XCTAssertFalse(
            CompactAlertPolicy.shouldNotify(
                previous: nil,
                current: session,
                threshold: 0.8,
                isArmed: true,
                hasAlerted: false,
                monitoringIsEstablished: false,
                now: now
            )
        )
    }

    func testAssistantOnlyUpdateNeverNotifies() {
        let messageDate = now.addingTimeInterval(-2)
        let previous = makeSession(lastUserMessageAt: messageDate, contextTokens: 80_000)
        let assistantUpdate = makeSession(lastUserMessageAt: messageDate, contextTokens: 90_000)

        XCTAssertFalse(
            CompactAlertPolicy.shouldNotify(
                previous: previous,
                current: assistantUpdate,
                threshold: 0.8,
                isArmed: true,
                hasAlerted: false,
                monitoringIsEstablished: true,
                now: now
            )
        )
    }

    func testNewUserMessageCanNotifyAtThreshold() {
        let previous = makeSession(lastUserMessageAt: now.addingTimeInterval(-30))
        let current = makeSession(lastUserMessageAt: now.addingTimeInterval(-1))

        XCTAssertTrue(
            CompactAlertPolicy.shouldNotify(
                previous: previous,
                current: current,
                threshold: 0.8,
                isArmed: true,
                hasAlerted: false,
                monitoringIsEstablished: true,
                now: now
            )
        )
    }

    func testStaleOrSubagentMessagesNeverNotify() {
        let stale = makeSession(lastUserMessageAt: now.addingTimeInterval(-300))
        let subagent = makeSession(lastUserMessageAt: now.addingTimeInterval(-1), isSubagent: true)

        for session in [stale, subagent] {
            XCTAssertFalse(
                CompactAlertPolicy.shouldNotify(
                    previous: nil,
                    current: session,
                    threshold: 0.8,
                    isArmed: true,
                    hasAlerted: false,
                    monitoringIsEstablished: true,
                    now: now
                )
            )
        }
    }

    private func makeSession(
        lastUserMessageAt: Date?,
        contextTokens: Int = 90_000,
        isSubagent: Bool = false
    ) -> CodingSession {
        CodingSession(
            id: "codex:alert-policy",
            provider: .codex,
            title: "Alert policy",
            projectPath: "/tmp/project",
            model: "gpt-5.4",
            usage: TokenUsage(inputTokens: contextTokens),
            contextTokens: contextTokens,
            contextWindow: 100_000,
            startedAt: now.addingTimeInterval(-600),
            updatedAt: now,
            logPath: "/tmp/alert-policy.jsonl",
            lastUserMessageAt: lastUserMessageAt,
            isSubagent: isSubagent
        )
    }
}
