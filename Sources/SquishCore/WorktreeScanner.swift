import Foundation

/// The linked worktrees of one repo, or why they could not be read.
public struct RepoScan: Identifiable, Equatable, Sendable {
    public var id: String { repoPath }
    public let repoPath: String
    public let worktrees: [Worktree]
    public let error: String?

    public init(repoPath: String, worktrees: [Worktree], error: String?) {
        self.repoPath = repoPath
        self.worktrees = worktrees
        self.error = error
    }
}

/// Finds repos and reads their linked worktrees. Blocking; run off the main actor.
public struct WorktreeScanner: Sendable {
    public let git: any GitClient

    public init(git: any GitClient = ProcessGitClient()) {
        self.git = git
    }

    /// Main repo roots for every candidate under `root` and every session path, deduplicated.
    /// Throws only `GitError.unavailable`; any other failure skips that candidate.
    public func repos(root: URL, sessionPaths: [String], maxDepth: Int = 4) throws -> [String] {
        var seen = Set<String>()
        for candidate in RepoDiscovery.candidates(under: root, maxDepth: maxDepth) + sessionPaths {
            do {
                if let main = try git.mainRepoRoot(containing: candidate) {
                    seen.insert(WorktreePolicy.normalized(main))
                }
            } catch GitError.unavailable {
                throw GitError.unavailable
            } catch {
                continue
            }
        }
        return seen.sorted()
    }

    public func scan(repo: String) -> RepoScan {
        do {
            let worktrees = try git.listWorktrees(repo: repo)
                .filter { !$0.isMain && !$0.isBare }
                .map { record in try worktree(from: record, repo: repo) }
            return RepoScan(repoPath: repo, worktrees: worktrees, error: nil)
        } catch {
            return RepoScan(repoPath: repo, worktrees: [], error: error.localizedDescription)
        }
    }

    /// Scans repos concurrently (bounded by the system's thread pool), keeping their order.
    public func scanAll(repos: [String]) -> [RepoScan] {
        let results = ScanResults(count: repos.count)
        DispatchQueue.concurrentPerform(iterations: repos.count) { index in
            results.set(scan(repo: repos[index]), at: index)
        }
        return results.values
    }

    private func worktree(from record: WorktreeRecord, repo: String) throws -> Worktree {
        let path = WorktreePolicy.normalized(record.path)
        guard !record.isPrunable else {
            return Worktree(
                path: path, repoPath: repo, branch: record.branch, head: record.head,
                isLocked: record.isLocked, isPrunable: true, lastActivity: nil,
                uncommittedCount: 0, unpushedCount: 0
            )
        }
        return Worktree(
            path: path,
            repoPath: repo,
            branch: record.branch,
            head: record.head,
            isLocked: record.isLocked,
            isPrunable: false,
            lastActivity: try git.lastActivity(worktree: path),
            uncommittedCount: try git.uncommittedCount(worktree: path),
            unpushedCount: try git.unpushedCount(worktree: path, branch: record.branch)
        )
    }
}

private final class ScanResults: @unchecked Sendable {
    private var storage: [RepoScan?]
    private let lock = NSLock()

    init(count: Int) { storage = Array(repeating: nil, count: count) }

    func set(_ scan: RepoScan, at index: Int) {
        lock.lock()
        storage[index] = scan
        lock.unlock()
    }

    var values: [RepoScan] {
        lock.lock()
        defer { lock.unlock() }
        return storage.compactMap { $0 }
    }
}
