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
        var sessionSeen = Set<String>()
        let uniqueSessionPaths = sessionPaths.map(WorktreePolicy.normalized).filter { sessionSeen.insert($0).inserted }
        for candidate in RepoDiscovery.candidates(under: root, maxDepth: maxDepth) + uniqueSessionPaths {
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

    /// A failure listing the repo becomes `RepoScan.error`; a failure reading one worktree
    /// only marks that worktree with `detailError`.
    public func scan(repo: String) -> RepoScan {
        let repo = WorktreePolicy.normalized(repo)
        do {
            let worktrees = try git.listWorktrees(repo: repo)
                .filter { !$0.isMain && !$0.isBare }
                .map { record in worktree(from: record, repo: repo) }
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

    private func worktree(from record: WorktreeRecord, repo: String) -> Worktree {
        let path = WorktreePolicy.normalized(record.path)
        func make(lastActivity: Date?, uncommitted: Int, unpushed: Int, detailError: String? = nil) -> Worktree {
            Worktree(
                path: path, repoPath: repo, branch: record.branch, head: record.head,
                isLocked: record.isLocked, isPrunable: record.isPrunable, lastActivity: lastActivity,
                uncommittedCount: uncommitted, unpushedCount: unpushed, detailError: detailError
            )
        }
        guard !record.isPrunable else {
            return make(lastActivity: nil, uncommitted: 0, unpushed: 0)
        }
        do {
            return make(
                lastActivity: try git.lastActivity(worktree: path),
                uncommitted: try git.uncommittedCount(worktree: path),
                unpushed: try git.unpushedCount(worktree: path, branch: record.branch)
            )
        } catch {
            return make(lastActivity: nil, uncommitted: 0, unpushed: 0, detailError: error.localizedDescription)
        }
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
