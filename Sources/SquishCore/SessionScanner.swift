import Foundation

struct SessionScannerMetrics: Equatable, Sendable {
    var discoveryRuns = 0
    var membershipChecks = 0
    var fullParses = 0
    var incrementalParses = 0
    var changedFilesInspected = 0
    var summaryCacheHits = 0
    var summaryCacheWrites = 0
}

public struct SessionScanBatch: Sendable {
    public let sessions: [CodingSession]
    public let hasMoreHistory: Bool

    public init(sessions: [CodingSession], hasMoreHistory: Bool) {
        self.sessions = sessions
        self.hasMoreHistory = hasMoreHistory
    }
}

public final class SessionScanner: @unchecked Sendable {
    private struct Candidate: Hashable {
        let url: URL
        let provider: AgentProvider
        let modifiedAt: Date

        init(url: URL, provider: AgentProvider) {
            self.url = url
            self.provider = provider
            self.modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }

        static func == (lhs: Candidate, rhs: Candidate) -> Bool {
            lhs.provider == rhs.provider && lhs.url.path == rhs.url.path
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(provider)
            hasher.combine(url.path)
        }
    }

    private struct CacheEntry {
        var modifiedAt: Date
        var size: Int
        var parsedBytes: Int
        var pendingData: Data
        var session: CodingSession
    }

    private let fileManager: FileManager
    private let lock = NSLock()
    private let parsers: [AgentProvider: any SessionLogParser]
    private let summaryStore: SessionSummaryStore

    private var membership: [String: Bool] = [:]
    private var matchingCandidates: [String: Candidate] = [:]
    private var cache: [String: CacheEntry] = [:]
    private var sessionsByPath: [String: CodingSession] = [:]
    private var completedInitialDiscovery = false
    private var currentRootPath = ""
    private var metrics = SessionScannerMetrics()

    public convenience init() {
        let fileManager = FileManager.default
        self.init(
            fileManager: fileManager,
            summaryCacheDirectory: SessionSummaryStore.defaultDirectory(fileManager: fileManager)
        )
    }

    public convenience init(fileManager: FileManager) {
        self.init(
            fileManager: fileManager,
            summaryCacheDirectory: SessionSummaryStore.defaultDirectory(fileManager: fileManager)
        )
    }

    public init(fileManager: FileManager, summaryCacheDirectory: URL?) {
        self.fileManager = fileManager
        self.summaryStore = SessionSummaryStore(directory: summaryCacheDirectory, fileManager: fileManager)
        self.parsers = [
            .codex: CodexSessionParser(),
            .claude: ClaudeSessionParser(),
            .gemini: GeminiSessionParser()
        ]
    }

    public func scan(projectRoot: URL) async -> [CodingSession] {
        await Task.detached(priority: .utility) { [self] in
            withLock { initialScanSynchronously(projectRoot: projectRoot) }
        }.value
    }

    public func scanInitialBatch(
        projectRoot: URL,
        maxFullParses: Int = 8,
        maxCandidates: Int = 250
    ) async -> SessionScanBatch {
        await Task.detached(priority: .userInitiated) { [self] in
            withLock {
                loadHistoryBatchSynchronously(
                    projectRoot: projectRoot,
                    maxFullParses: maxFullParses,
                    maxCandidates: maxCandidates,
                    ensureDiscovery: true
                )
            }
        }.value
    }

    public func loadNextHistoryBatch(
        projectRoot: URL,
        maxFullParses: Int = 8,
        maxCandidates: Int = 250
    ) async -> SessionScanBatch {
        await Task.detached(priority: .background) { [self] in
            withLock {
                loadHistoryBatchSynchronously(
                    projectRoot: projectRoot,
                    maxFullParses: maxFullParses,
                    maxCandidates: maxCandidates,
                    ensureDiscovery: false
                )
            }
        }.value
    }

    public func refresh(projectRoot: URL, changedPaths: [URL]) async -> [CodingSession] {
        await Task.detached(priority: .userInitiated) { [self] in
            withLock { refreshSynchronously(projectRoot: projectRoot, changedPaths: changedPaths) }
        }.value
    }

    public func discoverNewSessions(projectRoot: URL) async -> [CodingSession] {
        await Task.detached(priority: .background) { [self] in
            withLock { discoverNewSessionsSynchronously(projectRoot: projectRoot) }
        }.value
    }

