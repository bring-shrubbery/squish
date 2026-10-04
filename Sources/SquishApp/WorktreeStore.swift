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
