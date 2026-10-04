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
    /// Creates branch `name` at commit `sha`; throws if the name is taken.
    func createBranch(name: String, at sha: String, repo: String) throws
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
        // Explicit --untracked-files so a status.showUntrackedFiles=no config cannot hide untracked work.
        GitPorcelain.statusEntryCount(try run(["status", "--porcelain", "--untracked-files=normal"], in: worktree))
    }

    public func unpushedCount(worktree: String, branch: String?) throws -> Int {
        var arguments = ["rev-list", "--count", "HEAD", "--not"]
        // --exclude patterns for --branches are relative to refs/heads/ (a "refs/heads/" prefix matches nothing).
        if let branch { arguments.append("--exclude=\(branch)") }
        arguments += ["--branches", "--remotes"]
        let output = try run(arguments, in: worktree).trimmingCharacters(in: .whitespacesAndNewlines)
        // Never read garbage as "nothing unpushed": that would let work be deleted unconfirmed.
        guard let count = Int(output) else {
            throw GitError.failed(message: "git rev-list printed an unexpected count: \(output)")
        }
        return count
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

    // Destructive commands run without a timeout: killing one midway could leave a
    // half-deleted worktree.
    public func remove(worktree: String, repo: String, force: Bool) throws {
        try run(["worktree", "remove"] + (force ? ["--force"] : []) + [worktree], in: repo, timeout: nil)
    }

    public func prune(repo: String) throws {
        try run(["worktree", "prune"], in: repo, timeout: nil)
    }

    public func createBranch(name: String, at sha: String, repo: String) throws {
        try run(["branch", name, sha], in: repo)
    }

    /// Variables that would point git at another repo, index or object store than the
    /// directory it runs in (set when Squish is launched from a git hook or a git-aware shell).
    static let repoOverrideVariables = [
        "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE"
    ]

    /// Runs git in `directory` with the client's read timeout and returns stdout.
    @discardableResult
    func run(_ arguments: [String], in directory: String) throws -> String {
        try run(arguments, in: directory, timeout: timeout)
    }

    /// Runs git in `directory` and returns stdout; `timeout: nil` waits for as long as git takes.
    /// stdout and stderr are drained concurrently so large output cannot fill a pipe and stall
    /// the child. On timeout git gets SIGTERM, then SIGKILL after 2 s, and the readers stop even
    /// if a grandchild still holds the pipes open.
    @discardableResult
    func run(_ arguments: [String], in directory: String, timeout: TimeInterval?) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GitError.failed(message: "No such directory: \(directory)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        for name in Self.repoOverrideVariables { environment[name] = nil }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            throw GitError.unavailable
        }

        let outBox = DataBox()
        let errBox = DataBox()
        let stop = StopFlag()
        let group = DispatchGroup()
        for (pipe, box) in [(stdout, outBox), (stderr, errBox)] {
            group.enter()
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            DispatchQueue.global(qos: .utility).async {
                box.data = Self.drain(descriptor, until: stop)
                group.leave()
            }
        }

        let deadline: DispatchTime = timeout.map { .now() + $0 } ?? .distantFuture
        let finished = group.wait(timeout: deadline) == .success && exited.wait(timeout: deadline) == .success
        if !finished {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
            stop.set()
            group.wait()
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            throw GitError.timedOut(command: arguments.first ?? "")
        }
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()

        let errorText = String(decoding: errBox.data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            // /usr/bin/git is a shim that fails this way when the command line tools are missing.
            if errorText.contains("xcrun: error") { throw GitError.unavailable }
            let message = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.failed(message: message.isEmpty ? "git \(arguments.first ?? "") failed" : message)
        }
        return String(decoding: outBox.data, as: UTF8.self)
    }

    /// Reads `descriptor` to end of file, polling so `stop` can end the read even while
    /// another process keeps the write end open.
    private static func drain(_ descriptor: Int32, until stop: StopFlag) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        while !stop.isSet {
            let ready = poll(&poller, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
            } else if count < 0, errno == EINTR || errno == EAGAIN {
                continue
            } else {
                break
            }
        }
        return data
    }
}

/// Set once by the timing-out caller, read by the reader loops.
private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// Written by exactly one reader closure, read after the DispatchGroup has finished.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}
