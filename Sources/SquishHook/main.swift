import Foundation
import SquishCore

// squish-hook: the hook Claude Code, Codex and Gemini CLI run for Squish.
//
// The agent passes the event as JSON on stdin. We rendezvous with the Squish app through
// the file spool at ~/.squish/live. The hook only ever BLOCKS when Squish is actually
// listening (fresh heartbeat) and the session is inside the monitored folder; otherwise it
// passes through immediately (exit 0, no output) so a closed app can never hang a session.
//
// Claude Code and Codex send `PermissionRequest`, which takes an allow/deny answer. Gemini
// CLI sends `Notification` when a tool waits for permission; it takes no answer, so the
// hook only records that the session is waiting and returns at once. `Stop` (Claude Code,
// Codex) and `AfterAgent` (Gemini CLI) mean the turn finished, and Claude Code's
// `Notification` means it is waiting for the user; those become events Squish turns into
// notifications, and the hook returns at once.

let spool = RequestSpool(root: RequestSpool.defaultRoot)

/// Passthrough: emit nothing and let the agent use its native permission flow.
func passthrough() -> Never {
    exit(0)
}

let inputData = FileHandle.standardInput.readDataToEndOfFile()
guard let input = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any] else {
    passthrough()
}

let eventName = (input["hook_event_name"] as? String) ?? ""
let provider = HookProvider.provider(transcriptPath: input["transcript_path"] as? String)
let cwd = (input["cwd"] as? String) ?? ""
let sessionId = HookProvider.sessionID(input["session_id"] as? String, provider: provider)

// Heartbeat gate: Squish must be present and monitoring this session's folder.
guard spool.heartbeatIsFresh(maxAge: RequestSpool.heartbeatMaxAge),
      let heartbeat = spool.readHeartbeat(),
      pathIsInside(cwd, root: heartbeat.monitoredRoot) else {
    passthrough()
}

switch (provider, eventName) {
case (.claude, ClaudeHookResponse.eventName), (.codex, ClaudeHookResponse.eventName):
    handlePermissionRequest()
case (.gemini, "Notification"):
    handleGeminiNotification()
case (.claude, "Stop"), (.codex, "Stop"):
    handleStop(message: input["last_assistant_message"] as? String)
case (.gemini, "AfterAgent"):
    handleStop(message: input["prompt_response"] as? String)
case (.claude, "Notification"):
    handleClaudeNotification()
default:
    // Any other event (a stale PreToolUse registration from an older install, for
    // example) must never intercept an auto-approved tool.
    passthrough()
}

// MARK: - Events

func handlePermissionRequest() -> Never {
    let toolName = (input["tool_name"] as? String) ?? "tool"
    let classification = RequestClassifier.classify(
        toolName: toolName,
        toolInput: input["tool_input"] as? [String: Any]
    )
    let request = PendingRequest(
        id: UUID().uuidString,
        sessionId: sessionId,
        cwd: cwd,
        kind: classification.kind,
        toolName: toolName,
        inputSummary: classification.summary,
        options: classification.options,
        tty: currentTTY(),
        pid: Int(getpid()),
        ppid: Int(getppid()),
        createdAt: Date()
    )

    do {
        try spool.ensureDirectories()
        try spool.writeRequest(request)
    } catch {
        passthrough()
    }

    // Poll for the user's decision, falling back to the agent's native prompt on timeout.
    let deadline = Date().addingTimeInterval(RequestSpool.decisionTimeout)
    while Date() < deadline {
        if let decision = spool.readDecision(for: request.id) {
            print(ClaudeHookResponse.json(for: decision))
            spool.clearRequest(id: request.id)
            exit(0)
        }
        Thread.sleep(forTimeInterval: 0.15)
    }

    spool.clearRequest(id: request.id)
    passthrough()
}

func handleGeminiNotification() -> Never {
    guard (input["notification_type"] as? String) == "ToolPermission" else { passthrough() }
    let details = input["details"] as? [String: Any]
    let toolName = (details?["tool_name"] as? String) ?? (details?["toolName"] as? String) ?? "tool"
    let message = (input["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let summary = message ?? RequestClassifier.classify(toolName: toolName, toolInput: details).summary
    let request = PendingRequest(
        id: UUID().uuidString,
        sessionId: sessionId,
        cwd: cwd,
        kind: .permission,
        toolName: toolName,
        inputSummary: String(summary.prefix(200)),
        options: nil,
        tty: currentTTY(),
        pid: Int(getpid()),
        ppid: Int(getppid()),
        createdAt: Date(),
        isDecidable: false
    )
    try? spool.ensureDirectories()
    try? spool.writeRequest(request)
    passthrough()
}

/// The turn finished: tell Squish and get out of the agent's way. A subagent's stop is its
/// parent's business, not the user's.
func handleStop(message: String?) -> Never {
    guard input["agent_id"] == nil else { passthrough() }
    writeEvent(kind: .finished, message: message)
    passthrough()
}

/// Claude Code is waiting: for a permission (which the PermissionRequest hook may already
/// be showing in the notch; Squish folds the two together) or for the next prompt.
func handleClaudeNotification() -> Never {
    let type = (input["notification_type"] as? String) ?? ""
    guard type == "permission_prompt" || type == "idle_prompt" else { passthrough() }
    writeEvent(kind: .waiting, message: input["message"] as? String)
    passthrough()
}

func writeEvent(kind: AgentEvent.Kind, message: String?) {
    let event = AgentEvent(
        id: UUID().uuidString,
        sessionId: sessionId,
        cwd: cwd,
        kind: kind,
        message: AgentEvent.excerpt(message),
        tty: currentTTY(),
        pid: Int(getpid()),
        ppid: Int(getppid()),
        createdAt: Date()
    )
    try? spool.ensureDirectories()
    try? spool.writeEvent(event)
}

// MARK: - Helpers

func pathIsInside(_ path: String, root: String) -> Bool {
    guard !path.isEmpty, !root.isEmpty else { return false }
    let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    let base = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
    return candidate == base || candidate.hasPrefix(base.hasSuffix("/") ? base : base + "/")
}

func currentTTY() -> String? {
    guard let cString = ttyname(STDIN_FILENO) ?? ttyname(STDERR_FILENO) else { return nil }
    return String(cString: cString)
}
