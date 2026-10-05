import Foundation
import SquishCore

/// State for the Worktrees section: scans the watched folder's repos, measures worktree sizes
/// in the background, and removes worktrees through git.
@MainActor
final class WorktreeStore: ObservableObject {
    @Published private(set) var scans: [RepoScan] = [] {
        didSet {
            let listed = Set(scans.flatMap(\.worktrees).map(\.path))
            let kept = selection.intersection(listed)
            if kept != selection { selection = kept }
        }
    }
    /// What the list shows; kept here so it survives leaving and reopening the section.
    @Published var filter = WorktreeFilter()
    /// Paths of the selected rows; the table binds to it. Any row can be selected, and the
    /// removal plan says what happens to each.
    @Published var selection: Set<String> = []
    @Published private(set) var sizes: [String: Int64] = [:]
    @Published private(set) var unmeasurable: Set<String> = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var gitUnavailable = false
    @Published private(set) var rowErrors: [String: String] = [:]
    @Published private(set) var lastReclaimed: Int64?
    /// True while any remove or prune runs; the view disables removal controls meanwhile.
    @Published private(set) var isRemoving = false
    /// Normalized cwds of live agent sessions and of running processes (shells, editors, agents
    /// keeping worktrees anywhere); published so rows re-render (and Remove re-gates) when one
    /// starts in a worktree. Removal re-probes both right before deleting anything.
    @Published private(set) var activeSessionPaths: [String] = []
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
    private var liveSessionPaths: [String] = []
    /// Process cwds from the last refresh.
    private var processPaths: [String] = []
    private var refreshTask: Task<Void, Never>?
    private var sizingTask: Task<Void, Never>?
    private var timer: Timer?
    /// Nesting depth of removal operations, so a bulk run's inner removes keep `isRemoving` set.
    private var removalDepth = 0 {
        didSet { isRemoving = removalDepth > 0 }
    }

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
        liveSessionPaths = WorktreePolicy.liveSessionPaths(sessions, now: Date())
        updateActivePaths()
        if rootChanged {
            sizingTask?.cancel()
            scans = []
            sizes = [:]
            refresh()
        }
    }

    private func updateActivePaths() {
        let paths = Array(Set(liveSessionPaths + processPaths)).sorted()
        if paths != activeSessionPaths { activeSessionPaths = paths }
    }

    /// Live sessions plus running processes, probed now. Call off the main actor.
    nonisolated private static func probeActivePaths(sessionPaths: [String]) -> [String] {
        // Squish's own git commands run inside worktrees; they are not activity.
        sessionPaths + ProcessWorkingDirectories.current(excludingChildrenOf: getpid())
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

    func isInUse(_ worktree: Worktree) -> Bool {
        WorktreePolicy.hasActiveSession(worktree, activeSessionPaths: activeSessionPaths)
    }

    var flaggedCount: Int { worktrees.filter { !flags(for: $0).isEmpty }.count }

    var totalBytes: Int64 { worktrees.compactMap(\.sizeBytes).reduce(0, +) }

    var flaggedBytes: Int64 {
        worktrees.filter { !flags(for: $0).isEmpty }.compactMap(\.sizeBytes).reduce(0, +)
    }

    // MARK: - Filtering

    /// The worktrees the filter lets through, in the chosen order.
    var visibleWorktrees: [Worktree] {
        let now = Date()
        let matching = worktrees.filter {
            filter.matches($0, flagged: !flags(for: $0).isEmpty, inUse: isInUse($0), now: now)
        }
        return WorktreeFilter.sorted(matching, by: filter.sort)
    }

    func worktree(at path: String) -> Worktree? {
        worktrees.first { $0.path == path }
    }

    // MARK: - Selection

    var selectedWorktrees: [Worktree] { worktrees.filter { selection.contains($0.path) } }

    var selectedBytes: Int64 { selectedWorktrees.compactMap(\.sizeBytes).reduce(0, +) }

    /// Replaces the selection with the flagged worktrees the list shows.
    func selectFlagged() {
        selection = Set(visibleWorktrees.filter { !flags(for: $0).isEmpty }.map(\.path))
    }

    /// What removing the given worktrees would do, from the last scan.
    func bulkPlan(for paths: Set<String>) -> WorktreeBulkPlan {
        let chosen = visibleWorktrees.filter { paths.contains($0.path) }
            + worktrees.filter { paths.contains($0.path) && !visibleWorktrees.contains($0) }
        return WorktreePolicy.bulkPlan(chosen, activeSessionPaths: activeSessionPaths)
    }

    func refresh() {
        guard let root, refreshTask == nil else { return }
        isRefreshing = true
        let scanner = self.scanner
        let sessionPaths = sessions.map(\.projectPath)
        let scannedRoot = root.standardizedFileURL
        refreshTask = Task {
            let (result, cwds) = await Task.detached(priority: .utility) { () -> (Result<[RepoScan], GitError>, [String]) in
                let result: Result<[RepoScan], GitError>
                do {
                    let repos = try scanner.repos(root: root, sessionPaths: sessionPaths)
                    result = .success(scanner.scanAll(repos: repos))
                } catch let error as GitError {
                    result = .failure(error)
                } catch {
                    result = .failure(.failed(message: error.localizedDescription))
                }
                return (result, ProcessWorkingDirectories.current(excludingChildrenOf: getpid()))
            }.value
            // The watched folder changed mid-scan: drop the old folder's result and scan the new one.
            guard self.root?.standardizedFileURL == scannedRoot else {
                isRefreshing = false
                refreshTask = nil
                refresh()
                return
            }
            processPaths = cwds
            updateActivePaths()
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

    /// The latest scanned state of a worktree, so safety checks never run on a stale copy.
    private func current(_ worktree: Worktree) -> Worktree? {
        scans.lazy.flatMap(\.worktrees).first { $0.path == worktree.path }
    }

    /// Removes one worktree; returns the bytes it freed, or nil when git refused or the
    /// worktree is no longer safe to remove this way. A forced removal passes the counts the
    /// user confirmed losing; it is refused if git now reports more.
    private func remove(
        _ worktree: Worktree,
        force: Bool,
        confirmedUncommitted: Int,
        confirmedUnpushed: Int,
        showsReclaimed: Bool
    ) async -> Int64? {
        guard let latest = current(worktree) else {
            rowErrors[worktree.path] = "This worktree is no longer listed. Refresh and try again."
            return nil
        }
        switch removal(for: latest) {
        case .confirm:
            break
        case .confirmLosingWork:
            guard force else {
                rowErrors[worktree.path] = "This worktree now has work in it. Remove it again to review what would be lost."
                return nil
            }
        case .blocked(let reason):
            rowErrors[worktree.path] = reason
            return nil
        case .pruneOnly:
            rowErrors[worktree.path] = "The directory is gone; use Prune instead."
            return nil
        }
        removalDepth += 1
        defer { removalDepth -= 1 }
        let git = scanner.git
        rowErrors[worktree.path] = nil
        let sessionPaths = WorktreePolicy.liveSessionPaths(sessions, now: Date())
        // The deciding check reads git and the process table now, not the last scan.
        let failure: String? = await Task.detached(priority: .userInitiated) {
            do {
                try WorktreeRemover.remove(
                    worktree,
                    git: git,
                    activePaths: Self.probeActivePaths(sessionPaths: sessionPaths),
                    force: force,
                    confirmedUncommitted: confirmedUncommitted,
                    confirmedUnpushed: confirmedUnpushed
                )
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
            if showsReclaimed { showReclaimed(freed ?? 0) }
        }
        await rescan(repo: worktree.repoPath)
        return freed
    }

    /// Returns whether git's record of the missing worktree was removed.
    @discardableResult
    private func pruneNow(_ worktree: Worktree) async -> Bool {
        guard let latest = current(worktree), removal(for: latest) == .pruneOnly else {
            rowErrors[worktree.path] = "The directory exists again; it can no longer be pruned."
            return false
        }
        removalDepth += 1
        defer { removalDepth -= 1 }
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
        return failure == nil
    }

    /// Carries out a plan the user confirmed: prunes the missing, removes the clean, and, only
    /// when `losingWork` was confirmed too, force-removes the ones with work in them, each
    /// losing at most the counts the user saw. Every step re-checks the worktree first; the
    /// ones that no longer qualify, or that git refused, are returned as skipped. Each removal is its own git run, so
    /// a failure on one worktree does not stop the rest.
    func removePlanned(_ plan: WorktreeBulkPlan, losingWork: Bool) async -> [Worktree] {
        guard !isRemoving else { return plan.acted }
        removalDepth += 1
        defer { removalDepth -= 1 }
        var skipped: [Worktree] = []
        var total: Int64 = 0
        for worktree in plan.prune where !(await pruneNow(worktree)) {
            skipped.append(worktree)
        }
        for worktree in plan.clean {
            guard let latest = current(worktree), removal(for: latest) == .confirm else {
                skipped.append(worktree)
                continue
            }
            if let freed = await remove(
                worktree, force: false, confirmedUncommitted: 0, confirmedUnpushed: 0, showsReclaimed: false
            ) {
                total += freed
            } else {
                skipped.append(worktree)
            }
        }
        // Without `losingWork` the user chose to leave these; they are not skipped.
        for loss in plan.losingWork where losingWork {
            if let freed = await remove(
                loss.worktree, force: true, confirmedUncommitted: loss.uncommitted,
                confirmedUnpushed: loss.unpushed, showsReclaimed: false
            ) {
                total += freed
            } else {
                skipped.append(loss.worktree)
            }
        }
        if total > 0 { showReclaimed(total) }
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
                if Task.isCancelled { return }
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
