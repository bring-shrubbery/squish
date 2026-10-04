import Foundation

/// Why a removal was refused before anything was deleted.
public struct RemovalRefusal: Error, Equatable, LocalizedError {
    public let reason: String

    public init(_ reason: String) { self.reason = reason }

    public var errorDescription: String? { reason }
}

/// Removes a worktree only after re-reading its state from git, never from an earlier scan.
/// Blocking; run off the main actor.
public enum WorktreeRemover {
    public static func rescueBranchBase(head: String) -> String {
        "squish/rescued-\(head.prefix(7))"
    }

    /// Re-reads the worktree from git and removes it if `WorktreePolicy.freshRemovalCheck` allows.
    /// A forced removal of a detached HEAD with unique commits first saves them on a new branch
    /// (`squish/rescued-<short sha>`, suffixed `-2`, `-3`… when taken), since `git worktree remove`
    /// deletes the worktree's HEAD reflog. Returns that branch's name, if one was made.
    /// - Parameter activePaths: normalized cwds of processes and live sessions, probed just before.
    /// - Throws: `RemovalRefusal` when it refused (nothing deleted), or the git error.
    @discardableResult
    public static func remove(
        _ worktree: Worktree,
        git: any GitClient,
        activePaths: [String],
        force: Bool,
        confirmedUncommitted: Int = 0,
        confirmedUnpushed: Int = 0
    ) throws -> String? {
        let path = WorktreePolicy.normalized(worktree.path)
        let record = try git.listWorktrees(repo: worktree.repoPath).first {
            !$0.isMain && WorktreePolicy.normalized($0.path) == path
        }
        guard let record else {
            throw RemovalRefusal("This worktree is no longer listed. Refresh and try again.")
        }
        if record.isPrunable { throw RemovalRefusal("The directory is gone; use Prune instead.") }
        if record.isLocked {
            throw RemovalRefusal("This worktree is locked. Run git worktree unlock to allow removal.")
        }
        guard record.branch == worktree.branch else {
            throw RemovalRefusal("This worktree changed branch since it was scanned. Refresh and try again.")
        }
        let uncommitted = try git.uncommittedCount(worktree: path)
        let unpushed = try git.unpushedCount(worktree: path, branch: record.branch)
        let isActive = WorktreePolicy.hasActiveSession(worktree, activeSessionPaths: activePaths)
        if let reason = WorktreePolicy.freshRemovalCheck(
            uncommitted: uncommitted,
            unpushed: unpushed,
            isActive: isActive,
            force: force,
            confirmedUncommitted: confirmedUncommitted,
            confirmedUnpushed: confirmedUnpushed
        ) {
            throw RemovalRefusal(reason)
        }
        var rescued: String?
        if force, record.branch == nil, unpushed > 0 {
            rescued = try rescue(head: record.head, repo: worktree.repoPath, git: git)
        }
        try git.remove(worktree: path, repo: worktree.repoPath, force: force)
        return rescued
    }

    private static func rescue(head: String, repo: String, git: any GitClient) throws -> String {
        let base = rescueBranchBase(head: head)
        for attempt in 1...100 {
            let name = attempt == 1 ? base : "\(base)-\(attempt)"
            do {
                try git.createBranch(name: name, at: head, repo: repo)
                return name
            } catch GitError.failed(let message) where message.contains("already exists") {
                continue
            } catch {
                throw RemovalRefusal(
                    "Couldn't save the detached commits on a branch, so nothing was removed: \(error.localizedDescription)"
                )
            }
        }
        throw RemovalRefusal("Couldn't find a free squish/rescued-… branch name, so nothing was removed.")
    }
}
