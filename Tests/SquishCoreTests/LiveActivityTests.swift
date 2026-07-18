import Foundation
import XCTest
@testable import SquishCore

final class LiveActivityTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 10_000)

    private func session(_ id: String, ago: TimeInterval, sub: Bool = false) -> CodingSession {
        CodingSession(id: id, provider: .claude, title: id, projectPath: "/p", model: "m",
            usage: TokenUsage(), contextTokens: 1, contextWindow: 10,
            startedAt: now.addingTimeInterval(-1000), updatedAt: now.addingTimeInterval(-ago),
            logPath: "/l", lastUserMessageAt: nil, isSubagent: sub)
    }

    private func pending(_ sid: String) -> PendingRequest {
        PendingRequest(id: "req-\(sid)", sessionId: sid, cwd: "/p", kind: .permission,
            toolName: "Bash", inputSummary: "ls", options: nil, tty: nil, pid: nil, ppid: nil, createdAt: now)
    }

    func testActiveWindowFiltersOldSessions() {
        let chats = LiveActivity.chats(sessions: [session("a", ago: 5), session("b", ago: 500)],
                                       pending: [], now: now)
        XCTAssertEqual(chats.map(\.id), ["a"])
    }

    func testStatuses() {
        let chats = LiveActivity.chats(
            sessions: [session("work", ago: 2), session("idle", ago: 60), session("wait", ago: 300)],
            pending: [pending("wait")], now: now)
        let byId = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0.status) })
        XCTAssertEqual(byId["work"], .working)
        XCTAssertEqual(byId["idle"], .idle)
        XCTAssertEqual(byId["wait"], .waiting)
    }

    func testWaitingIncludesOtherwiseInactiveSession() {
        // "wait" was updated 300s ago (outside the active window) but has a pending
        // request, so it must still appear.
        let chats = LiveActivity.chats(sessions: [session("wait", ago: 300)],
                                       pending: [pending("wait")], now: now)
        XCTAssertEqual(chats.map(\.id), ["wait"])
    }

    func testWaitingSortedFirstAndSubagentsExcluded() {
        let chats = LiveActivity.chats(
            sessions: [session("work", ago: 1), session("wait", ago: 400), session("sub", ago: 1, sub: true)],
            pending: [pending("wait")], now: now)
        XCTAssertEqual(chats.first?.id, "wait")
        XCTAssertFalse(chats.contains { $0.id == "sub" })
    }
}
