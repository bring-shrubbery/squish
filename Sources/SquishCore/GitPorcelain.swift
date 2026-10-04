import Foundation

/// One record of `git worktree list --porcelain`.
public struct WorktreeRecord: Equatable, Sendable {
    public let path: String
    public let head: String
    /// The short branch name; nil for a detached HEAD or a bare repo.
    public let branch: String?
    /// git lists the main worktree first.
    public let isMain: Bool
    public let isBare: Bool
    public let isLocked: Bool
    public let isPrunable: Bool

    public init(
        path: String, head: String, branch: String?,
        isMain: Bool, isBare: Bool, isLocked: Bool, isPrunable: Bool
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isMain = isMain
        self.isBare = isBare
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}

public enum GitPorcelain {
    /// Records are separated by blank lines; each starts with `worktree <path>`.
    public static func worktrees(_ output: String) -> [WorktreeRecord] {
        var records: [WorktreeRecord] = []
        var fields: [String] = []

        func flush() {
            defer { fields = [] }
            guard let first = fields.first, first.hasPrefix("worktree ") else { return }
            let path = String(first.dropFirst("worktree ".count))
            var head = ""
            var branch: String?
            var bare = false
            var locked = false
            var prunable = false
            for field in fields.dropFirst() {
                if field.hasPrefix("HEAD ") {
                    head = String(field.dropFirst("HEAD ".count))
                } else if field.hasPrefix("branch ") {
                    let ref = String(field.dropFirst("branch ".count))
                    branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
                } else if field == "bare" {
                    bare = true
                } else if field == "locked" || field.hasPrefix("locked ") {
                    locked = true
                } else if field == "prunable" || field.hasPrefix("prunable ") {
                    prunable = true
                }
            }
            records.append(WorktreeRecord(
                path: path, head: head, branch: branch, isMain: records.isEmpty,
                isBare: bare, isLocked: locked, isPrunable: prunable
            ))
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { flush() } else { fields.append(String(line)) }
        }
        flush()
        return records
    }

    /// One entry per non-blank line of `git status --porcelain` (v1; a rename is one line).
    public static func statusEntryCount(_ output: String) -> Int {
        output.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }
}
