import Foundation
import XCTest
@testable import SquishCore

final class CompactionTests: XCTestCase {
    private func session(provider: AgentProvider, model: String, context: Int, path: String = "/p/a", startedAt: TimeInterval = 1_000) -> CodingSession {
        CodingSession(
            id: "\(provider.rawValue):s", provider: provider, title: "t", projectPath: path, model: model,
            usage: TokenUsage(), contextTokens: context, contextWindow: 200_000,
            startedAt: Date(timeIntervalSince1970: startedAt), updatedAt: Date(timeIntervalSince1970: startedAt + 10), logPath: "/l"
        )
    }

    func testEstimateReadsTheContextAtTheCacheRateAndWritesASummary() throws {
        // gpt-5.4: cached reads $0.25/M, output $15/M.
        let cost = try XCTUnwrap(Compaction.estimatedCost(for: session(provider: .codex, model: "gpt-5.4", context: 160_000)))
        XCTAssertEqual(cost, 160_000 / 1e6 * 0.25 + 4_000 / 1e6 * 15, accuracy: 0.000_001)
        XCTAssertNil(Compaction.estimatedCost(for: session(provider: .codex, model: "codex-auto-review", context: 1_000)))
    }

    func testCommandsPerAgent() {
        XCTAssertEqual(Compaction.command(for: .claude), "/compact")
        XCTAssertEqual(Compaction.command(for: .codex), "/compact")
        XCTAssertEqual(Compaction.command(for: .gemini), "/compress")
    }

    func testProcessMatchPrefersSameAgentFolderAndNearestStart() {
        let processes = [
            AgentProcess(pid: 1, provider: .claude, workingDirectory: "/p/a", tty: "/dev/ttys001", startedAt: Date(timeIntervalSince1970: 900)),
            AgentProcess(pid: 2, provider: .claude, workingDirectory: "/p/a/", tty: "/dev/ttys002", startedAt: Date(timeIntervalSince1970: 1_010)),
            AgentProcess(pid: 3, provider: .codex, workingDirectory: "/p/a", tty: "/dev/ttys003", startedAt: Date(timeIntervalSince1970: 1_000)),
            AgentProcess(pid: 4, provider: .claude, workingDirectory: "/p/b", tty: "/dev/ttys004", startedAt: Date(timeIntervalSince1970: 1_000)),
            AgentProcess(pid: 5, provider: .claude, workingDirectory: "/p/a", tty: nil, startedAt: Date(timeIntervalSince1970: 1_000))
        ]
        let match = AgentProcesses.match(for: session(provider: .claude, model: "m", context: 1), in: processes)
        XCTAssertEqual(match?.pid, 2)
        XCTAssertNil(AgentProcesses.match(for: session(provider: .gemini, model: "m", context: 1), in: processes))
        XCTAssertEqual(AgentProcesses.provider(forExecutable: "node"), .gemini)
        XCTAssertNil(AgentProcesses.provider(forExecutable: "zsh"))
    }

    func testRunningListsThisTestProcessesTerminalsWithoutCrashing() {
        // Nothing to assert about other people's processes; the walk must just not fail.
        _ = AgentProcesses.running()
    }
}
