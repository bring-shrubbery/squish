import Foundation
import SquishCore

// squish-hook: a Claude Code PreToolUse hook.
//
// Claude passes the tool request as JSON on stdin. We rendezvous with the Squish
// app through the file spool at ~/.squish/live. The hook only ever BLOCKS when
// Squish is actually listening (fresh heartbeat) and the session is inside the
// monitored folder; otherwise it passes through immediately (exit 0, no output)
// so a closed app can never hang a Claude session.

let spool = RequestSpool(root: RequestSpool.defaultRoot)

/// Passthrough: emit nothing and let Claude use its native permission flow.
func passthrough() -> Never {
    exit(0)
}

let inputData = FileHandle.standardInput.readDataToEndOfFile()
guard let input = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any] else {
    passthrough()
}

// Only act on PermissionRequest — the event that fires solely when Claude would
// actually prompt the user. Ignoring any other event (e.g. a stale PreToolUse
// registration from an older install) prevents intercepting auto-approved tools.
let eventName = (input["hook_event_name"] as? String) ?? ""
guard eventName == ClaudeHookResponse.eventName else {
    passthrough()
}

let cwd = (input["cwd"] as? String) ?? ""
let toolName = (input["tool_name"] as? String) ?? "tool"
let sessionId = (input["session_id"] as? String).map { "claude:\($0)" } ?? "claude:unknown"
let toolInput = input["tool_input"]

// Heartbeat gate — Squish must be present and monitoring this session's folder.
guard spool.heartbeatIsFresh(maxAge: RequestSpool.heartbeatMaxAge),
      let heartbeat = spool.readHeartbeat(),
      pathIsInside(cwd, root: heartbeat.monitoredRoot) else {
    passthrough()
}

let classification = RequestClassifier.classify(
    toolName: toolName,
    toolInput: toolInput as? [String: Any]
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

// Poll for the user's decision, falling back to Claude's native prompt on timeout.
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
