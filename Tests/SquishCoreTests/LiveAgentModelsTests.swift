import Foundation
import XCTest
@testable import SquishCore

final class LiveAgentModelsTests: XCTestCase {
    func testPendingRequestRoundTrips() throws {
        let request = PendingRequest(
            id: "abc", sessionId: "claude:s1", cwd: "/tmp/proj",
            kind: .permission, toolName: "Bash", inputSummary: "rm -rf build/",
            options: nil, tty: "/dev/ttys003", pid: 42, ppid: 7,
            createdAt: Date(timeIntervalSince1970: 1000)
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PendingRequest.self, from: data)
        XCTAssertEqual(decoded, request)
    }

    func testAgentDecisionAnswerRoundTrips() {
        let decision = AgentDecision.answer("use the staging DB")
        let restored = AgentDecision.decode(decision.encoded())
        XCTAssertEqual(restored, .answer("use the staging DB"))
    }

    func testAgentDecisionSimpleCasesRoundTrip() {
        for decision in [AgentDecision.allow, .deny, .alwaysAllow] {
            XCTAssertEqual(AgentDecision.decode(decision.encoded()), decision)
        }
    }

    func testAllowProducesAllowHookJSON() {
        let json = ClaudeHookResponse.json(for: .allow)
        XCTAssertTrue(json.contains("\"permissionDecision\":\"allow\""))
    }

    func testDenyProducesDenyHookJSON() {
        let json = ClaudeHookResponse.json(for: .deny)
        XCTAssertTrue(json.contains("\"permissionDecision\":\"deny\""))
    }

    func testAnswerProducesDenyWithReason() {
        let json = ClaudeHookResponse.json(for: .answer("do X"))
        XCTAssertTrue(json.contains("\"permissionDecision\":\"deny\""))
        XCTAssertTrue(json.contains("do X"))
    }

    func testAlwaysAllowProducesAllow() {
        let json = ClaudeHookResponse.json(for: .alwaysAllow)
        XCTAssertTrue(json.contains("\"permissionDecision\":\"allow\""))
    }
}
