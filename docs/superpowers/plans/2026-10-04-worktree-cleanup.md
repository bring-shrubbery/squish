# Worktree Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Worktrees section in Squish that finds every linked git worktree of the repos under the watched folder, shows its age and size, flags stale or oversized ones, and removes them without losing work.

**Architecture:** Pure logic and git access live in `SquishCore` (models and policy, porcelain parsers, a `GitClient` protocol with a `Process`-backed implementation, repo discovery, directory sizing, and a scanner that combines them), all unit- or integration-tested. `SquishApp` gets a `WorktreeStore` observable object that owns refresh, thresholds and removal, and a `WorktreesView` section with a sidebar badge.

**Tech Stack:** Swift 6 toolchain in Swift 5 language mode, SwiftUI/AppKit, XCTest, `/usr/bin/git`.

**Spec:** `docs/superpowers/specs/2026-10-04-worktree-cleanup-design.md`

## Global Constraints

- macOS 14 minimum; `swiftLanguageModes: [.v5]` (Package.swift); no new package dependencies.
- CI fails on any compiler warning in `Sources/Squish*/` — build warning-free.
- git is run as `/usr/bin/git` with a 15-second timeout per command, with `GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0`, `LC_ALL=C`.
- Default thresholds: 14 days, 1 GB = `1_000_000_000` bytes (decimal, as Finder shows). A worktree is flagged when it passes either (strictly greater than).
- A session counts as live when its `updatedAt` is within 600 seconds (`WorktreePolicy.liveSessionWindow`).
- Removal never deletes files directly: only `git worktree remove [--force]` and `git worktree prune`. Branches are never deleted.
- Every path compared or used as a key is normalized with `WorktreePolicy.normalized(_:)` (symlinks resolved; `/var` and `/private/var` must compare equal).
- Commits: conventional subjects, `feat(core): …` for SquishCore, `feat(app): …` for SquishApp, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Tests: XCTest in `Tests/SquishCoreTests/`, run with `swift test --filter <TestClass>`.

## Review Focus

1. A session in `/x/wt-2` must not count as active in worktree `/x/wt` (prefix without a path boundary) — test in Task 1.
2. Temp and home paths reached through symlinks (`/var/folders/…` vs `/private/var/folders/…` as git prints them) must still match sessions and dedupe repos — tests in Tasks 1 and 6.
3. A worktree whose only untracked content is gitignored (`node_modules/`) is clean: one confirmation, non-forced removal succeeds — test in Task 3.
4. A worktree with thousands of untracked files must not hang the git pipe (64 KB pipe buffer) — test in Task 3.
5. A worktree directory deleted by hand shows as prunable and is only pruned, never "removed" — tests in Tasks 2 and 3.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Sources/SquishCore/WorktreeModels.swift` (create) | `Worktree`, `WorktreeAgent`, `WorktreeThresholds`, `WorktreeFlag`, `WorktreeRemoval`, `WorktreePolicy` |
| `Sources/SquishCore/GitPorcelain.swift` (create) | `WorktreeRecord`, parsers for `worktree list --porcelain` and `status --porcelain` |
| `Sources/SquishCore/GitClient.swift` (create) | `GitError`, `GitClient` protocol, `ProcessGitClient` |
| `Sources/SquishCore/RepoDiscovery.swift` (create) | shallow walk for repo candidates |
| `Sources/SquishCore/DirectorySizer.swift` (create) | allocated-size measurement with a cache |
| `Sources/SquishCore/WorktreeScanner.swift` (create) | `RepoScan`, `WorktreeScanner` |
| `Sources/SquishApp/WorktreeStore.swift` (create) | app state for the section |
| `Sources/SquishApp/WorktreesView.swift` (create) | the section UI |
| `Sources/SquishApp/AppState.swift` (modify) | `AppSection.worktrees` |
| `Sources/SquishApp/RootView.swift` (modify) | routing, sidebar badge, store wiring |
| `Sources/SquishApp/SquishApp.swift` (modify) | own the store |
| `Tests/SquishCoreTests/WorktreePolicyTests.swift`, `GitPorcelainTests.swift`, `ProcessGitClientTests.swift`, `RepoDiscoveryTests.swift`, `DirectorySizerTests.swift`, `WorktreeScannerTests.swift`, `GitFixture.swift` (create) | tests |

---

### Task 1: Worktree models and policy

**Files:**
- Create: `Sources/SquishCore/WorktreeModels.swift`
- Test: `Tests/SquishCoreTests/WorktreePolicyTests.swift`

**Interfaces:**
- Consumes: `CodingSession` (`projectPath: String`, `updatedAt: Date`) from `Sources/SquishCore/Domain.swift`.
- Produces: `Worktree`, `WorktreeAgent`, `WorktreeThresholds`, `WorktreeFlag`, `WorktreeRemoval`, and `WorktreePolicy.normalized(_:)`, `.liveSessionPaths(_:now:window:)`, `.hasActiveSession(_:activeSessionPaths:)`, `.flags(for:thresholds:activeSessionPaths:now:)`, `.removal(for:activeSessionPaths:)`, `.bulkRemovable(_:thresholds:activeSessionPaths:now:)`, exactly as below.

- [ ] **Step 1: Write the failing tests**

`Tests/SquishCoreTests/WorktreePolicyTests.swift`:

```swift
import Foundation
import XCTest
@testable import SquishCore

