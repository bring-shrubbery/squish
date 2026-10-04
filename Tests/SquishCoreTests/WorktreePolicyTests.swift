import Foundation
import XCTest
@testable import SquishCore

final class WorktreePolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400

    private func make(
        path: String = "/repo/.claude/worktrees/feature",
        branch: String? = "feature",
        lastActivity: Date? = nil,
        size: Int64? = nil,
        uncommitted: Int = 0,
        unpushed: Int = 0,
        locked: Bool = false,
        prunable: Bool = false
    ) -> Worktree {
        Worktree(
            path: path, repoPath: "/repo", branch: branch, head: "0123456789abcdef",
            isLocked: locked, isPrunable: prunable, lastActivity: lastActivity,
            uncommittedCount: uncommitted, unpushedCount: unpushed, sizeBytes: size
        )
    }

    func testAgentDetectedFromClaudeWorktreePath() {
        XCTAssertEqual(make().agent, .claudeCode)
        XCTAssertNil(make(path: "/repo-feature").agent)
    }

    func testDisplayNameFallsBackToDetachedHead() {
        XCTAssertEqual(make().displayName, "feature")
        XCTAssertEqual(make(branch: nil).displayName, "detached 0123456")
    }

    func testAgeFlagIsStrictlyPastThreshold() {
        let thresholds = WorktreeThresholds()
        let atLimit = make(lastActivity: now.addingTimeInterval(-14 * day))
        let past = make(lastActivity: now.addingTimeInterval(-15 * day))
        XCTAssertEqual(WorktreePolicy.flags(for: atLimit, thresholds: thresholds, activeSessionPaths: [], now: now), [])
        XCTAssertEqual(WorktreePolicy.flags(for: past, thresholds: thresholds, activeSessionPaths: [], now: now), [.age(days: 15)])
    }

    func testSizeFlagIsStrictlyPastThreshold() {
        let thresholds = WorktreeThresholds()
        XCTAssertEqual(WorktreePolicy.flags(for: make(size: 1_000_000_000), thresholds: thresholds, activeSessionPaths: [], now: now), [])
        XCTAssertEqual(
            WorktreePolicy.flags(for: make(size: 1_000_000_001), thresholds: thresholds, activeSessionPaths: [], now: now),
            [.size(bytes: 1_000_000_001)]
        )
    }

    func testBothFlagsAndUnknownValues() {
        let both = make(lastActivity: now.addingTimeInterval(-30 * day), size: 5_000_000_000)
        XCTAssertEqual(
            WorktreePolicy.flags(for: both, thresholds: WorktreeThresholds(), activeSessionPaths: [], now: now),
            [.age(days: 30), .size(bytes: 5_000_000_000)]
        )
        XCTAssertEqual(WorktreePolicy.flags(for: make(), thresholds: WorktreeThresholds(), activeSessionPaths: [], now: now), [])
    }

    func testActiveSessionSuppressesFlagsAndBlocksRemoval() {
        let old = make(lastActivity: now.addingTimeInterval(-30 * day))
        let inside = ["/repo/.claude/worktrees/feature/packages/app"]
        XCTAssertEqual(WorktreePolicy.flags(for: old, thresholds: WorktreeThresholds(), activeSessionPaths: inside, now: now), [])
        guard case .blocked = WorktreePolicy.removal(for: old, activeSessionPaths: inside) else {
            return XCTFail("expected blocked")
        }
    }

    func testSessionInSiblingWithSharedPrefixIsNotActive() {
        let worktree = make(path: "/x/wt")
        XCTAssertFalse(WorktreePolicy.hasActiveSession(worktree, activeSessionPaths: ["/x/wt-2"]))
        XCTAssertTrue(WorktreePolicy.hasActiveSession(worktree, activeSessionPaths: ["/x/wt"]))
        XCTAssertTrue(WorktreePolicy.hasActiveSession(worktree, activeSessionPaths: ["/x/wt/sub"]))
    }

    func testLiveSessionPathsUsesWindowAndNormalizesSymlinks() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fresh = session(path: tmp.path, updatedAt: now.addingTimeInterval(-60))
        let stale = session(path: "/elsewhere", updatedAt: now.addingTimeInterval(-601))
        let paths = WorktreePolicy.liveSessionPaths([fresh, stale], now: now)
        XCTAssertEqual(paths, [WorktreePolicy.normalized(tmp.path)])
        // The temporary directory lives under /var, a symlink to /private/var.
        XCTAssertTrue(paths[0].hasPrefix("/private/"))
    }

    func testNormalizedMatchesSymlinkedAndMissingPaths() {
        XCTAssertEqual(WorktreePolicy.normalized("/tmp"), WorktreePolicy.normalized("/private/tmp"))
        let missing = "/tmp/\(UUID().uuidString)/gone"
        XCTAssertEqual(WorktreePolicy.normalized(missing), WorktreePolicy.normalized("/private" + missing))
        XCTAssertTrue(WorktreePolicy.normalized(missing).hasSuffix("/gone"))
    }

    func testRemovalCases() {
        XCTAssertEqual(WorktreePolicy.removal(for: make(), activeSessionPaths: []), .confirm)
        XCTAssertEqual(
            WorktreePolicy.removal(for: make(uncommitted: 4, unpushed: 2), activeSessionPaths: []),
            .confirmLosingWork(uncommitted: 4, unpushed: 2, detached: false)
        )
        XCTAssertEqual(
            WorktreePolicy.removal(for: make(branch: nil, unpushed: 1), activeSessionPaths: []),
            .confirmLosingWork(uncommitted: 0, unpushed: 1, detached: true)
        )
        XCTAssertEqual(WorktreePolicy.removal(for: make(prunable: true), activeSessionPaths: []), .pruneOnly)
        guard case .blocked = WorktreePolicy.removal(for: make(locked: true), activeSessionPaths: []) else {
            return XCTFail("expected blocked")
        }
    }

    func testPrunableIsNeverFlagged() {
        let gone = make(lastActivity: now.addingTimeInterval(-90 * day), prunable: true)
        XCTAssertEqual(WorktreePolicy.flags(for: gone, thresholds: WorktreeThresholds(), activeSessionPaths: [], now: now), [])
    }

    func testBulkRemovableTakesOnlyCleanFlaggedOnes() {
        let oldClean = make(path: "/a", lastActivity: now.addingTimeInterval(-30 * day))
        let oldDirty = make(path: "/b", lastActivity: now.addingTimeInterval(-30 * day), uncommitted: 1)
        let fresh = make(path: "/c", lastActivity: now)
        let result = WorktreePolicy.bulkRemovable(
            [oldClean, oldDirty, fresh], thresholds: WorktreeThresholds(), activeSessionPaths: [], now: now
        )
        XCTAssertEqual(result.remove.map(\.path), ["/a"])
        XCTAssertEqual(result.skipped.map(\.path), ["/b"])
    }

    private func session(path: String, updatedAt: Date) -> CodingSession {
        CodingSession(
            id: UUID().uuidString, provider: .claude, title: "t", projectPath: path, model: "m",
            usage: TokenUsage(), contextTokens: 0, contextWindow: 100_000,
            startedAt: updatedAt, updatedAt: updatedAt, logPath: "/tmp/x.jsonl"
        )
    }
}
