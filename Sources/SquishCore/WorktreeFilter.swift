import Foundation

/// How a yes/no property of a worktree narrows the list.
public enum WorktreeFilterChoice: String, CaseIterable, Sendable, Identifiable {
    case any
    case only
    case exclude

    public var id: String { rawValue }

    func allows(_ value: Bool) -> Bool {
        switch self {
        case .any: true
        case .only: value
        case .exclude: !value
        }
    }
}

public enum WorktreeSort: String, CaseIterable, Sendable, Identifiable {
    /// Largest first; unmeasured last.
    case largest
    /// Least recent activity first; unknown activity last.
    case oldest
    /// Most recent activity first; unknown activity last.
    case newest
    case name

    public var id: String { rawValue }
}

/// What the Worktrees list shows and in which order. Every field at its default shows everything.
public struct WorktreeFilter: Equatable, Sendable {
    /// Matched case-insensitively against the branch (or detached name) and the path.
    public var query = ""
    /// Past an age or size threshold.
    public var flagged: WorktreeFilterChoice = .any
    /// A process or agent session is working in it.
    public var inUse: WorktreeFilterChoice = .any
    /// Uncommitted changes or unpushed commits.
    public var withWork: WorktreeFilterChoice = .any
    /// Created by a coding agent.
    public var agentMade: WorktreeFilterChoice = .any
    public var locked: WorktreeFilterChoice = .any
    /// The directory is gone.
    public var missing: WorktreeFilterChoice = .any
    /// 0 for any size; otherwise only measured worktrees at least this large.
    public var minSizeBytes: Int64 = 0
    /// 0 for any age; otherwise only worktrees whose last activity is at least this many days ago.
    public var minIdleDays = 0
    public var sort: WorktreeSort = .largest

    public static let sizeSteps: [Int64] = [
        0, 100_000_000, 500_000_000, 1_000_000_000, 2_000_000_000, 5_000_000_000, 10_000_000_000,
    ]
    public static let idleSteps = [0, 1, 7, 14, 30, 90]

    public init() {}

    public var isDefault: Bool { self == WorktreeFilter() }

    /// The facts the filter cannot compute alone (`flagged` needs the thresholds and `inUse`
    /// the live paths) are passed in.
    public func matches(_ worktree: Worktree, flagged isFlagged: Bool, inUse isInUse: Bool, now: Date) -> Bool {
        guard flagged.allows(isFlagged), inUse.allows(isInUse),
              withWork.allows(worktree.uncommittedCount > 0 || worktree.unpushedCount > 0),
              agentMade.allows(worktree.agent != nil),
              locked.allows(worktree.isLocked),
              missing.allows(worktree.isPrunable)
        else { return false }
        if minSizeBytes > 0 {
            guard let size = worktree.sizeBytes, size >= minSizeBytes else { return false }
        }
        if minIdleDays > 0 {
            guard let last = worktree.lastActivity,
                  now.timeIntervalSince(last) >= TimeInterval(minIdleDays) * 86_400
            else { return false }
        }
        let needle = query.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            guard worktree.displayName.localizedCaseInsensitiveContains(needle)
                || worktree.path.localizedCaseInsensitiveContains(needle)
            else { return false }
        }
        return true
    }

    public static func sorted(_ worktrees: [Worktree], by sort: WorktreeSort) -> [Worktree] {
        switch sort {
        case .largest:
            worktrees.sorted { ($0.sizeBytes ?? -1) > ($1.sizeBytes ?? -1) }
        case .oldest:
            worktrees.sorted { ($0.lastActivity ?? .distantFuture) < ($1.lastActivity ?? .distantFuture) }
        case .newest:
            worktrees.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        case .name:
            worktrees.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }
    }
}

/// What removing a chosen set of worktrees would do, from the last scan. Removal re-checks
/// each one against git right before deleting it.
public struct WorktreeBulkPlan: Equatable, Sendable {
    /// A worktree with work in it and the counts the user is shown; removal refuses if git
    /// reports more by the time it runs.
    public struct Loss: Equatable, Sendable {
        public let worktree: Worktree
        public let uncommitted: Int
        public let unpushed: Int
        public let detached: Bool
    }

    public struct Skip: Equatable, Sendable {
        public let worktree: Worktree
        public let reason: String
    }

    /// Clean: `git worktree remove`.
    public var clean: [Worktree] = []
    /// Work exists only here: `git worktree remove --force` after a second confirmation.
    public var losingWork: [Loss] = []
    /// The directory is gone: `git worktree prune`.
    public var prune: [Worktree] = []
    /// In use, locked or unreadable.
    public var skipped: [Skip] = []

    public init() {}

    public var isEmpty: Bool { clean.isEmpty && losingWork.isEmpty && prune.isEmpty }

    /// Everything the plan would act on, in the order it was given.
    public var acted: [Worktree] { clean + losingWork.map(\.worktree) + prune }

    public var bytes: Int64 { acted.compactMap(\.sizeBytes).reduce(0, +) }
}

extension WorktreePolicy {
    /// Sorts the given worktrees into what a bulk removal does with each.
    public static func bulkPlan(_ worktrees: [Worktree], activeSessionPaths: [String]) -> WorktreeBulkPlan {
        var plan = WorktreeBulkPlan()
        for worktree in worktrees {
            switch removal(for: worktree, activeSessionPaths: activeSessionPaths) {
            case .confirm:
                plan.clean.append(worktree)
            case let .confirmLosingWork(uncommitted, unpushed, detached):
                plan.losingWork.append(
                    .init(worktree: worktree, uncommitted: uncommitted, unpushed: unpushed, detached: detached)
                )
            case .pruneOnly:
                plan.prune.append(worktree)
            case .blocked(let reason):
                plan.skipped.append(.init(worktree: worktree, reason: reason))
            }
        }
        return plan
    }
}