final class WorktreePolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400

    private func make(
        path: String = "/repo/.claude/worktrees/feature",
        branch: String? = "feature",
        lastActivity: Date? = nil,
        size: Int64? = nil,
        uncommitted: Int = 0,
        unpushed: Int = 0,
        locked: Bool = false,
        prunable: Bool = false
    ) -> Worktree {
        Worktree(
            path: path, repoPath: "/repo", branch: branch, head: "0123456789abcdef",
            isLocked: locked, isPrunable: prunable, lastActivity: lastActivity,
            uncommittedCount: uncommitted, unpushedCount: unpushed, sizeBytes: size
        )
    }

    func testAgentDetectedFromClaudeWorktreePath() {
        XCTAssertEqual(make().agent, .claudeCode)
        XCTAssertNil(make(path: "/repo-feature").agent)
    }

    func testDisplayNameFallsBackToDetachedHead() {
        XCTAssertEqual(make().displayName, "feature")
        XCTAssertEqual(make(branch: nil).displayName, "detached 0123456")
    }

    func testAgeFlagIsStrictlyPastThreshold() {
        let thresholds = WorktreeThresholds()
        let atLimit = make(lastActivity: now.addingTimeInterval(-14 * day))
        let past = make(lastActivity: now.addingTimeInterval(-15 * day))
        XCTAssertEqual(WorktreePolicy.flags(for: atLimit, thresholds: thresholds, activeSessionPaths: [], now: now), [])
        XCTAssertEqual(WorktreePolicy.flags(for: past, thresholds: thresholds, activeSessionPaths: [], now: now), [.age(days: 15)])
    }

    func testSizeFlagIsStrictlyPastThreshold() {
        let thresholds = WorktreeThresholds()
        XCTAssertEqual(WorktreePolicy.flags(for: make(size: 1_000_000_000), thresholds: thresholds, activeSessionPaths: [], now: now), [])
        XCTAssertEqual(
            WorktreePolicy.flags(for: make(size: 1_000_000_001), thresholds: thresholds, activeSessionPaths: [], now: now),
            [.size(bytes: 1_000_000_001)]
        )
    }

    func testBothFlagsAndUnknownValues() {
        let both = make(lastActivity: now.addingTimeInterval(-30 * day), size: 5_000_000_000)
        XCTAssertEqual(
            WorktreePolicy.flags(for: both, thresholds: WorktreeThresholds(), activeSessionPaths: [], now: now),
            [.age(days: 30), .size(bytes: 5_000_000_000)]
        )
        XCTAssertEqual(WorktreePolicy.flags(for: make(), thresholds: WorktreeThresholds(), activeSessionPaths: [], now: now), [])
    }

    func testActiveSessionSuppressesFlagsAndBlocksRemoval() {
        let old = make(lastActivity: now.addingTimeInterval(-30 * day))
        let inside = ["/repo/.claude/worktrees/feature/packages/app"]
        XCTAssertEqual(WorktreePolicy.flags(for: old, thresholds: WorktreeThresholds(), activeSessionPaths: inside, now: now), [])
        guard case .blocked = WorktreePolicy.removal(for: old, activeSessionPaths: inside) else {
            return XCTFail("expected blocked")
        }
    }

    func testSessionInSiblingWithSharedPrefixIsNotActive() {
        let worktree = make(path: "/x/wt")
        XCTAssertFalse(WorktreePolicy.hasActiveSession(worktree, activeSessionPaths: ["/x/wt-2"]))
        XCTAssertTrue(WorktreePolicy.hasActiveSession(worktree, activeSessionPaths: ["/x/wt"]))
        XCTAssertTrue(WorktreePolicy.hasActiveSession(worktree, activeSessionPaths: ["/x/wt/sub"]))
    }

    func testLiveSessionPathsUsesWindowAndNormalizesSymlinks() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fresh = session(path: tmp.path, updatedAt: now.addingTimeInterval(-60))
        let stale = session(path: "/elsewhere", updatedAt: now.addingTimeInterval(-601))
        let paths = WorktreePolicy.liveSessionPaths([fresh, stale], now: now)
        XCTAssertEqual(paths, [WorktreePolicy.normalized(tmp.path)])
        // The temporary directory lives under /var, a symlink to /private/var.
        XCTAssertTrue(paths[0].hasPrefix("/private/"))
    }

    func testRemovalCases() {
        XCTAssertEqual(WorktreePolicy.removal(for: make(), activeSessionPaths: []), .confirm)
        XCTAssertEqual(
            WorktreePolicy.removal(for: make(uncommitted: 4, unpushed: 2), activeSessionPaths: []),
            .confirmLosingWork(uncommitted: 4, unpushed: 2, detached: false)
        )
        XCTAssertEqual(
            WorktreePolicy.removal(for: make(branch: nil, unpushed: 1), activeSessionPaths: []),
            .confirmLosingWork(uncommitted: 0, unpushed: 1, detached: true)
        )
        XCTAssertEqual(WorktreePolicy.removal(for: make(prunable: true), activeSessionPaths: []), .pruneOnly)
        guard case .blocked = WorktreePolicy.removal(for: make(locked: true), activeSessionPaths: []) else {
            return XCTFail("expected blocked")
        }
    }

    func testPrunableIsNeverFlagged() {
        let gone = make(lastActivity: now.addingTimeInterval(-90 * day), prunable: true)
        XCTAssertEqual(WorktreePolicy.flags(for: gone, thresholds: WorktreeThresholds(), activeSessionPaths: [], now: now), [])
    }

    func testBulkRemovableTakesOnlyCleanFlaggedOnes() {
        let oldClean = make(path: "/a", lastActivity: now.addingTimeInterval(-30 * day))
        let oldDirty = make(path: "/b", lastActivity: now.addingTimeInterval(-30 * day), uncommitted: 1)
        let fresh = make(path: "/c", lastActivity: now)
        let result = WorktreePolicy.bulkRemovable(
            [oldClean, oldDirty, fresh], thresholds: WorktreeThresholds(), activeSessionPaths: [], now: now
        )
        XCTAssertEqual(result.remove.map(\.path), ["/a"])
        XCTAssertEqual(result.skipped.map(\.path), ["/b"])
    }

    private func session(path: String, updatedAt: Date) -> CodingSession {
        CodingSession(
            id: UUID().uuidString, provider: .claude, title: "t", projectPath: path, model: "m",
            usage: TokenUsage(), contextTokens: 0, contextWindow: 100_000,
            startedAt: updatedAt, updatedAt: updatedAt, logPath: "/tmp/x.jsonl"
        )
    }
}
```

Before running, check `AgentProvider`'s case for Claude Code and `TokenUsage`'s initializer in `Sources/SquishCore/Domain.swift` (`grep -n "enum AgentProvider" -A6 Sources/SquishCore/Domain.swift`, `grep -n "struct TokenUsage" -A20 Sources/SquishCore/Domain.swift`) and adjust the two expressions in `session(path:updatedAt:)` to match if they differ (for example `.claudeCode`, or `TokenUsage(input: 0, …)`).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter WorktreePolicyTests`
Expected: compile failure, `cannot find 'Worktree' in scope`.

- [ ] **Step 3: Implement the models and policy**

`Sources/SquishCore/WorktreeModels.swift`:

```swift
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
        sizeBytes: Int64? = nil
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
    public static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter WorktreePolicyTests`
Expected: `Executed 11 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SquishCore/WorktreeModels.swift Tests/SquishCoreTests/WorktreePolicyTests.swift
git commit -m "feat(core): worktree model and the flag and removal policy

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: git porcelain parsers

**Files:**
- Create: `Sources/SquishCore/GitPorcelain.swift`
- Test: `Tests/SquishCoreTests/GitPorcelainTests.swift`

**Interfaces:**
- Produces: `WorktreeRecord` (`path`, `head`, `branch: String?`, `isMain`, `isBare`, `isLocked`, `isPrunable`), `GitPorcelain.worktrees(_ output: String) -> [WorktreeRecord]`, `GitPorcelain.statusEntryCount(_ output: String) -> Int`.

- [ ] **Step 1: Write the failing tests**

`Tests/SquishCoreTests/GitPorcelainTests.swift`:

```swift
import XCTest
@testable import SquishCore