    public func refreshKnownSessions(projectRoot: URL) async -> [CodingSession] {
        await Task.detached(priority: .utility) { [self] in
            withLock {
                let root = prepare(projectRoot)
                refreshCandidates(Array(matchingCandidates.values), projectRoot: root)
                return sortedSessions()
            }
        }.value
    }

    public func reset() {
        withLock { resetState() }
    }

    public static func monitoringRoots(
        projectRoot: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        let possibleRoots = [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".gemini/tmp", isDirectory: true),
            projectRoot.appendingPathComponent(".codex", isDirectory: true),
            projectRoot.appendingPathComponent(".claude", isDirectory: true),
            projectRoot.appendingPathComponent(".gemini", isDirectory: true)
        ]

        var seen = Set<String>()
        return possibleRoots.compactMap { url in
            let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
            guard fileManager.fileExists(atPath: normalized.path), seen.insert(normalized.path).inserted else {
                return nil
            }
            return normalized
        }
    }

    func metricsSnapshot() -> SessionScannerMetrics {
        withLock { metrics }
    }

    private func initialScanSynchronously(projectRoot: URL) -> [CodingSession] {
        let root = prepare(projectRoot)
        if !completedInitialDiscovery {
            integrate(discoverCandidates(projectRoot: root), projectRoot: root, pruningMissing: true)
            completedInitialDiscovery = true
        }
        refreshCandidates(Array(matchingCandidates.values), projectRoot: root)
        return sortedSessions()
    }

    private func loadHistoryBatchSynchronously(
        projectRoot: URL,
        maxFullParses: Int,
        maxCandidates: Int,
        ensureDiscovery: Bool
    ) -> SessionScanBatch {
        let root = prepare(projectRoot)
        if ensureDiscovery || !completedInitialDiscovery {
            integrate(discoverCandidates(projectRoot: root), projectRoot: root, pruningMissing: true)
            completedInitialDiscovery = true
        }

        let pending = matchingCandidates.values
            .filter { cache[key(for: $0.url)] == nil }
            .sorted { $0.modifiedAt > $1.modifiedAt }
        let fullParsesAtStart = metrics.fullParses
        var candidateCount = 0

        for candidate in pending {
            refreshCandidate(candidate, projectRoot: root)
            candidateCount += 1
            if candidateCount >= max(1, maxCandidates)
                || metrics.fullParses - fullParsesAtStart >= max(1, maxFullParses) {
                break
            }
        }

        let hasMore = matchingCandidates.values.contains { cache[key(for: $0.url)] == nil }
        return SessionScanBatch(sessions: sortedSessions(), hasMoreHistory: hasMore)
    }

    private func refreshSynchronously(projectRoot: URL, changedPaths: [URL]) -> [CodingSession] {
        let root = prepare(projectRoot)
        if !completedInitialDiscovery {
            return initialScanSynchronously(projectRoot: root)
        }

        var candidatesToRefresh = Set<Candidate>()
        var directoriesToDiscover: [(URL, AgentProvider)] = []

        for changedURL in changedPaths {
            let url = changedURL.standardizedFileURL.resolvingSymlinksInPath()
            let path = url.path

            if let candidate = matchingCandidates[path] {
                candidatesToRefresh.insert(candidate)
                continue
            }

            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            if exists, isDirectory.boolValue, let provider = provider(for: url) {
                directoriesToDiscover.append((url, provider))
                continue
            }

            if let provider = provider(for: url), supportedExtensions(for: provider).contains(url.pathExtension.lowercased()) {
                let candidate = Candidate(url: url, provider: provider)
                integrateSingle(candidate, projectRoot: root)
                if membership[path] == true { candidatesToRefresh.insert(candidate) }
            }
        }

        for (directory, provider) in directoriesToDiscover {
            var found = Set<Candidate>()
            addFiles(
                under: directory,
                provider: provider,
                extensions: supportedExtensions(for: provider),
                excluding: provider == .claude ? ["/subagents/"] : [],
                to: &found
            )
            integrate(found, projectRoot: root, pruningMissing: false)
            candidatesToRefresh.formUnion(found.filter { membership[key(for: $0.url)] == true })
        }

        refreshCandidates(Array(candidatesToRefresh), projectRoot: root)
        return sortedSessions()
    }

    private func discoverNewSessionsSynchronously(projectRoot: URL) -> [CodingSession] {
        let root = prepare(projectRoot)
        integrate(discoverCandidates(projectRoot: root), projectRoot: root, pruningMissing: true)
        completedInitialDiscovery = true
        refreshCandidates(Array(matchingCandidates.values), projectRoot: root)
        return sortedSessions()
    }

    private func prepare(_ projectRoot: URL) -> URL {
        let normalized = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        if currentRootPath != normalized.path {
            resetState()
            currentRootPath = normalized.path
        }
        return normalized
    }

    private func resetState() {
        membership.removeAll(keepingCapacity: false)
        matchingCandidates.removeAll(keepingCapacity: false)
        cache.removeAll(keepingCapacity: false)
        sessionsByPath.removeAll(keepingCapacity: false)
        completedInitialDiscovery = false
        currentRootPath = ""
        metrics = SessionScannerMetrics()
    }

    private func integrate(
        _ discovered: Set<Candidate>,
        projectRoot: URL,
        pruningMissing: Bool
    ) {
        metrics.discoveryRuns += 1
        let livePaths = Set(discovered.map { key(for: $0.url) })

        for candidate in discovered {
            integrateSingle(candidate, projectRoot: projectRoot)
        }

        if pruningMissing {
            for path in matchingCandidates.keys where !livePaths.contains(path) {
                removeCandidate(at: path)
            }
            membership = membership.filter { livePaths.contains($0.key) }
        }
    }

    private func integrateSingle(_ candidate: Candidate, projectRoot: URL) {
        let path = key(for: candidate.url)
        if let belongs = membership[path] {
            if belongs { matchingCandidates[path] = candidate }
            return
        }

        metrics.membershipChecks += 1
        let belongs = couldBelong(candidate, projectRoot: projectRoot)
        membership[path] = belongs
        if belongs { matchingCandidates[path] = candidate }
    }

    private func refreshCandidates(_ candidates: [Candidate], projectRoot: URL) {
        for candidate in candidates {
            refreshCandidate(candidate, projectRoot: projectRoot)
        }
    }

    private func refreshCandidate(_ candidate: Candidate, projectRoot: URL) {
        let path = key(for: candidate.url)
        guard let attributes = try? fileManager.attributesOfItem(atPath: candidate.url.path),
              let modifiedAt = attributes[.modificationDate] as? Date else {
            removeCandidate(at: path)
            return
        }

        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if let entry = cache[path], entry.modifiedAt == modifiedAt, entry.size == size { return }
        metrics.changedFilesInspected += 1

        if cache[path] == nil,
           let cachedSession = summaryStore.session(
                for: path,
                fileSize: size,
                modifiedAt: modifiedAt
           ) {
            metrics.summaryCacheHits += 1
            let entry = CacheEntry(
                modifiedAt: modifiedAt,
                size: size,
                parsedBytes: size,
                pendingData: Data(),
                session: cachedSession
            )
            cache[path] = entry
            sessionsByPath[path] = cachedSession
            return
        }

        if var entry = cache[path],
           size >= entry.parsedBytes,
           size > entry.parsedBytes,
           candidate.provider != .gemini,
           let appended = readData(from: candidate.url, offset: entry.parsedBytes) {
            let combined = entry.pendingData + appended
            let split = splitCompleteJSONLines(combined)
            entry.modifiedAt = modifiedAt
            entry.size = size
            entry.parsedBytes = size
            entry.pendingData = split.pending

            let previousSession = entry.session
            if !split.complete.isEmpty {
                switch candidate.provider {
                case .codex:
                    entry.session = CodexSessionParser().refreshing(
                        entry.session,
                        withJSONLines: split.complete,
                        fileURL: candidate.url
                    )
                case .claude:
                    entry.session = ClaudeSessionParser().refreshing(
                        entry.session,
                        withJSONLines: split.complete,
                        fileURL: candidate.url
                    )
                case .gemini:
                    break
                }
                metrics.incrementalParses += 1
            }

            cache[path] = entry
            sessionsByPath[path] = entry.session
            if entry.session != previousSession {
                saveSummary(entry.session, sourcePath: path, fileSize: size, modifiedAt: modifiedAt)
            }
            return
        }

        metrics.fullParses += 1
        let parsed = try? parsers[candidate.provider]?.parse(url: candidate.url, projectRoot: projectRoot)
        guard let session = parsed ?? nil else {
            removeCandidate(at: path)
            return
        }

        let entry = CacheEntry(
            modifiedAt: modifiedAt,
            size: size,
            parsedBytes: size,
            pendingData: Data(),
            session: session
        )
        cache[path] = entry
        sessionsByPath[path] = session
        saveSummary(session, sourcePath: path, fileSize: size, modifiedAt: modifiedAt)
    }

    private func removeCandidate(at path: String) {
        matchingCandidates.removeValue(forKey: path)
        cache.removeValue(forKey: path)
        sessionsByPath.removeValue(forKey: path)
        summaryStore.remove(sourcePath: path)
    }

    private func sortedSessions() -> [CodingSession] {
        sessionsByPath.values.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func discoverCandidates(projectRoot: URL) -> Set<Candidate> {
        let home = fileManager.homeDirectoryForCurrentUser
        var result = Set<Candidate>()

        addFiles(
            under: home.appendingPathComponent(".codex/sessions"),
            provider: .codex,
            extensions: supportedExtensions(for: .codex),
            to: &result
        )
        addFiles(
            under: home.appendingPathComponent(".claude/projects"),
            provider: .claude,
            extensions: supportedExtensions(for: .claude),
            excluding: ["/subagents/"],
            to: &result
        )
        addFiles(
            under: home.appendingPathComponent(".gemini/tmp"),
            provider: .gemini,
            extensions: supportedExtensions(for: .gemini),
            to: &result
        )

        for (directory, provider) in [
            (projectRoot.appendingPathComponent(".codex"), AgentProvider.codex),
            (projectRoot.appendingPathComponent(".claude"), AgentProvider.claude),
            (projectRoot.appendingPathComponent(".gemini"), AgentProvider.gemini)
        ] {
            addFiles(
                under: directory,
                provider: provider,
                extensions: supportedExtensions(for: provider),
                excluding: provider == .claude ? ["/subagents/"] : [],
                to: &result
            )
        }

        return result
    }

    private func addFiles(
        under root: URL,
        provider: AgentProvider,
        extensions: Set<String>,
        excluding fragments: [String] = [],
        to result: inout Set<Candidate>
    ) {
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { return }

        for case let url as URL in enumerator {
            guard extensions.contains(url.pathExtension.lowercased()),
                  !fragments.contains(where: url.path.contains) else { continue }
            result.insert(Candidate(url: url, provider: provider))
        }
    }

    private func provider(for url: URL) -> AgentProvider? {
        let path = url.path
        if path.contains("/.codex/") { return .codex }
        if path.contains("/.claude/") { return .claude }
        if path.contains("/.gemini/") { return .gemini }
        return nil
    }

    private func supportedExtensions(for provider: AgentProvider) -> Set<String> {
        switch provider {
        case .codex, .claude: ["jsonl"]
        case .gemini: ["json", "jsonl"]
        }
    }

    private func couldBelong(_ candidate: Candidate, projectRoot: URL) -> Bool {
        let candidatePath = candidate.url.standardizedFileURL.resolvingSymlinksInPath().path
        if candidatePath.hasPrefix(projectRoot.path + "/") { return true }

        switch candidate.provider {
        case .claude:
            let encodedRoot = projectRoot.path.replacingOccurrences(of: "/", with: "-")
            return candidate.url.path.contains(encodedRoot)

        case .codex:
            guard let handle = try? FileHandle(forReadingFrom: candidate.url) else { return false }
            defer { try? handle.close() }
            let data = try? handle.read(upToCount: 64 * 1024)
            guard let data, let prefix = String(data: data, encoding: .utf8) else { return false }
            if let firstLine = prefix.split(whereSeparator: \.isNewline).first,
               let lineData = String(firstLine).data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let payload = object["payload"] as? [String: Any],
               let cwd = payload["cwd"] as? String {
                return path(cwd, isInside: projectRoot.path)
            }
            return prefix.contains(projectRoot.path)

        case .gemini:
            return true
        }
    }

    private func path(_ candidate: String, isInside root: String) -> Bool {
        let candidate = URL(fileURLWithPath: candidate).standardizedFileURL.resolvingSymlinksInPath().path
        let root = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    private func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func saveSummary(
        _ session: CodingSession,
        sourcePath: String,
        fileSize: Int,
        modifiedAt: Date
    ) {
        summaryStore.save(
            session,
            sourcePath: sourcePath,
            fileSize: fileSize,
            modifiedAt: modifiedAt
        )
        metrics.summaryCacheWrites += 1
    }

    private func readData(from url: URL, offset: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.readToEnd() ?? Data()
        } catch {
            return nil
        }
    }

    private func splitCompleteJSONLines(_ data: Data) -> (complete: Data, pending: Data) {
        guard let newline = data.lastIndex(of: 0x0A) else { return (Data(), data) }
        let next = data.index(after: newline)
        return (Data(data[..<next]), Data(data[next...]))
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
