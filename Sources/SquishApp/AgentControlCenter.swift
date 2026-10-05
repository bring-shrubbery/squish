import Combine
import Foundation
import SquishCore

/// Owns the live interactive path: watches the request spool, keeps the heartbeat
/// fresh so the hook knows Squish is listening, and resolves pending requests.
@MainActor
final class AgentControlCenter: ObservableObject {
    @Published private(set) var pendingRequests: [PendingRequest] = []

    private let spool: RequestSpool
    private var monitor: FileSystemEventMonitor?
    private var heartbeatTimer: Timer?
    private var monitoredRoot: URL?

    init(spool: RequestSpool = RequestSpool(root: RequestSpool.defaultRoot)) {
        self.spool = spool
    }

    /// Begin listening for requests scoped to `monitoredRoot`.
    func start(monitoredRoot: URL) {
        stop()
        self.monitoredRoot = monitoredRoot

        try? spool.ensureDirectories()
        spool.cleanupStale(olderThan: RequestSpool.staleRequestAge)
        writeHeartbeat()

        let monitor = FileSystemEventMonitor(paths: [spool.requestsDirectory]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reload() }
        }
        monitor.start()
        self.monitor = monitor

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.writeHeartbeat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer

        reload()
    }

    func stop() {
        monitor?.stop()
        monitor = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        spool.removeHeartbeat()
        pendingRequests = []
        monitoredRoot = nil
    }

    /// Write the user's decision for a request, delivering typed answers to the
    /// terminal, and optimistically drop it from the pending list.
    func resolve(_ request: PendingRequest, with decision: AgentDecision) {
        // Answering a question means letting Claude's question tool run (allow) and
        // delivering the chosen text into the terminal — not denying it.
        let hookDecision: AgentDecision
        if request.kind == .question, case .answer = decision {
            hookDecision = .allow
        } else {
            hookDecision = decision
        }
        try? spool.writeDecision(hookDecision, for: request.id)

        if case let .answer(text) = decision {
            TerminalResponder.deliver(answer: text, toPid: request.pid)
        }
        pendingRequests.removeAll { $0.id == request.id }
    }

    /// Drops a request Squish could only show (Gemini CLI): the user answered it in the
    /// terminal, or wants it out of the notch.
    func dismiss(_ request: PendingRequest) {
        spool.clearRequest(id: request.id)
        pendingRequests.removeAll { $0.id == request.id }
    }

    /// Inject a request directly (used by the settings Preview button).
    func injectPreview(_ request: PendingRequest) {
        try? spool.ensureDirectories()
        try? spool.writeRequest(request)
        reload()
    }

    // MARK: - Internals

    private func reload() {
        let root = monitoredRoot?.standardizedFileURL.resolvingSymlinksInPath().path
        let all = spool.pendingRequests()
        let scoped = all.filter { request in
            guard let root else { return true }
            let cwd = URL(fileURLWithPath: request.cwd).standardizedFileURL.resolvingSymlinksInPath().path
            return cwd == root || cwd.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        if scoped != pendingRequests { pendingRequests = scoped }
    }

    private func writeHeartbeat() {
        guard let root = monitoredRoot else { return }
        try? spool.writeHeartbeat(
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            monitoredRoot: root.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }
}
