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
        // Explicit --untracked-files so a status.showUntrackedFiles=no config cannot hide untracked work.
        GitPorcelain.statusEntryCount(try run(["status", "--porcelain", "--untracked-files=normal"], in: worktree))
    }

    public func unpushedCount(worktree: String, branch: String?) throws -> Int {
        var arguments = ["rev-list", "--count", "HEAD", "--not"]
        // --exclude patterns for --branches are relative to refs/heads/ (a "refs/heads/" prefix matches nothing).
        if let branch { arguments.append("--exclude=\(branch)") }
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
