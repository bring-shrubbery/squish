import Darwin
import Foundation

/// What compacting a session costs and how to ask for it.
public enum Compaction {
    /// The slash command that compacts the agent's context.
    public static func command(for provider: AgentProvider) -> String {
        switch provider {
        case .claude, .codex: "/compact"
        case .gemini: "/compress"
        }
    }

    /// Output tokens a compaction summary takes, give or take: a few thousand.
    public static let summaryOutputTokens = 4_000

    /// About what compacting now would cost: the whole context read once more (at the
    /// cache-read rate, since a live session's context is cached) plus the summary the
    /// model writes. Nil when the model has no price.
    public static func estimatedCost(for session: CodingSession, catalog: PricingCatalog = .current) -> Double? {
        guard let price = catalog.price(for: session.model, provider: session.provider) else { return nil }
        let usage = TokenUsage(cachedReadTokens: session.contextTokens, outputTokens: summaryOutputTokens)
        return price.cost(usage: usage, currentContextTokens: session.contextTokens).total
    }
}

/// A running agent process: which agent, where it works, and the terminal it is attached to.
public struct AgentProcess: Equatable, Sendable {
    public let pid: pid_t
    public let provider: AgentProvider
    public let workingDirectory: String
    /// `/dev/ttys003`, or nil when the process has no controlling terminal.
    public let tty: String?
    public let startedAt: Date

    public init(pid: pid_t, provider: AgentProvider, workingDirectory: String, tty: String?, startedAt: Date) {
        self.pid = pid
        self.provider = provider
        self.workingDirectory = workingDirectory
        self.tty = tty
        self.startedAt = startedAt
    }
}

/// What the kernel says about a process, for walking up from an agent to the app around it.
public enum ProcessTree {
    public struct Info: Equatable, Sendable {
        public let pid: pid_t
        public let parent: pid_t
        /// The executable's short name (`claude`, `zsh`, `Terminal`).
        public let name: String
        /// `/dev/ttys003`, or nil when the process has no controlling terminal.
        public let tty: String?
        public let startedAt: Date
    }

    public static func info(of pid: pid_t) -> Info? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: &info.pbi_comm) { buffer -> String in
            let bytes = buffer.bindMemory(to: UInt8.self)
            let length = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: UnsafeBufferPointer(rebasing: bytes[..<length]), as: UTF8.self)
        }
        // NODEV (all ones) means no controlling terminal.
        let tty: String? = info.e_tdev == UInt32.max
            ? nil
            : devname(dev_t(bitPattern: info.e_tdev), S_IFCHR).map { "/dev/" + String(cString: $0) }
        return Info(
            pid: pid,
            parent: pid_t(info.pbi_ppid),
            name: name,
            tty: tty,
            startedAt: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
        )
    }

    /// The process's ancestors, nearest first, stopping before launchd. At most `limit`.
    public static func ancestors(of pid: pid_t, limit: Int = 12) -> [pid_t] {
        var result: [pid_t] = []
        var current = pid
        while result.count < limit, let info = info(of: current), info.parent > 1 {
            result.append(info.parent)
            current = info.parent
        }
        return result
    }
}

/// Finds the process behind a session, so a command can be sent to its terminal. Sessions do
/// not record their process, so this matches on the agent, the working directory and, when
/// several qualify, the start time nearest the session's.
public enum AgentProcesses {
    /// Executable names each agent runs as. Gemini CLI is a Node script, so it shows as node.
    static func provider(forExecutable name: String) -> AgentProvider? {
        switch name {
        case "claude": .claude
        case "codex": .codex
        case "gemini", "node": .gemini
        default: nil
        }
    }

    /// The best match for the session among `processes`, or nil.
    public static func match(for session: CodingSession, in processes: [AgentProcess]) -> AgentProcess? {
        let projectPath = normalized(session.projectPath)
        let candidates = processes.filter {
            $0.provider == session.provider && normalized($0.workingDirectory) == projectPath && $0.tty != nil
        }
        return candidates.min {
            abs($0.startedAt.timeIntervalSince(session.startedAt)) < abs($1.startedAt.timeIntervalSince(session.startedAt))
        }
    }

    /// Every agent process the user can inspect.
    public static func running() -> [AgentProcess] {
        allPids().compactMap { pid -> AgentProcess? in
            guard pid > 0, pid != getpid() else { return nil }
            return process(pid: pid)
        }
    }

    /// The agent process with this pid, or nil when it is gone or is not an agent.
    public static func process(pid: pid_t) -> AgentProcess? {
        guard let info = ProcessTree.info(of: pid),
              let provider = provider(forExecutable: info.name),
              let cwd = workingDirectory(of: pid) else { return nil }
        return AgentProcess(
            pid: pid,
            provider: provider,
            workingDirectory: cwd,
            tty: info.tty,
            startedAt: info.startedAt
        )
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func allPids() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 256)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled)))
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { buffer -> String in
            let bytes = buffer.bindMemory(to: UInt8.self)
            let length = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: UnsafeBufferPointer(rebasing: bytes[..<length]), as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }
}
