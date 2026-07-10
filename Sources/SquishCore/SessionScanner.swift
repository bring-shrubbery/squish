import Foundation

public final class SessionScanner: @unchecked Sendable {
    private struct Candidate: Hashable {
        let url: URL
        let provider: AgentProvider
    }

    private struct CacheEntry {
        let modifiedAt: Date
        let size: Int
        let session: CodingSession?
    }

    private let fileManager: FileManager
    private let lock = NSLock()
    private let parsers: [AgentProvider: any SessionLogParser]
    private var cache: [String: CacheEntry] = [:]
    private var candidates: Set<Candidate> = []
    private var lastDiscovery = Date.distantPast
    private var currentRootPath = ""

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.parsers = [
            .codex: CodexSessionParser(),
            .claude: ClaudeSessionParser(),
            .gemini: GeminiSessionParser()
        ]
    }

    public func scan(projectRoot: URL) async -> [CodingSession] {
        await Task.detached(priority: .utility) { [self] in
            lockedScan(projectRoot: projectRoot)
        }.value
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        candidates.removeAll()
        lastDiscovery = .distantPast
        currentRootPath = ""
    }

    private func lockedScan(projectRoot: URL) -> [CodingSession] {
        lock.lock()
        defer { lock.unlock() }
        return scanSynchronously(projectRoot: projectRoot)
    }

    private func scanSynchronously(projectRoot: URL) -> [CodingSession] {
        let normalizedRoot = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        if currentRootPath != normalizedRoot.path {
            cache.removeAll()
            candidates.removeAll()
            lastDiscovery = .distantPast
            currentRootPath = normalizedRoot.path
        }

        if candidates.isEmpty || Date().timeIntervalSince(lastDiscovery) > 4 {
            candidates = discoverCandidates(projectRoot: normalizedRoot)
            lastDiscovery = Date()
        }

        var sessions: [CodingSession] = []
        var livePaths = Set<String>()
        for candidate in candidates {
            let path = candidate.url.path
            livePaths.insert(path)
            guard couldBelong(candidate, projectRoot: normalizedRoot) else { continue }
            guard let values = try? candidate.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modifiedAt = values.contentModificationDate else { continue }
            let size = values.fileSize ?? 0

            if let cached = cache[path], cached.modifiedAt == modifiedAt, cached.size == size {
                if let session = cached.session { sessions.append(session) }
                continue
            }

            let session = try? parsers[candidate.provider]?.parse(url: candidate.url, projectRoot: normalizedRoot)
            let resolved = session ?? nil
            cache[path] = CacheEntry(modifiedAt: modifiedAt, size: size, session: resolved)
            if let resolved { sessions.append(resolved) }
        }

        cache = cache.filter { livePaths.contains($0.key) }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func discoverCandidates(projectRoot: URL) -> Set<Candidate> {
        let home = fileManager.homeDirectoryForCurrentUser
        var result = Set<Candidate>()

        addFiles(
            under: home.appendingPathComponent(".codex/sessions"),
            provider: .codex,
            extensions: ["jsonl"],
            to: &result
        )
        addFiles(
            under: home.appendingPathComponent(".claude/projects"),
            provider: .claude,
            extensions: ["jsonl"],
            excluding: ["/subagents/"],
            to: &result
        )
        addFiles(
            under: home.appendingPathComponent(".gemini/tmp"),
            provider: .gemini,
            extensions: ["json", "jsonl"],
            to: &result
        )

        discoverLocalAgentFiles(under: projectRoot, into: &result)
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

    private func discoverLocalAgentFiles(under root: URL, into result: inout Set<Candidate>) {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else { return }

        let skippedDirectories: Set<String> = [".git", "node_modules", "DerivedData", ".build", "Pods"]
        for case let url as URL in enumerator {
            if skippedDirectories.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let components = Set(url.pathComponents)
            let provider: AgentProvider?
            if components.contains(".codex") { provider = .codex }
            else if components.contains(".claude") { provider = .claude }
            else if components.contains(".gemini") { provider = .gemini }
            else { provider = nil }

            guard let provider,
                  ["json", "jsonl"].contains(url.pathExtension.lowercased()) else { continue }
            result.insert(Candidate(url: url, provider: provider))
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
}
