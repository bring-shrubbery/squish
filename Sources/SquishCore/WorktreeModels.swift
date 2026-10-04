import Foundation

/// The coding agent that created a worktree, judged from where it lives.
public enum WorktreeAgent: String, Equatable, Sendable {
    case claudeCode = "Claude Code"

    public static func detect(path: String) -> WorktreeAgent? {
        path.contains("/.claude/worktrees/") ? .claudeCode : nil
    }
}

/// A linked git worktree, as Squish shows it.
public struct Worktree: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    /// The repo's main worktree.
    public let repoPath: String
    /// nil for a detached HEAD.
    public let branch: String?
    public let head: String
    public let isLocked: Bool
    /// git reports the worktree's directory as missing.
    public let isPrunable: Bool
    /// The later of the HEAD commit date and the last git operation in the worktree.
    public let lastActivity: Date?
    /// Entries in `git status --porcelain`, untracked included, ignored excluded.
    public let uncommittedCount: Int
    /// Commits reachable from HEAD that are on no remote and no other local branch.
    public let unpushedCount: Int
    /// Allocated bytes on disk; nil while unmeasured.
    public var sizeBytes: Int64?
    /// Why git could not read this worktree's details; such a worktree is listed but not removable.
    public let detailError: String?

    public init(
        path: String,
        repoPath: String,
        branch: String?,
        head: String,
        isLocked: Bool,
        isPrunable: Bool,
        lastActivity: Date?,
        uncommittedCount: Int,
        unpushedCount: Int,
        sizeBytes: Int64? = nil,
        detailError: String? = nil
    ) {
        self.path = path
        self.repoPath = repoPath
        self.branch = branch
        self.head = head
        self.isLocked = isLocked
        self.isPrunable = isPrunable
        self.lastActivity = lastActivity
        self.uncommittedCount = uncommittedCount
        self.unpushedCount = unpushedCount
        self.sizeBytes = sizeBytes
        self.detailError = detailError
    }

    public var agent: WorktreeAgent? { WorktreeAgent.detect(path: path) }

    public var displayName: String { branch ?? "detached \(head.prefix(7))" }
}

public struct WorktreeThresholds: Equatable, Sendable {
    public static let defaultMaxAgeDays = 14
    public static let defaultMaxSizeBytes: Int64 = 1_000_000_000

    public var maxAgeDays: Int
    public var maxSizeBytes: Int64

    public init(maxAgeDays: Int = defaultMaxAgeDays, maxSizeBytes: Int64 = defaultMaxSizeBytes) {
        self.maxAgeDays = maxAgeDays
        self.maxSizeBytes = maxSizeBytes
    }
}

public enum WorktreeFlag: Equatable, Sendable {
    case age(days: Int)
    case size(bytes: Int64)
}

public enum WorktreeRemoval: Equatable, Sendable {
    /// Clean: one confirmation, `git worktree remove`.
    case confirm
    /// Work exists only here: a second confirmation, then `git worktree remove --force`.
    case confirmLosingWork(uncommitted: Int, unpushed: Int, detached: Bool)
    case blocked(reason: String)
    /// The directory is already gone: `git worktree prune`.
    case pruneOnly
}

public enum WorktreePolicy {
    public static let liveSessionWindow: TimeInterval = 600

    /// Symlinks resolved, so `/var/…` and `/private/var/…` compare equal.
    /// Uses realpath(3), which keeps the canonical `/private/…` form git prints
    /// (Foundation's resolvingSymlinksInPath strips `/private` inconsistently).
    /// A path that no longer exists resolves its nearest existing ancestor.
    public static func normalized(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let resolved = realpath(standardized, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = (standardized as NSString).deletingLastPathComponent
        guard parent != standardized else { return standardized }
        return (normalized(parent) as NSString).appendingPathComponent((standardized as NSString).lastPathComponent)
    }

    public static func liveSessionPaths(
        _ sessions: [CodingSession],
        now: Date,
        window: TimeInterval = liveSessionWindow
    ) -> [String] {
        sessions
            .filter { now.timeIntervalSince($0.updatedAt) <= window }
            .map { normalized($0.projectPath) }
    }

    public static func hasActiveSession(_ worktree: Worktree, activeSessionPaths: [String]) -> Bool {
        let root = worktree.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return activeSessionPaths.contains { $0 == root || $0.hasPrefix(prefix) }
    }

    public static func flags(
        for worktree: Worktree,
        thresholds: WorktreeThresholds,
        activeSessionPaths: [String],
        now: Date
    ) -> [WorktreeFlag] {
        guard !worktree.isPrunable, !hasActiveSession(worktree, activeSessionPaths: activeSessionPaths) else {
            return []
        }
        var flags: [WorktreeFlag] = []
        if let last = worktree.lastActivity {
            let age = now.timeIntervalSince(last)
            if age > TimeInterval(thresholds.maxAgeDays) * 86_400 {
                flags.append(.age(days: Int(age / 86_400)))
            }
        }
        if let size = worktree.sizeBytes, size > thresholds.maxSizeBytes {
            flags.append(.size(bytes: size))
        }
        return flags
    }

    public static func removal(for worktree: Worktree, activeSessionPaths: [String]) -> WorktreeRemoval {
        if worktree.isPrunable { return .pruneOnly }
        if let detailError = worktree.detailError { return .blocked(reason: detailError) }
        if hasActiveSession(worktree, activeSessionPaths: activeSessionPaths) {
            return .blocked(reason: "An agent session is working in this worktree.")
        }
        if worktree.isLocked {
            return .blocked(reason: "This worktree is locked. Run git worktree unlock to allow removal.")
        }
        if worktree.uncommittedCount > 0 || worktree.unpushedCount > 0 {
            return .confirmLosingWork(
                uncommitted: worktree.uncommittedCount,
                unpushed: worktree.unpushedCount,
                detached: worktree.branch == nil
            )
        }
        return .confirm
    }

    /// The flagged worktrees "Remove flagged" removes (clean ones) and skips (the rest).
    public static func bulkRemovable(
        _ worktrees: [Worktree],
        thresholds: WorktreeThresholds,
        activeSessionPaths: [String],
        now: Date
    ) -> (remove: [Worktree], skipped: [Worktree]) {
        let flagged = worktrees.filter {
            !flags(for: $0, thresholds: thresholds, activeSessionPaths: activeSessionPaths, now: now).isEmpty
        }
        let remove = flagged.filter { removal(for: $0, activeSessionPaths: activeSessionPaths) == .confirm }
        let skipped = flagged.filter { removal(for: $0, activeSessionPaths: activeSessionPaths) != .confirm }
        return (remove, skipped)
    }
}