final class GitPorcelainTests: XCTestCase {
    func testParsesMainLinkedDetachedLockedAndPrunable() {
        let output = """
        worktree /Users/me/Projects/app
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /Users/me/Projects/app/.claude/worktrees/fix login
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/fix-login

        worktree /Users/me/Projects/app-detached
        HEAD 3333333333333333333333333333333333333333
        detached

        worktree /Users/me/Projects/app-locked
        HEAD 4444444444444444444444444444444444444444
        branch refs/heads/locked-one
        locked moving to another disk

        worktree /Users/me/Projects/app-gone
        HEAD 5555555555555555555555555555555555555555
        branch refs/heads/gone
        prunable gitdir file points to non-existent location

        """
        let records = GitPorcelain.worktrees(output)
        XCTAssertEqual(records.count, 5)
        XCTAssertEqual(records[0], WorktreeRecord(
            path: "/Users/me/Projects/app", head: "1111111111111111111111111111111111111111",
            branch: "main", isMain: true, isBare: false, isLocked: false, isPrunable: false
        ))
        XCTAssertEqual(records[1].path, "/Users/me/Projects/app/.claude/worktrees/fix login")
        XCTAssertEqual(records[1].branch, "fix-login")
        XCTAssertFalse(records[1].isMain)
        XCTAssertNil(records[2].branch)
        XCTAssertEqual(records[2].head, "3333333333333333333333333333333333333333")
        XCTAssertTrue(records[3].isLocked)
        XCTAssertTrue(records[4].isPrunable)
    }

    func testBareMainAndBareLock() {
        let output = "worktree /srv/repo.git\nbare\n\nworktree /srv/wt\nHEAD abc\nbranch refs/heads/x\nlocked\n"
        let records = GitPorcelain.worktrees(output)
        XCTAssertTrue(records[0].isBare)
        XCTAssertTrue(records[0].isMain)
        XCTAssertTrue(records[1].isLocked)
    }

    func testEmptyOutput() {
        XCTAssertEqual(GitPorcelain.worktrees(""), [])
    }

    func testStatusEntryCount() {
        let output = " M Sources/a.swift\nM  Sources/b.swift\n?? notes.txt\nR  old.swift -> new.swift\n"
        XCTAssertEqual(GitPorcelain.statusEntryCount(output), 4)
        XCTAssertEqual(GitPorcelain.statusEntryCount(""), 0)
        XCTAssertEqual(GitPorcelain.statusEntryCount("\n"), 0)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter GitPorcelainTests`
Expected: compile failure, `cannot find 'GitPorcelain' in scope`.

- [ ] **Step 3: Implement the parsers**

`Sources/SquishCore/GitPorcelain.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter GitPorcelainTests`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SquishCore/GitPorcelain.swift Tests/SquishCoreTests/GitPorcelainTests.swift
git commit -m "feat(core): parse git worktree list and status porcelain output

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: GitClient and the process-backed client

**Files:**
- Create: `Sources/SquishCore/GitClient.swift`
- Create: `Tests/SquishCoreTests/GitFixture.swift`
- Test: `Tests/SquishCoreTests/ProcessGitClientTests.swift`

**Interfaces:**
- Consumes: `WorktreeRecord`, `GitPorcelain` (Task 2); `WorktreePolicy.normalized` (Task 1).
- Produces:
  - `GitError` (`.unavailable`, `.timedOut(command: String)`, `.failed(message: String)`; `LocalizedError`).
  - `protocol GitClient: Sendable` with `listWorktrees(repo:) throws -> [WorktreeRecord]`, `uncommittedCount(worktree:) throws -> Int`, `unpushedCount(worktree:branch:) throws -> Int`, `lastActivity(worktree:) throws -> Date?`, `mainRepoRoot(containing:) throws -> String?`, `remove(worktree:repo:force:) throws`, `prune(repo:) throws`.
  - `ProcessGitClient(gitPath: String = "/usr/bin/git", timeout: TimeInterval = 15)` and its internal `run(_ arguments: [String], in directory: String) throws -> String`.
  - Test helper `GitFixture` (tests only).

- [ ] **Step 1: Write the test fixture**

`Tests/SquishCoreTests/GitFixture.swift`:

```swift
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
```

- [ ] **Step 2: Write the failing tests**

`Tests/SquishCoreTests/ProcessGitClientTests.swift`:

```swift
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter ProcessGitClientTests`
Expected: compile failure, `cannot find 'ProcessGitClient' in scope`.

- [ ] **Step 4: Implement the client**

`Sources/SquishCore/GitClient.swift`:

```swift
import Foundation

public enum GitError: Error, Equatable, LocalizedError {
    /// No usable git: the binary is missing or the command line tools are not installed.
    case unavailable
    case timedOut(command: String)
    case failed(message: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "git is not available. Install the command line tools with xcode-select --install."
        case .timedOut(let command):
            "git \(command) took too long and was stopped."
        case .failed(let message):
            message
        }
    }
}

/// The git operations the Worktrees section needs. Implementations block; call them off the main actor.
public protocol GitClient: Sendable {
    func listWorktrees(repo: String) throws -> [WorktreeRecord]
    func uncommittedCount(worktree: String) throws -> Int
    func unpushedCount(worktree: String, branch: String?) throws -> Int
    func lastActivity(worktree: String) throws -> Date?
    /// The main worktree of the repo containing `path`; nil when it is not in a repo (or is bare).
    func mainRepoRoot(containing path: String) throws -> String?
    func remove(worktree: String, repo: String, force: Bool) throws
    func prune(repo: String) throws
}

public struct ProcessGitClient: GitClient {
    public let gitPath: String
    public let timeout: TimeInterval

    public init(gitPath: String = "/usr/bin/git", timeout: TimeInterval = 15) {
        self.gitPath = gitPath
        self.timeout = timeout
    }

    public func listWorktrees(repo: String) throws -> [WorktreeRecord] {
        GitPorcelain.worktrees(try run(["worktree", "list", "--porcelain"], in: repo))
    }

    public func uncommittedCount(worktree: String) throws -> Int {
        GitPorcelain.statusEntryCount(try run(["status", "--porcelain"], in: worktree))
    }

    public func unpushedCount(worktree: String, branch: String?) throws -> Int {
        var arguments = ["rev-list", "--count", "HEAD", "--not"]
        if let branch { arguments.append("--exclude=refs/heads/\(branch)") }
        arguments += ["--branches", "--remotes"]
        let output = try run(arguments, in: worktree).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(output) ?? 0
    }

    public func lastActivity(worktree: String) throws -> Date? {
        let commitOutput = try run(["log", "-1", "--format=%ct", "HEAD"], in: worktree)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let commitDate = TimeInterval(commitOutput).map(Date.init(timeIntervalSince1970:))
        let gitDir = try run(["rev-parse", "--path-format=absolute", "--git-dir"], in: worktree)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let index = URL(fileURLWithPath: gitDir).appendingPathComponent("index").path
        let indexDate = (try? FileManager.default.attributesOfItem(atPath: index))?[.modificationDate] as? Date
        return [commitDate, indexDate].compactMap { $0 }.max()
    }

    public func mainRepoRoot(containing path: String) throws -> String? {
        let output: String
        do {
            output = try run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: path)
        } catch GitError.failed {
            return nil
        }
        let commonDir = URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines))
        guard commonDir.lastPathComponent == ".git" else { return nil }
        return WorktreePolicy.normalized(commonDir.deletingLastPathComponent().path)
    }

    public func remove(worktree: String, repo: String, force: Bool) throws {
        try run(["worktree", "remove"] + (force ? ["--force"] : []) + [worktree], in: repo)
    }

    public func prune(repo: String) throws {
        try run(["worktree", "prune"], in: repo)
    }

    /// Runs git in `directory` and returns stdout. stdout and stderr are drained concurrently so
    /// large output cannot fill a pipe and stall the child.
    @discardableResult
    func run(_ arguments: [String], in directory: String) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GitError.failed(message: "No such directory: \(directory)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw GitError.unavailable
        }

        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.data = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            group.wait()
            process.waitUntilExit()
            throw GitError.timedOut(command: arguments.first ?? "")
        }
        process.waitUntilExit()

        let errorText = String(decoding: errBox.data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            // /usr/bin/git is a shim that fails this way when the command line tools are missing.
            if errorText.contains("xcrun: error") { throw GitError.unavailable }
            let message = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.failed(message: message.isEmpty ? "git \(arguments.first ?? "") failed" : message)
        }
        return String(decoding: outBox.data, as: UTF8.self)
    }
}

