import Foundation
@testable import SquishCore

/// A throwaway git repo in a temporary directory, driven through the real git binary.
final class GitFixture {
    let root: URL
    let repo: URL
    private let git = ProcessGitClient()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("squish-git-\(UUID().uuidString)")
        repo = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try run(["init", "-q", "-b", "main"])
        try run(["commit", "-q", "--allow-empty", "-m", "init"])
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// git with a fixed identity, in the main repo unless `directory` is given.
    @discardableResult
    func run(_ arguments: [String], in directory: URL? = nil) throws -> String {
        try git.run(["-c", "user.name=Squish Tests", "-c", "user.email=tests@squish.invalid"] + arguments,
                    in: (directory ?? repo).path)
    }

    /// Adds a linked worktree on a new branch under `.claude/worktrees/<name>`.
    @discardableResult
    func addWorktree(_ name: String) throws -> URL {
        let path = repo.appendingPathComponent(".claude/worktrees/\(name)")
        try run(["worktree", "add", "-q", "-b", name, path.path])
        return path
    }

    func write(_ text: String, to relative: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
