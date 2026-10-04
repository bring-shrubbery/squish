import Foundation
import XCTest
@testable import SquishCore

final class ProcessGitClientTests: XCTestCase {
    let git = ProcessGitClient()

    func testListsLinkedWorktrees() throws {
        let fixture = try GitFixture()
        let feature = try fixture.addWorktree("feature")
        let records = try git.listWorktrees(repo: fixture.repo.path)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records[0].isMain)
        XCTAssertEqual(records[1].branch, "feature")
        XCTAssertEqual(WorktreePolicy.normalized(records[1].path), WorktreePolicy.normalized(feature.path))
    }

    func testUncommittedCountsUntrackedButNotIgnored() throws {
        let fixture = try GitFixture()
        let feature = try fixture.addWorktree("feature")
        try fixture.write("node_modules/\n", to: ".gitignore", in: feature)
        try fixture.run(["add", ".gitignore"], in: feature)
        try fixture.run(["commit", "-q", "-m", "ignore"], in: feature)
        try fixture.write("x", to: "node_modules/pkg/index.js", in: feature)
        XCTAssertEqual(try git.uncommittedCount(worktree: feature.path), 0)
        try fixture.write("draft", to: "notes.txt", in: feature)
        XCTAssertEqual(try git.uncommittedCount(worktree: feature.path), 1)
    }

    func testUncommittedIgnoresShowUntrackedFilesConfig() throws {
        let fixture = try GitFixture()
        let feature = try fixture.addWorktree("feature")
        try fixture.run(["config", "status.showUntrackedFiles", "no"], in: feature)
        try fixture.write("draft", to: "notes.txt", in: feature)
        XCTAssertEqual(try git.uncommittedCount(worktree: feature.path), 1)
    }

    func testThousandsOfUntrackedFilesDoNotHang() throws {
        let fixture = try GitFixture()
        let feature = try fixture.addWorktree("feature")
        for index in 0..<3_000 {
            try fixture.write("x", to: "generated/file-with-a-fairly-long-name-\(index).txt", in: feature)
        }
        // -uall lists every file, overflowing the 64 KB pipe buffer if output is not drained concurrently.
        let output = try git.run(["status", "--porcelain", "-uall"], in: feature.path)
        XCTAssertEqual(GitPorcelain.statusEntryCount(output), 3_000)
    }

    func testUnpushedCountsOnlyWorkOnNoOtherBranchOrRemote() throws {
        let fixture = try GitFixture()
        let feature = try fixture.addWorktree("feature")
        XCTAssertEqual(try git.unpushedCount(worktree: feature.path, branch: "feature"), 0)
        try fixture.run(["commit", "-q", "--allow-empty", "-m", "one"], in: feature)
        try fixture.run(["commit", "-q", "--allow-empty", "-m", "two"], in: feature)
        XCTAssertEqual(try git.unpushedCount(worktree: feature.path, branch: "feature"), 2)
    }

    func testLastActivityAndMainRepoRoot() throws {
        let fixture = try GitFixture()
        let feature = try fixture.addWorktree("feature")
        let activity = try XCTUnwrap(try git.lastActivity(worktree: feature.path))
        XCTAssertLessThan(abs(activity.timeIntervalSinceNow), 120)
        let expected = WorktreePolicy.normalized(fixture.repo.path)
        XCTAssertEqual(try git.mainRepoRoot(containing: feature.path), expected)
        XCTAssertEqual(try git.mainRepoRoot(containing: fixture.repo.path), expected)
    }

    func testMainRepoRootOfNonRepoIsNotAnError() throws {
        let fixture = try GitFixture()
        XCTAssertNil(try git.mainRepoRoot(containing: fixture.root.path))
        XCTAssertNil(try git.mainRepoRoot(containing: "/nonexistent/squish/path"))
    }

    func testRemovingCleanWorktreeKeepsBranch() throws {
        let fixture = try GitFixture()
        let feature = try fixture.addWorktree("feature")
        try git.remove(worktree: feature.path, repo: fixture.repo.path, force: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: feature.path))
        XCTAssertTrue(try fixture.run(["branch", "--list", "feature"]).contains("feature"))
    }

    func testIgnoredOnlyWorktreeRemovesWithoutForce() throws {
        let fixture = try GitFixture()
        let feature = try fixture.addWorktree("feature")
        try fixture.write("node_modules/\n", to: ".gitignore", in: feature)
        try fixture.run(["add", ".gitignore"], in: feature)
        try fixture.run(["commit", "-q", "-m", "ignore"], in: feature)
        try fixture.write("x", to: "node_modules/pkg/index.js", in: feature)
        try git.remove(worktree: feature.path, repo: fixture.repo.path, force: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: feature.path))
    }

    func testDirtyWorktreeNeedsForce() throws {
        let fixture = try GitFixture()
        let feature = try fixture.addWorktree("feature")
        try fixture.write("draft", to: "notes.txt", in: feature)
        XCTAssertThrowsError(try git.remove(worktree: feature.path, repo: fixture.repo.path, force: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: feature.path))
        try git.remove(worktree: feature.path, repo: fixture.repo.path, force: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: feature.path))
        XCTAssertTrue(try fixture.run(["branch", "--list", "feature"]).contains("feature"))
    }

    func testDeletedDirectoryIsPrunableAndPrunes() throws {
        let fixture = try GitFixture()
        let feature = try fixture.addWorktree("feature")
        try FileManager.default.removeItem(at: feature)
        XCTAssertTrue(try git.listWorktrees(repo: fixture.repo.path)[1].isPrunable)
        try git.prune(repo: fixture.repo.path)
        XCTAssertEqual(try git.listWorktrees(repo: fixture.repo.path).count, 1)
    }

    func testMissingBinaryIsUnavailable() {
        let missing = ProcessGitClient(gitPath: "/nonexistent/git")
        XCTAssertThrowsError(try missing.run(["--version"], in: "/")) { error in
            XCTAssertEqual(error as? GitError, .unavailable)
        }
    }

    func testTimeout() {
        let slow = ProcessGitClient(gitPath: "/bin/sleep", timeout: 0.5)
        XCTAssertThrowsError(try slow.run(["5"], in: "/")) { error in
            guard case .timedOut = error as? GitError else { return XCTFail("expected timeout, got \(error)") }
        }
    }
}