/// Written by exactly one reader closure, read after the DispatchGroup has finished.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter ProcessGitClientTests`
Expected: `Executed 12 tests, with 0 failures`. If `testLastActivityAndMainRepoRoot` fails on a `/var` vs `/private/var` mismatch, the fix belongs in `mainRepoRoot` (normalize), not in the test.

- [ ] **Step 6: Commit**

```bash
git add Sources/SquishCore/GitClient.swift Tests/SquishCoreTests/GitFixture.swift Tests/SquishCoreTests/ProcessGitClientTests.swift
git commit -m "feat(core): a git client for listing, inspecting and removing worktrees

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Repo discovery

**Files:**
- Create: `Sources/SquishCore/RepoDiscovery.swift`
- Test: `Tests/SquishCoreTests/RepoDiscoveryTests.swift`

**Interfaces:**
- Produces: `RepoDiscovery.skippedNames: Set<String>`, `RepoDiscovery.candidates(under root: URL, maxDepth: Int = 4, fileManager: FileManager = .default) -> [String]` — directories (depth 0…maxDepth, root is depth 0) that contain a `.git` entry (directory or file), sorted.

- [ ] **Step 1: Write the failing tests**

`Tests/SquishCoreTests/RepoDiscoveryTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter RepoDiscoveryTests`
Expected: compile failure, `cannot find 'RepoDiscovery' in scope`.

- [ ] **Step 3: Implement discovery**

`Sources/SquishCore/RepoDiscovery.swift`:

```swift
import Foundation

/// Finds directories that may be git repos (or linked worktrees) under the watched folder.
/// The scanner resolves each candidate to its main repo, so duplicates are harmless.
public enum RepoDiscovery {
    public static let skippedNames: Set<String> = [
        "node_modules", ".build", "DerivedData", "Pods", "vendor", "dist", "build", ".venv", "target"
    ]

    public static func candidates(
        under root: URL,
        maxDepth: Int = 4,
        fileManager: FileManager = .default
    ) -> [String] {
        var found: [String] = []
        var queue: [(url: URL, depth: Int)] = [(root.standardizedFileURL, 0)]
        while !queue.isEmpty {
            let (directory, depth) = queue.removeFirst()
            if fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                found.append(directory.path)
            }
            guard depth < maxDepth,
                  let children = try? fileManager.contentsOfDirectory(
                      at: directory,
                      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                      options: []
                  ) else { continue }
            for child in children {
                let name = child.lastPathComponent
                if skippedNames.contains(name) { continue }
                if name.hasPrefix("."), name != ".claude" { continue }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                queue.append((child, depth + 1))
            }
        }
        return found.sorted()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter RepoDiscoveryTests`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SquishCore/RepoDiscovery.swift Tests/SquishCoreTests/RepoDiscoveryTests.swift
git commit -m "feat(core): discover git repos under the watched folder

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Directory sizer

**Files:**
- Create: `Sources/SquishCore/DirectorySizer.swift`
- Test: `Tests/SquishCoreTests/DirectorySizerTests.swift`

**Interfaces:**
- Produces: `final class DirectorySizer: @unchecked Sendable` with `init()`, `size(of path: String, stamp: Date?) -> Int64?` (cached per path while `stamp` is unchanged; nil when the directory does not exist) and `static measure(_ url: URL) -> Int64?`.

- [ ] **Step 1: Write the failing tests**

`Tests/SquishCoreTests/DirectorySizerTests.swift`:

```swift
import Foundation
import XCTest
@testable import SquishCore

final class DirectorySizerTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("squish-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("nested"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ bytes: Int, to name: String) throws {
        try Data(count: bytes).write(to: dir.appendingPathComponent(name))
    }

    func testCountsAllocatedBytesRecursively() throws {
        try write(100_000, to: "a.bin")
        try write(200_000, to: "nested/b.bin")
        let size = try XCTUnwrap(DirectorySizer.measure(dir))
        XCTAssertGreaterThanOrEqual(size, 300_000)
        XCTAssertLessThan(size, 400_000)
    }

    func testMissingDirectoryIsNil() {
        XCTAssertNil(DirectorySizer.measure(dir.appendingPathComponent("gone")))
        XCTAssertNil(DirectorySizer().size(of: dir.appendingPathComponent("gone").path, stamp: nil))
    }

