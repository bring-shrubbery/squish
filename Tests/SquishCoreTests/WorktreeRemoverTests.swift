import Foundation
import XCTest
@testable import SquishCore

final class WorktreeRemoverTests: XCTestCase {
    let git = ProcessGitClient()

    // MARK: - freshRemovalCheck

    func testPlainRemovalNeedsCleanIdleWorktree() {
        XCTAssertNil(check(0, 0))
        XCTAssertNotNil(check(1, 0))
        XCTAssertNotNil(check(0, 1))
        XCTAssertEqual(check(0, 0, active: true), WorktreePolicy.activeReason)
    }

    func testPlainRemovalIgnoresConfirmedCounts() {
        XCTAssertNotNil(check(1, 0, confirmed: (5, 5)))
    }

    func testForcedRemovalLosesAtMostWhatWasConfirmed() {
        XCTAssertNil(check(2, 1, force: true, confirmed: (2, 1)))
        XCTAssertNil(check(1, 0, force: true, confirmed: (2, 1)))
        XCTAssertNotNil(check(3, 1, force: true, confirmed: (2, 1)))
        XCTAssertNotNil(check(2, 2, force: true, confirmed: (2, 1)))
        XCTAssertEqual(check(0, 0, active: true, force: true, confirmed: (2, 1)), WorktreePolicy.activeReason)
    }

    private func check(
        _ uncommitted: Int, _ unpushed: Int, active: Bool = false, force: Bool = false,
        confirmed: (Int, Int) = (0, 0)
    ) -> String? {
        WorktreePolicy.freshRemovalCheck(
            uncommitted: uncommitted, unpushed: unpushed, isActive: active, force: force,
            confirmedUncommitted: confirmed.0, confirmedUnpushed: confirmed.1
        )
    }

    // MARK: - Against real git

    private func scanned(_ fixture: GitFixture, _ path: URL) throws -> Worktree {
        let scan = WorktreeScanner(git: git).scan(repo: fixture.repo.path)
        return try XCTUnwrap(scan.worktrees.first { $0.path == WorktreePolicy.normalized(path.path) })
    }

    private func refusal(_ body: () throws -> Void) -> RemovalRefusal? {
        do {
            try body()
            return nil
        } catch {
            return error as? RemovalRefusal
        }
    }

    func testRefusesWorkAddedAfterTheScan() throws {
        let fixture = try GitFixture()
        let feature = try fixture.addWorktree("feature")
        let worktree = try scanned(fixture, feature)
        XCTAssertEqual(worktree.uncommittedCount, 0)
        try fixture.write("draft", to: "notes.txt", in: feature)
        XCTAssertNotNil(refusal {
            try WorktreeRemover.remove(worktree, git: git, activePaths: [], force: false)
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: feature.appendingPathComponent("notes.txt").path))
    }

    func testForcedRemovalRefusesMoreThanConfirmedThenProceeds() throws {
        let fixture = try GitFixture()
        let feature = try fixture.addWorktree("feature")
        try fixture.write("draft", to: "notes.txt", in: feature)
        let worktree = try scanned(fixture, feature)
        XCTAssertEqual(worktree.uncommittedCount, 1)
        try fixture.write("more", to: "more.txt", in: feature)
        XCTAssertNotNil(refusal {
            try WorktreeRemover.remove(worktree, git: git, activePaths: [], force: true, confirmedUncommitted: 1)
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: feature.path))
        try WorktreeRemover.remove(worktree, git: git, activePaths: [], force: true, confirmedUncommitted: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: feature.path))
    }

    func testRefusesWhenSomethingIsWorkingInside() throws {
        let fixture = try GitFixture()
        let feature = try fixture.addWorktree("feature")
        let worktree = try scanned(fixture, feature)
        let inside = WorktreePolicy.normalized(feature.appendingPathComponent("src").path)
        XCTAssertEqual(
            refusal { try WorktreeRemover.remove(worktree, git: git, activePaths: [inside], force: false) },
            RemovalRefusal(WorktreePolicy.activeReason)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: feature.path))
    }

    func testCleanRemovalProceeds() throws {
        let fixture = try GitFixture()
        let feature = try fixture.addWorktree("feature")
        let worktree = try scanned(fixture, feature)
        XCTAssertNil(try WorktreeRemover.remove(worktree, git: git, activePaths: [], force: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: feature.path))
    }

    func testForcedRemovalOfDetachedHeadRescuesItsCommits() throws {
        let fixture = try GitFixture()
        let path = fixture.repo.appendingPathComponent(".claude/worktrees/loose")
        try fixture.run(["worktree", "add", "-q", "--detach", path.path])
        try fixture.run(["commit", "-q", "--allow-empty", "-m", "only here"], in: path)
        let head = try fixture.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        // The first name is taken, so the rescue branch gets a suffix.
        let base = WorktreeRemover.rescueBranchBase(head: head)
        try fixture.run(["branch", base])
        let worktree = try scanned(fixture, path)
        XCTAssertNil(worktree.branch)
        XCTAssertEqual(worktree.unpushedCount, 1)

        let rescued = try WorktreeRemover.remove(
            worktree, git: git, activePaths: [], force: true, confirmedUnpushed: 1
        )
        XCTAssertEqual(rescued, "\(base)-2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        let tip = try fixture.run(["rev-parse", "\(base)-2"]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(tip, head)
    }
}
