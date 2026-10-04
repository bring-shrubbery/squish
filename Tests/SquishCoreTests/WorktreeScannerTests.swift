import Foundation
import XCTest
@testable import SquishCore

private struct FakeGit: GitClient {
    var records: [String: [WorktreeRecord]] = [:]
    var failingRepo: String?
    var unavailable = false
    var failingWorktree: String?

    func listWorktrees(repo: String) throws -> [WorktreeRecord] {
        if repo == failingRepo { throw GitError.timedOut(command: "worktree") }
        return records[repo] ?? []
    }
    func uncommittedCount(worktree: String) throws -> Int { worktree.hasSuffix("dirty") ? 3 : 0 }
    func unpushedCount(worktree: String, branch: String?) throws -> Int { 0 }
    func lastActivity(worktree: String) throws -> Date? {
        if worktree == failingWorktree { throw GitError.failed(message: "unborn HEAD") }
        return Date(timeIntervalSince1970: 1_000)
    }
    func mainRepoRoot(containing path: String) throws -> String? {
        if unavailable { throw GitError.unavailable }
        return path.hasPrefix("/r") ? "/r" : nil
    }
    func remove(worktree: String, repo: String, force: Bool) throws {}
    func prune(repo: String) throws {}
    func createBranch(name: String, at sha: String, repo: String) throws {}
}

final class WorktreeScannerTests: XCTestCase {
    private func record(_ path: String, main: Bool = false, prunable: Bool = false) -> WorktreeRecord {
        WorktreeRecord(path: path, head: "abc", branch: main ? "main" : "f", isMain: main,
                       isBare: false, isLocked: false, isPrunable: prunable)
    }

    func testScanSkipsMainAndFillsDetails() {
        let git = FakeGit(records: ["/r": [record("/r", main: true), record("/r/wt-dirty"), record("/r/gone", prunable: true)]])
        let scan = WorktreeScanner(git: git).scan(repo: "/r")
        XCTAssertNil(scan.error)
        XCTAssertEqual(scan.worktrees.map(\.path), ["/r/wt-dirty", "/r/gone"])
        XCTAssertEqual(scan.worktrees[0].uncommittedCount, 3)
        XCTAssertEqual(scan.worktrees[0].lastActivity, Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(scan.worktrees[1].isPrunable)
        XCTAssertNil(scan.worktrees[1].lastActivity)
    }

    func testFailingRepoBecomesAnErrorRowAndOthersStillScan() {
        let git = FakeGit(records: ["/r": [record("/r", main: true), record("/r/wt")]], failingRepo: "/bad")
        let scans = WorktreeScanner(git: git).scanAll(repos: ["/bad", "/r"])
        XCTAssertEqual(scans.map(\.repoPath), ["/bad", "/r"])
        XCTAssertNotNil(scans[0].error)
        XCTAssertEqual(scans[1].worktrees.count, 1)
    }

    func testOneFailingWorktreeIsListedWithItsErrorAndSiblingsStillScan() {
        let git = FakeGit(
            records: ["/r": [record("/r", main: true), record("/r/broken"), record("/r/wt-dirty")]],
            failingWorktree: "/r/broken"
        )
        let scan = WorktreeScanner(git: git).scan(repo: "/r")
        XCTAssertNil(scan.error)
        XCTAssertEqual(scan.worktrees.map(\.path), ["/r/broken", "/r/wt-dirty"])
        XCTAssertEqual(scan.worktrees[0].detailError, GitError.failed(message: "unborn HEAD").localizedDescription)
        XCTAssertNil(scan.worktrees[0].lastActivity)
        XCTAssertEqual(scan.worktrees[0].uncommittedCount, 0)
        XCTAssertNil(scan.worktrees[1].detailError)
        XCTAssertEqual(scan.worktrees[1].uncommittedCount, 3)
    }

    func testReposPropagateUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try WorktreeScanner(git: FakeGit(unavailable: true)).repos(root: root, sessionPaths: ["/r/x"])) {
            XCTAssertEqual($0 as? GitError, .unavailable)
        }
    }

    func testRealRepoDedupesWorktreesAndSessionPathsToTheMainRepo() throws {
        let fixture = try GitFixture()
        let feature = try fixture.addWorktree("feature")
        let scanner = WorktreeScanner()
        // The walk finds both the repo and its .claude worktree; a session inside the worktree adds it again.
        let repos = try scanner.repos(root: fixture.root, sessionPaths: [feature.path])
        XCTAssertEqual(repos, [WorktreePolicy.normalized(fixture.repo.path)])
        let scan = scanner.scan(repo: repos[0])
        XCTAssertEqual(scan.worktrees.map(\.path), [WorktreePolicy.normalized(feature.path)])
        XCTAssertEqual(scan.worktrees[0].branch, "feature")
    }
}