    func testCachesPerStamp() throws {
        let sizer = DirectorySizer()
        let stamp = Date(timeIntervalSince1970: 1)
        try write(100_000, to: "a.bin")
        let first = try XCTUnwrap(sizer.size(of: dir.path, stamp: stamp))
        try write(500_000, to: "b.bin")
        XCTAssertEqual(sizer.size(of: dir.path, stamp: stamp), first)
        let remeasured = try XCTUnwrap(sizer.size(of: dir.path, stamp: Date(timeIntervalSince1970: 2)))
        XCTAssertGreaterThan(remeasured, first)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter DirectorySizerTests`
Expected: compile failure, `cannot find 'DirectorySizer' in scope`.

- [ ] **Step 3: Implement the sizer**

`Sources/SquishCore/DirectorySizer.swift`:

```swift
import Foundation

/// Measures how much disk a directory tree takes (allocated bytes, as Finder's "on disk").
/// Results are cached per path until the caller's stamp (the worktree's last activity) changes.
public final class DirectorySizer: @unchecked Sendable {
    private struct Entry {
        let stamp: Date?
        let bytes: Int64
    }

    private var cache: [String: Entry] = [:]
    private let lock = NSLock()

    public init() {}

    public func size(of path: String, stamp: Date?) -> Int64? {
        lock.lock()
        let cached = cache[path]
        lock.unlock()
        if let cached, cached.stamp == stamp { return cached.bytes }
        guard let bytes = Self.measure(URL(fileURLWithPath: path)) else { return nil }
        lock.lock()
        cache[path] = Entry(stamp: stamp, bytes: bytes)
        lock.unlock()
        return bytes
    }

    public static func measure(_ url: URL) -> Int64? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return nil }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter DirectorySizerTests`
Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SquishCore/DirectorySizer.swift Tests/SquishCoreTests/DirectorySizerTests.swift
git commit -m "feat(core): measure a worktree's size on disk, cached by activity

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Worktree scanner

**Files:**
- Create: `Sources/SquishCore/WorktreeScanner.swift`
- Test: `Tests/SquishCoreTests/WorktreeScannerTests.swift`

**Interfaces:**
- Consumes: `GitClient`, `GitError`, `ProcessGitClient` (Task 3); `RepoDiscovery.candidates` (Task 4); `Worktree`, `WorktreePolicy.normalized` (Task 1); `WorktreeRecord` (Task 2).
- Produces: `RepoScan` (`id`/`repoPath: String`, `worktrees: [Worktree]`, `error: String?`); `WorktreeScanner(git: any GitClient = ProcessGitClient())` with `git`, `repos(root: URL, sessionPaths: [String], maxDepth: Int = 4) throws -> [String]` (throws only `GitError.unavailable`), `scan(repo: String) -> RepoScan`, `scanAll(repos: [String]) -> [RepoScan]` (order preserved).

- [ ] **Step 1: Write the failing tests**

`Tests/SquishCoreTests/WorktreeScannerTests.swift`:

```swift
import Foundation
import XCTest
@testable import SquishCore

private struct FakeGit: GitClient {
    var records: [String: [WorktreeRecord]] = [:]
    var failingRepo: String?
    var unavailable = false

    func listWorktrees(repo: String) throws -> [WorktreeRecord] {
        if repo == failingRepo { throw GitError.timedOut(command: "worktree") }
        return records[repo] ?? []
    }
    func uncommittedCount(worktree: String) throws -> Int { worktree.hasSuffix("dirty") ? 3 : 0 }
    func unpushedCount(worktree: String, branch: String?) throws -> Int { 0 }
    func lastActivity(worktree: String) throws -> Date? { Date(timeIntervalSince1970: 1_000) }
    func mainRepoRoot(containing path: String) throws -> String? {
        if unavailable { throw GitError.unavailable }
        return path.hasPrefix("/r") ? "/r" : nil
    }
    func remove(worktree: String, repo: String, force: Bool) throws {}
    func prune(repo: String) throws {}
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

    func testReposPropagateUnavailable() {
        let root = FileManager.default.temporaryDirectory
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter WorktreeScannerTests`
Expected: compile failure, `cannot find 'WorktreeScanner' in scope`.

- [ ] **Step 3: Implement the scanner**

`Sources/SquishCore/WorktreeScanner.swift`:

```swift
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
```

Note: `WorktreePolicy.normalized` resolves symlinks only for paths that exist; the fake paths in the unit tests (`/r/…`) do not exist and pass through unchanged, which the tests rely on.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter WorktreeScannerTests`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Run the whole suite**

Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: `Executed 101 tests, with 0 failures` (63 existing + 38 new).

- [ ] **Step 6: Commit**

```bash
git add Sources/SquishCore/WorktreeScanner.swift Tests/SquishCoreTests/WorktreeScannerTests.swift
git commit -m "feat(core): scan repos for their linked worktrees

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: WorktreeStore

**Files:**
- Create: `Sources/SquishApp/WorktreeStore.swift`

**Interfaces:**
- Consumes: everything in SquishCore from Tasks 1–6; `CodingSession`.
- Produces (`@MainActor final class WorktreeStore: ObservableObject`): `scans: [RepoScan]`, `sizes: [String: Int64]`, `unmeasurable: Set<String>`, `isRefreshing: Bool`, `gitUnavailable: Bool`, `rowErrors: [String: String]`, `lastReclaimed: Int64?`, `thresholds: WorktreeThresholds` (settable, persisted); `update(root: URL?, sessions: [CodingSession])`, `refresh()`, `worktrees: [Worktree]` (with sizes), `flags(for:) -> [WorktreeFlag]`, `removal(for:) -> WorktreeRemoval`, `flaggedCount: Int`, `totalBytes: Int64`, `flaggedBytes: Int64`, `remove(_:force:) async`, `prune(_:) async`, `removeFlagged() async -> [Worktree]` (returns skipped), `bulkPreview() -> (remove: [Worktree], skipped: [Worktree])`.

SquishApp has no test target; this task is verified by a warning-free build, and Task 8 checks it in the running app.

- [ ] **Step 1: Implement the store**

`Sources/SquishApp/WorktreeStore.swift`:

```swift
import Foundation
import SquishCore

/// State for the Worktrees section: scans the watched folder's repos, measures worktree sizes
/// in the background, and removes worktrees through git.
@MainActor
final class WorktreeStore: ObservableObject {
    @Published private(set) var scans: [RepoScan] = []
    @Published private(set) var sizes: [String: Int64] = [:]
    @Published private(set) var unmeasurable: Set<String> = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var gitUnavailable = false
    @Published private(set) var rowErrors: [String: String] = [:]
    @Published private(set) var lastReclaimed: Int64?
    @Published var thresholds: WorktreeThresholds {
        didSet {
            defaults.set(thresholds.maxAgeDays, forKey: Keys.maxAgeDays)
            defaults.set(NSNumber(value: thresholds.maxSizeBytes), forKey: Keys.maxSizeBytes)
        }
    }

    private enum Keys {
        static let maxAgeDays = "worktrees.maxAgeDays"
        static let maxSizeBytes = "worktrees.maxSizeBytes"
    }

    private let scanner: WorktreeScanner
    private let sizer = DirectorySizer()
    private let defaults: UserDefaults
    private var root: URL?
    private var sessions: [CodingSession] = []
    private var refreshTask: Task<Void, Never>?
    private var sizingTask: Task<Void, Never>?
    private var timer: Timer?

    init(scanner: WorktreeScanner = WorktreeScanner(), defaults: UserDefaults = .standard) {
        self.scanner = scanner
        self.defaults = defaults
        let days = defaults.object(forKey: Keys.maxAgeDays) as? Int ?? WorktreeThresholds.defaultMaxAgeDays
        let bytes = (defaults.object(forKey: Keys.maxSizeBytes) as? NSNumber)?.int64Value
            ?? WorktreeThresholds.defaultMaxSizeBytes
        thresholds = WorktreeThresholds(maxAgeDays: days, maxSizeBytes: bytes)
        // Hourly, so the sidebar badge stays current without the section open.
        timer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Called whenever the watched folder or the session list changes.
    func update(root: URL?, sessions: [CodingSession]) {
        let rootChanged = root?.standardizedFileURL != self.root?.standardizedFileURL
        self.root = root
        self.sessions = sessions
        if rootChanged {
            scans = []
            sizes = [:]
            refresh()
        }
    }

    var activeSessionPaths: [String] {
        WorktreePolicy.liveSessionPaths(sessions, now: Date())
    }

    var worktrees: [Worktree] {
        scans.flatMap(\.worktrees).map { worktree in
            var sized = worktree
            sized.sizeBytes = sizes[worktree.path]
            return sized
        }
    }

    func flags(for worktree: Worktree) -> [WorktreeFlag] {
        var sized = worktree
        sized.sizeBytes = sizes[worktree.path]
        return WorktreePolicy.flags(
            for: sized, thresholds: thresholds, activeSessionPaths: activeSessionPaths, now: Date()
        )
    }

    func removal(for worktree: Worktree) -> WorktreeRemoval {
        WorktreePolicy.removal(for: worktree, activeSessionPaths: activeSessionPaths)
    }

    var flaggedCount: Int { worktrees.filter { !flags(for: $0).isEmpty }.count }

    var totalBytes: Int64 { worktrees.compactMap(\.sizeBytes).reduce(0, +) }

    var flaggedBytes: Int64 {
        worktrees.filter { !flags(for: $0).isEmpty }.compactMap(\.sizeBytes).reduce(0, +)
    }

    func bulkPreview() -> (remove: [Worktree], skipped: [Worktree]) {
        WorktreePolicy.bulkRemovable(
            worktrees, thresholds: thresholds, activeSessionPaths: activeSessionPaths, now: Date()
        )
    }

    func refresh() {
        guard let root, refreshTask == nil else { return }
        isRefreshing = true
        let scanner = self.scanner
        let sessionPaths = sessions.map(\.projectPath)
        refreshTask = Task {
            let result = await Task.detached(priority: .utility) { () -> Result<[RepoScan], GitError> in
                do {
                    let repos = try scanner.repos(root: root, sessionPaths: sessionPaths)
                    return .success(scanner.scanAll(repos: repos))
                } catch let error as GitError {
                    return .failure(error)
                } catch {
                    return .failure(.failed(message: error.localizedDescription))
                }
            }.value
            switch result {
            case .success(let scans):
                self.scans = scans
                gitUnavailable = false
            case .failure(.unavailable):
                scans = []
                gitUnavailable = true
            case .failure:
                scans = []
            }
            isRefreshing = false
            refreshTask = nil
            measureSizes()
        }
    }

    /// Removes one worktree; returns the bytes it freed, or nil when git refused.
    @discardableResult
    func remove(_ worktree: Worktree, force: Bool) async -> Int64? {
        let git = scanner.git
        rowErrors[worktree.path] = nil
        let failure: String? = await Task.detached(priority: .userInitiated) {
            do {
                try git.remove(worktree: worktree.path, repo: worktree.repoPath, force: force)
                try? git.prune(repo: worktree.repoPath)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        let freed: Int64?
        if let failure {
            rowErrors[worktree.path] = failure
            freed = nil
        } else {
            freed = sizes[worktree.path] ?? 0
            sizes[worktree.path] = nil
            showReclaimed(freed ?? 0)
        }
        await rescan(repo: worktree.repoPath)
        return freed
    }

    func prune(_ worktree: Worktree) async {
        let git = scanner.git
        let failure: String? = await Task.detached(priority: .userInitiated) {
            do {
                try git.prune(repo: worktree.repoPath)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        rowErrors[worktree.path] = failure
        await rescan(repo: worktree.repoPath)
    }

    /// Removes every clean flagged worktree; returns the flagged ones it skipped.
    func removeFlagged() async -> [Worktree] {
        let (remove, skipped) = bulkPreview()
        var total: Int64 = 0
        for worktree in remove {
            if let freed = await self.remove(worktree, force: false) { total += freed }
        }
        showReclaimed(total)
        return skipped
    }

    private func showReclaimed(_ bytes: Int64) {
        lastReclaimed = bytes
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if lastReclaimed == bytes { lastReclaimed = nil }
        }
    }

    private func rescan(repo: String) async {
        let scanner = self.scanner
        let scan = await Task.detached(priority: .userInitiated) { scanner.scan(repo: repo) }.value
        if let index = scans.firstIndex(where: { $0.repoPath == repo }) {
            scans[index] = scan
        }
        measureSizes()
    }

    private func measureSizes() {
        sizingTask?.cancel()
        let targets = worktrees.filter { !$0.isPrunable }.map { ($0.path, $0.lastActivity) }
        let sizer = self.sizer
        sizingTask = Task {
            for (path, stamp) in targets {
                if Task.isCancelled { return }
                let bytes = await Task.detached(priority: .utility) { sizer.size(of: path, stamp: stamp) }.value
                if let bytes {
                    sizes[path] = bytes
                    unmeasurable.remove(path)
                } else {
                    unmeasurable.insert(path)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build warning-free**

Run: `swift build 2>&1 | grep -E "warning:|error:" | grep "Sources/Squish" ; echo "exit $?"`
Expected: no lines printed before `exit 1` (grep found nothing). Fix any warning before continuing; CI fails on them.

- [ ] **Step 3: Commit**

```bash
git add Sources/SquishApp/WorktreeStore.swift
git commit -m "feat(app): worktree store that scans, sizes and removes worktrees

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Worktrees section, sidebar badge and wiring

**Files:**
- Create: `Sources/SquishApp/WorktreesView.swift`
- Modify: `Sources/SquishApp/AppState.swift` (`AppSection`, lines 6–28)
- Modify: `Sources/SquishApp/RootView.swift` (`DashboardShell` switch and `Sidebar` badge)
- Modify: `Sources/SquishApp/SquishApp.swift` (own and inject the store)
- Modify: `README.md` ("What it does")

**Interfaces:**
- Consumes: `WorktreeStore` (Task 7), `PageHeader(eyebrow:title:subtitle:)`, `.appCard()`, `AppColors` (`RootView.swift`).
- Produces: `AppSection.worktrees`, `WorktreesView`.

- [ ] **Step 1: Add the section to `AppSection`**

In `Sources/SquishApp/AppState.swift`, add the case and its title and symbol:

```swift
enum AppSection: String, CaseIterable, Identifiable {
    case costs
    case compactAlerts
    case liveChats
    case worktrees

    var id: String { rawValue }

    var title: String {
        switch self {
        case .costs: "Costs"
        case .compactAlerts: "Compact alerts"
        case .liveChats: "Live chats"
        case .worktrees: "Worktrees"
        }
    }

    var symbol: String {
        switch self {
        case .costs: "chart.bar.xaxis"
        case .compactAlerts: "rectangle.topthird.inset.filled"
        case .liveChats: "bubble.left.and.bubble.right.fill"
        case .worktrees: "arrow.triangle.branch"
        }
    }
}
```

- [ ] **Step 2: Own and inject the store**

In `Sources/SquishApp/SquishApp.swift`, add the state object beside `appState` and inject it:

```swift
    @StateObject private var appState = AppState()
    @StateObject private var updates = Updates()
    @StateObject private var worktreeStore = WorktreeStore()
```

```swift
            RootView()
                .environmentObject(appState)
                .environmentObject(worktreeStore)
                .frame(minWidth: 980, minHeight: 680)
```

- [ ] **Step 3: Route, feed the store, and badge the sidebar**

In `Sources/SquishApp/RootView.swift`, `DashboardShell`:

```swift
struct DashboardShell: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var worktreeStore: WorktreeStore

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 224)

            Divider().overlay(.white.opacity(0.05))

            Group {
                switch appState.selectedSection {
                case .costs:
                    CostDashboardView()
                case .compactAlerts:
                    CompactAlertsView()
                case .liveChats:
                    LiveChatsSettingsView()
                case .worktrees:
                    WorktreesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            worktreeStore.update(root: appState.projectRoot, sessions: appState.sessions)
        }
        .onReceive(appState.$projectRoot) { root in
            worktreeStore.update(root: root, sessions: appState.sessions)
        }
        .onReceive(appState.$sessions) { sessions in
            worktreeStore.update(root: appState.projectRoot, sessions: sessions)
        }
    }
}
```

In `Sidebar`, add `@EnvironmentObject private var worktreeStore: WorktreeStore` below `appState`. Inside the section button's `HStack`, replace everything from the `Spacer()` after `Text(section.title)` through the closing brace of the `if (section == .compactAlerts && appState.alertsEnabled) || (section == .liveChats && appState.liveChatsEnabled) { Circle()… }` block with:

```swift
                        Spacer()
                        if section == .worktrees, worktreeStore.flaggedCount > 0 {
                            Text("\(worktreeStore.flaggedCount)")
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .padding(.horizontal, 6)
                                .frame(height: 17)
                                .background(AppColors.amber.opacity(0.28), in: Capsule())
                                .foregroundStyle(AppColors.amber)
                        } else if (section == .compactAlerts && appState.alertsEnabled)
                            || (section == .liveChats && appState.liveChatsEnabled) {
                            Circle()
                                .fill(AppColors.mint)
                                .frame(width: 6, height: 6)
                        }
```


- [ ] **Step 4: Write the section view**

`Sources/SquishApp/WorktreesView.swift`:

```swift
import AppKit
import SquishCore
import SwiftUI

struct WorktreesView: View {
    @EnvironmentObject private var store: WorktreeStore
    @State private var flaggedOnly = false
    @State private var confirmation: Confirmation?
    @State private var skippedAfterBulk: [Worktree] = []

    private enum Confirmation: Identifiable {
        case remove(Worktree)
        case losingWork(Worktree, uncommitted: Int, unpushed: Int, detached: Bool)
        case removeAnyway(Worktree)
        case bulk(remove: [Worktree], skipped: [Worktree])

        var id: String {
            switch self {
            case .remove(let w): "remove-\(w.path)"
            case .losingWork(let w, _, _, _): "losing-\(w.path)"
            case .removeAnyway(let w): "anyway-\(w.path)"
            case .bulk: "bulk"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    PageHeader(
                        eyebrow: "Disk hygiene",
                        title: "Worktrees",
                        subtitle: "Linked git worktrees of the repos in your folder, largest first."
                    )
                    Spacer()
                    Button {
                        store.refresh()
                    } label: {
                        Label(store.isRefreshing ? "Scanning…" : "Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isRefreshing)
                }

                summary

                if store.gitUnavailable {
                    notice(
                        "git is not available",
                        "Squish uses git to find and remove worktrees. Install the command line tools with xcode-select --install, then refresh."
                    )
                } else if store.scans.allSatisfy({ $0.worktrees.isEmpty && $0.error == nil }) && !store.isRefreshing {
                    notice("No linked worktrees", "None of the repos in your folder has a linked worktree.")
                } else {
                    ForEach(store.scans) { scan in
                        repoCard(scan)
                    }
                }

                if !skippedAfterBulk.isEmpty {
                    notice(
                        "Skipped \(skippedAfterBulk.count) with work in them",
                        skippedAfterBulk.map(\.displayName).joined(separator: ", ") + ". Remove these one at a time."
                    )
                }
            }
            .padding(28)
        }
        .onAppear { store.refresh() }
        .alert(
            Text(confirmation.map(title(for:)) ?? ""),
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            presenting: confirmation
        ) { confirmation in
            buttons(for: confirmation)
        } message: { confirmation in
            Text(message(for: confirmation))
        }
    }

    // MARK: - Header

    private var summary: some View {
        HStack(alignment: .center, spacing: 18) {
            stat("On disk", Self.bytes(store.totalBytes))
            stat("Flagged", "\(store.flaggedCount) · \(Self.bytes(store.flaggedBytes))")
            Divider().frame(height: 34)
            Stepper(value: ageBinding, in: 1...365) {
                Text("Older than \(store.thresholds.maxAgeDays) days")
                    .font(.system(size: 12, weight: .medium))
            }
            Stepper(value: sizeBinding, in: 1...200) {
                Text("Larger than \(store.thresholds.maxSizeBytes / 1_000_000_000) GB")
                    .font(.system(size: 12, weight: .medium))
            }
            Spacer()
            Toggle("Flagged only", isOn: $flaggedOnly)
                .toggleStyle(.switch)
                .tint(AppColors.mint)
                .font(.system(size: 12, weight: .medium))
            Button("Remove flagged") {
                let preview = store.bulkPreview()
                confirmation = .bulk(remove: preview.remove, skipped: preview.skipped)
            }
            .disabled(store.flaggedCount == 0)
        }
        .padding(18)
        .appCard()
        .overlay(alignment: .bottomTrailing) {
            if let reclaimed = store.lastReclaimed {
                Text("Freed \(Self.bytes(reclaimed))")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(AppColors.mint.opacity(0.22), in: Capsule())
                    .padding(10)
            }
        }
    }

    private var ageBinding: Binding<Int> {
        Binding(
            get: { store.thresholds.maxAgeDays },
            set: { store.thresholds.maxAgeDays = $0 }
        )
    }

    private var sizeBinding: Binding<Int> {
        Binding(
            get: { Int(store.thresholds.maxSizeBytes / 1_000_000_000) },
            set: { store.thresholds.maxSizeBytes = Int64($0) * 1_000_000_000 }
        )
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .bold).monospacedDigit())
        }
    }

    // MARK: - Rows

    private func repoCard(_ scan: RepoScan) -> some View {
        let rows = sortedRows(scan)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(URL(fileURLWithPath: scan.repoPath).lastPathComponent)
                    .font(.system(size: 14, weight: .bold))
                Text(scan.repoPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.bottom, 10)

            if let error = scan.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.coral)
            } else if rows.isEmpty {
                Text(flaggedOnly ? "Nothing flagged." : "No linked worktrees.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            ForEach(rows) { worktree in
                row(worktree)
                if worktree.id != rows.last?.id {
                    Divider().overlay(.white.opacity(0.04))
                }
            }
        }
        .padding(18)
        .appCard()
    }

    private func sortedRows(_ scan: RepoScan) -> [Worktree] {
        let sized = store.worktrees.filter { $0.repoPath == scan.repoPath }
        let visible = flaggedOnly ? sized.filter { !store.flags(for: $0).isEmpty } : sized
        return visible.sorted { ($0.sizeBytes ?? -1) > ($1.sizeBytes ?? -1) }
    }

    private func row(_ worktree: Worktree) -> some View {
        let flags = store.flags(for: worktree)
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(worktree.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    if let agent = worktree.agent {
                        chip(agent.rawValue, AppColors.violet)
                    }
                    if worktree.uncommittedCount > 0 { chip("Uncommitted changes", AppColors.amber) }
                    if worktree.unpushedCount > 0 { chip("Unpushed commits", AppColors.amber) }
                    if WorktreePolicy.hasActiveSession(worktree, activeSessionPaths: store.activeSessionPaths) {
                        chip("Session active", AppColors.mint)
                    }
                    if worktree.isLocked { chip("Locked", .secondary) }
                    if worktree.isPrunable { chip("Missing", AppColors.coral) }
                }
                Text(worktree.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let error = store.rowErrors[worktree.path] {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.coral)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(sizeText(worktree))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(flags.contains { if case .size = $0 { true } else { false } } ? AppColors.amber : .primary)
                Text(activityText(worktree))
                    .font(.system(size: 11))
                    .foregroundStyle(flags.contains { if case .age = $0 { true } else { false } } ? AppColors.amber : .secondary)
            }
            .frame(width: 110, alignment: .trailing)
            actions(worktree)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(flags.isEmpty ? .clear : AppColors.amber.opacity(0.07))
        )
    }

    private func actions(_ worktree: Worktree) -> some View {
        HStack(spacing: 6) {
            if !worktree.isPrunable {
                iconButton("folder", help: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.path)])
                }
                iconButton("terminal", help: "Open in Terminal") {
                    openInTerminal(worktree.path)
                }
            }
            removeButton(worktree)
        }
    }

    @ViewBuilder
    private func removeButton(_ worktree: Worktree) -> some View {
        switch store.removal(for: worktree) {
        case .confirm:
            Button("Remove") { confirmation = .remove(worktree) }
        case let .confirmLosingWork(uncommitted, unpushed, detached):
            Button("Remove") {
                confirmation = .losingWork(worktree, uncommitted: uncommitted, unpushed: unpushed, detached: detached)
            }
        case .blocked(let reason):
            Button("Remove") {}
                .disabled(true)
                .help(reason)
        case .pruneOnly:
            Button("Prune") { Task { await store.prune(worktree) } }
                .help("The directory is gone; remove git's record of it.")
        }
    }

    // MARK: - Confirmations

    private func title(for confirmation: Confirmation) -> String {
        switch confirmation {
        case .remove(let worktree):
            "Remove \(worktree.displayName)\(sizeSuffix(worktree))?"
        case .losingWork(let worktree, _, _, _):
            "\(worktree.displayName) has work that exists nowhere else"
        case .removeAnyway(let worktree):
            "Remove \(worktree.displayName) anyway?"
        case let .bulk(remove, _):
            "Remove \(remove.count) flagged worktrees (\(Self.bytes(remove.compactMap(\.sizeBytes).reduce(0, +))))?"
        }
    }

    private func message(for confirmation: Confirmation) -> String {
        switch confirmation {
        case .remove(let worktree):
            branchKeptText(worktree)
        case let .losingWork(worktree, uncommitted, unpushed, detached):
            lossText(worktree, uncommitted: uncommitted, unpushed: unpushed, detached: detached)
        case .removeAnyway:
            "This cannot be undone."
        case let .bulk(remove, skipped):
            remove.map(\.displayName).joined(separator: ", ") + ". Their branches are kept."
                + (skipped.isEmpty ? "" : " \(skipped.count) with work in them will be skipped.")
        }
    }

    @ViewBuilder
    private func buttons(for confirmation: Confirmation) -> some View {
        switch confirmation {
        case .remove(let worktree):
            Button("Remove", role: .destructive) { Task { await store.remove(worktree, force: false) } }
        case .losingWork(let worktree, _, _, _):
            Button("Continue…", role: .destructive) {
                // A second, separate confirmation, presented after this alert has closed.
                DispatchQueue.main.async { self.confirmation = .removeAnyway(worktree) }
            }
        case .removeAnyway(let worktree):
            Button("Remove anyway", role: .destructive) { Task { await store.remove(worktree, force: true) } }
        case .bulk:
            Button("Remove", role: .destructive) { Task { skippedAfterBulk = await store.removeFlagged() } }
        }
        Button("Cancel", role: .cancel) {}
    }

    private func branchKeptText(_ worktree: Worktree) -> String {
        if let branch = worktree.branch { return "The branch \(branch) is kept." }
        return "It is on a detached HEAD; nothing is lost because it has no unique commits."
    }

    private func lossText(_ worktree: Worktree, uncommitted: Int, unpushed: Int, detached: Bool) -> String {
        var lines: [String] = []
        if uncommitted > 0 {
            lines.append("\(uncommitted) uncommitted \(uncommitted == 1 ? "file" : "files") will be deleted.")
        }
        if unpushed > 0 {
            let commits = "\(unpushed) \(unpushed == 1 ? "commit is" : "commits are") on no remote or other branch"
            if detached {
                lines.append("\(commits) and will only be reachable through git's reflog.")
            } else {
                lines.append("\(commits); \(unpushed == 1 ? "it stays" : "they stay") on branch \(worktree.branch ?? "").")
            }
        }
        return lines.joined(separator: " ")
    }

    // MARK: - Helpers

    private func sizeSuffix(_ worktree: Worktree) -> String {
        worktree.sizeBytes.map { " (\(Self.bytes($0)))" } ?? ""
    }

    private func sizeText(_ worktree: Worktree) -> String {
        if worktree.isPrunable { return "—" }
        if let bytes = worktree.sizeBytes { return Self.bytes(bytes) }
        return store.unmeasurable.contains(worktree.path) ? "—" : "Measuring…"
    }

    private func activityText(_ worktree: Worktree) -> String {
        guard let last = worktree.lastActivity else { return "No activity" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: last, relativeTo: Date())
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private func notice(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 14, weight: .bold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .appCard()
    }

    private func openInTerminal(_ path: String) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
```

- [ ] **Step 5: Mention it in the README**

In `README.md`, under "## What it does", add after the "Puts live chats in the notch." bullet:

```markdown
- **Cleans up worktrees.** Lists every linked git worktree of the repos in your folder with its age and size, flags the ones older than 14 days or larger than 1 GB (both adjustable), and removes them with `git worktree remove`, keeping the branch. Worktrees with uncommitted or unpushed work need a second confirmation that says what would be lost.
```

- [ ] **Step 6: Build warning-free and run the full test suite**

Run: `swift build 2>&1 | grep -E "warning:|error:" | grep "Sources/Squish"; swift test 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: no warning or error lines; `Executed 101 tests, with 0 failures`.

- [ ] **Step 7: Check it in the running app**

Run: `./scripts/build-app.sh && open dist/Squish.app`
With the watched folder set to `~/Projects`:
1. The sidebar shows **Worktrees**; selecting it lists widget-ai's three Claude Code worktrees (and any others), each with "Measuring…" turning into a size.
2. Compare one size against `du -sh <path>`; they should agree within a few percent.
3. Lower the size threshold to 1 GB and the age to 1 day: rows past them highlight, the sidebar badge shows the count, and the setting survives a relaunch.
4. Create a scratch worktree with an untracked file (`git -C ~/Projects/squish worktree add /tmp/squish-wt-test -b wt-test && touch /tmp/squish-wt-test/x`; it appears only if `/tmp/squish-wt-test` belongs to a repo in the folder, which it does since squish is in `~/Projects`). Refresh, press Remove: the first alert says "1 uncommitted file will be deleted"; Continue… shows "Remove anyway?"; confirming removes it and `git -C ~/Projects/squish branch --list wt-test` still lists the branch. Clean up with `git -C ~/Projects/squish branch -D wt-test`.

- [ ] **Step 8: Commit**

```bash
git add Sources/SquishApp/WorktreesView.swift Sources/SquishApp/AppState.swift Sources/SquishApp/RootView.swift Sources/SquishApp/SquishApp.swift README.md
git commit -m "feat(app): a Worktrees section to find and remove stale or oversized worktrees

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
