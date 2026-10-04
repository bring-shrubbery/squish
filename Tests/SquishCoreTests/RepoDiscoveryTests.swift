import Foundation
import XCTest
@testable import SquishCore

final class RepoDiscoveryTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("squish-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeRepo(_ relative: String, gitFile: Bool = false) throws {
        let dir = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if gitFile {
            try "gitdir: /elsewhere".write(to: dir.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        } else {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        }
    }

    private func names(_ paths: [String]) -> [String] {
        let base = root.standardizedFileURL.path
        return paths.map { $0 == base ? "." : String($0.dropFirst(base.count + 1)) }
    }

    func testFindsReposAndClaudeWorktreesAtAnyAllowedDepth() throws {
        try makeRepo("app")
        try makeRepo("app/.claude/worktrees/feature", gitFile: true)
        try makeRepo("clients/acme/site")
        XCTAssertEqual(
            names(RepoDiscovery.candidates(under: root)),
            ["app", "app/.claude/worktrees/feature", "clients/acme/site"]
        )
    }

    func testRootItselfCanBeARepo() throws {
        try makeRepo(".")
        XCTAssertEqual(names(RepoDiscovery.candidates(under: root)), ["."])
    }

    func testSkipsDependencyAndHiddenDirectories() throws {
        try makeRepo("app/node_modules/dep")
        try makeRepo("app/.build/checkouts/pkg")
        try makeRepo(".cache/thing")
        try makeRepo("app/Pods/Lib")
        XCTAssertEqual(RepoDiscovery.candidates(under: root), [])
    }

    func testHonoursMaxDepth() throws {
        try makeRepo("a/b/c/d/e")
        XCTAssertEqual(RepoDiscovery.candidates(under: root, maxDepth: 4), [])
        XCTAssertEqual(names(RepoDiscovery.candidates(under: root, maxDepth: 5)), ["a/b/c/d/e"])
    }

    func testSkipsPackagesAndLibrary() throws {
        try makeRepo("Foo.app")
        try makeRepo("Library/Developer/thing")
        try makeRepo("app")
        XCTAssertEqual(names(RepoDiscovery.candidates(under: root)), ["app"])
    }
}
