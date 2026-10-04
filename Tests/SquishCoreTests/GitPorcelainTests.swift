import XCTest
@testable import SquishCore

final class GitPorcelainTests: XCTestCase {
    func testParsesMainLinkedDetachedLockedAndPrunable() {
        let output = """
        worktree /Users/me/Projects/app
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /Users/me/Projects/app/.claude/worktrees/fix login
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/fix-login

        worktree /Users/me/Projects/app-detached
        HEAD 3333333333333333333333333333333333333333
        detached

        worktree /Users/me/Projects/app-locked
        HEAD 4444444444444444444444444444444444444444
        branch refs/heads/locked-one
        locked moving to another disk

        worktree /Users/me/Projects/app-gone
        HEAD 5555555555555555555555555555555555555555
        branch refs/heads/gone
        prunable gitdir file points to non-existent location

        """
        let records = GitPorcelain.worktrees(output)
        XCTAssertEqual(records.count, 5)
        XCTAssertEqual(records[0], WorktreeRecord(
            path: "/Users/me/Projects/app", head: "1111111111111111111111111111111111111111",
            branch: "main", isMain: true, isBare: false, isLocked: false, isPrunable: false
        ))
        XCTAssertEqual(records[1].path, "/Users/me/Projects/app/.claude/worktrees/fix login")
        XCTAssertEqual(records[1].branch, "fix-login")
        XCTAssertFalse(records[1].isMain)
        XCTAssertNil(records[2].branch)
        XCTAssertEqual(records[2].head, "3333333333333333333333333333333333333333")
        XCTAssertTrue(records[3].isLocked)
        XCTAssertTrue(records[4].isPrunable)
    }

    func testBareMainAndBareLock() {
        let output = "worktree /srv/repo.git\nbare\n\nworktree /srv/wt\nHEAD abc\nbranch refs/heads/x\nlocked\n"
        let records = GitPorcelain.worktrees(output)
        XCTAssertTrue(records[0].isBare)
        XCTAssertTrue(records[0].isMain)
        XCTAssertTrue(records[1].isLocked)
    }

    func testEmptyOutput() {
        XCTAssertEqual(GitPorcelain.worktrees(""), [])
    }

    func testStatusEntryCount() {
        let output = " M Sources/a.swift\nM  Sources/b.swift\n?? notes.txt\nR  old.swift -> new.swift\n"
        XCTAssertEqual(GitPorcelain.statusEntryCount(output), 4)
        XCTAssertEqual(GitPorcelain.statusEntryCount(""), 0)
        XCTAssertEqual(GitPorcelain.statusEntryCount("\n"), 0)
    }
}
