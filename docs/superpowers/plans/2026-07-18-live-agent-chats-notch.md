# Live Agent Chats in the Notch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface live AI agent chats in the macOS notch — horizontal when active, click-to-expand detail, vertical-open with multi-session tabs when a Claude Code agent needs a permission or an answer, answerable in-notch.

**Architecture:** A passive display path reuses the existing `SessionScanner` to show active chats. A live interactive path uses a bundled Claude Code hook executable that rendezvous with the app through a file spool under `~/.squish/live/`; the hook blocks for a decision only while the app's heartbeat is fresh, otherwise it passes through so a closed app never hangs a session. Permissions resolve through the hook's return value; free-text answers are injected into the session's terminal via Accessibility keystrokes with a clipboard fallback.

**Tech Stack:** Swift 6 / SwiftUI, macOS 14+, DynamicNotchKit 1.1.0, FSEvents, XCTest, ApplicationServices (Accessibility/CGEvent).

## Global Constraints

- Swift tools version 6.0, `swiftLanguageModes: [.v5]`, platform macOS 14+ (verbatim from `Package.swift`).
- Wire-format types shared between app and hook live in `SquishCore` so both compile the same code.
- The hook MUST pass through (exit 0, no decision) when the heartbeat is stale, the feature is off, or `cwd` is outside the monitored root. This is a correctness requirement, not a nicety.
- Tests use `XCTest` and `@testable import SquishCore`, matching `Tests/SquishCoreTests`.
- Never clobber the user's existing `~/.claude/settings.json` hooks; merge with backup, reverse cleanly on disable.
- Provider colors: Claude `AppColors.pink`, Codex `AppColors.cyan`, Gemini `AppColors.blue` (from `NotchAlertController`).

---

## File Structure

**SquishCore (pure, tested):**
- `Sources/SquishCore/LiveAgentModels.swift` — `RequestKind`, `PendingRequest`, `AgentDecision`, Codable + Claude hook-response JSON builder.
- `Sources/SquishCore/RequestSpool.swift` — spool dir layout, atomic request/decision IO, enumeration, stale cleanup, heartbeat read/write, timeout constants.
- `Sources/SquishCore/HookSettings.swift` — merge/unmerge Squish hook into a settings dictionary; install-detection.
- `Sources/SquishCore/LiveActivity.swift` — active predicate + working/waiting/idle grouping.

**squish-hook executable:**
- `Sources/SquishHook/main.swift` — reads hook JSON stdin, heartbeat gate, spool rendezvous, emits hook-response JSON.

**SquishApp (integration/UI):**
- `Sources/SquishApp/AgentControlCenter.swift`
- `Sources/SquishApp/HookInstaller.swift`
- `Sources/SquishApp/TerminalResponder.swift`
- `Sources/SquishApp/LiveChatsNotchController.swift`
- `Sources/SquishApp/LiveChatsViews.swift` (compact + panel + prompt views)
- `Sources/SquishApp/LiveChatsSettingsView.swift`
- Modify: `Sources/SquishApp/AppState.swift`, `Sources/SquishApp/RootView.swift`, `Package.swift`.

**Tests:**
- `Tests/SquishCoreTests/LiveAgentModelsTests.swift`
- `Tests/SquishCoreTests/RequestSpoolTests.swift`
- `Tests/SquishCoreTests/HookSettingsTests.swift`
- `Tests/SquishCoreTests/LiveActivityTests.swift`

---

## Task 1: Wire-format models (`LiveAgentModels`)

**Files:**
- Create: `Sources/SquishCore/LiveAgentModels.swift`
- Test: `Tests/SquishCoreTests/LiveAgentModelsTests.swift`

**Interfaces:**
- Produces:
  - `enum RequestKind: String, Codable, Sendable { case permission, question }`
  - `struct PendingRequest: Codable, Equatable, Identifiable, Sendable` with `let id: String; sessionId: String; cwd: String; kind: RequestKind; toolName: String; inputSummary: String; options: [String]?; tty: String?; pid: Int?; ppid: Int?; createdAt: Date`
  - `enum AgentDecision: Equatable, Sendable { case allow, deny, alwaysAllow, answer(String) }` with `func encoded() -> Data` and `static func decode(_:) -> AgentDecision?` using JSON `{ "decision": "allow|deny|alwaysAllow|answer", "text": "…" }`
  - `enum ClaudeHookResponse { static func json(for: AgentDecision) -> String }` producing `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow|deny","permissionDecisionReason":"…"}}` (alwaysAllow → allow with a reason; answer → deny with the text as `permissionDecisionReason` so Claude sees the reply as feedback).

- [ ] **Step 1: Write failing tests**

```swift
import Foundation
import XCTest
@testable import SquishCore

final class LiveAgentModelsTests: XCTestCase {
    func testPendingRequestRoundTrips() throws {
        let request = PendingRequest(
            id: "abc", sessionId: "claude:s1", cwd: "/tmp/proj",
            kind: .permission, toolName: "Bash", inputSummary: "rm -rf build/",
            options: nil, tty: "/dev/ttys003", pid: 42, ppid: 7,
            createdAt: Date(timeIntervalSince1970: 1000)
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PendingRequest.self, from: data)
        XCTAssertEqual(decoded, request)
    }

    func testAgentDecisionAnswerRoundTrips() {
        let decision = AgentDecision.answer("use the staging DB")
        let restored = AgentDecision.decode(decision.encoded())
        XCTAssertEqual(restored, .answer("use the staging DB"))
    }

    func testAllowProducesAllowHookJSON() {
        let json = ClaudeHookResponse.json(for: .allow)
        XCTAssertTrue(json.contains("\"permissionDecision\":\"allow\""))
    }

    func testDenyProducesDenyHookJSON() {
        let json = ClaudeHookResponse.json(for: .deny)
        XCTAssertTrue(json.contains("\"permissionDecision\":\"deny\""))
    }

    func testAnswerProducesDenyWithReason() {
        let json = ClaudeHookResponse.json(for: .answer("do X"))
        XCTAssertTrue(json.contains("\"permissionDecision\":\"deny\""))
        XCTAssertTrue(json.contains("do X"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter LiveAgentModelsTests`
Expected: FAIL (types not defined).

- [ ] **Step 3: Implement `LiveAgentModels.swift`** — the types and JSON builders described in Interfaces. `AgentDecision` encodes to `{"decision":…,"text":…}`; `ClaudeHookResponse.json(for:)` maps allow→allow, deny/answer→deny (answer's text becomes `permissionDecisionReason`), alwaysAllow→allow with reason `"Squish: always allow"`.

- [ ] **Step 4: Run tests** — `swift test --filter LiveAgentModelsTests` → PASS.

- [ ] **Step 5: Commit** — `git add Sources/SquishCore/LiveAgentModels.swift Tests/SquishCoreTests/LiveAgentModelsTests.swift && git commit -m "feat(core): add live agent wire-format models"`

---

## Task 2: Request spool + heartbeat (`RequestSpool`)

**Files:**
- Create: `Sources/SquishCore/RequestSpool.swift`
- Test: `Tests/SquishCoreTests/RequestSpoolTests.swift`

**Interfaces:**
- Consumes: `PendingRequest`, `AgentDecision` (Task 1).
- Produces `struct RequestSpool: Sendable`:
  - `init(root: URL)` — root defaults in app/hook to `~/.squish/live`; tests pass a temp dir.
  - `let requestsDirectory: URL`, `heartbeatURL: URL`
  - `func ensureDirectories() throws`
  - `func writeRequest(_ request: PendingRequest) throws` → `requests/<id>.json` (atomic)
  - `func pendingRequests() -> [PendingRequest]` (reads all `*.json` that lack a matching decision, sorted by `createdAt`)
  - `func writeDecision(_ decision: AgentDecision, for id: String) throws` → `requests/<id>.decision.json` (atomic)
  - `func readDecision(for id: String) -> AgentDecision?`
  - `func clearRequest(id: String)` — removes both files
  - `func cleanupStale(olderThan seconds: TimeInterval, now: Date) ` — removes request+decision files whose request `createdAt` is older than `seconds`
  - `func writeHeartbeat(pid: Int, monitoredRoot: String, now: Date) throws`
  - `struct Heartbeat: Codable, Equatable { let pid: Int; let monitoredRoot: String; let timestamp: Date }`
  - `func readHeartbeat() -> Heartbeat?`
  - `func heartbeatIsFresh(maxAge: TimeInterval, now: Date) -> Bool`
  - `static let decisionTimeout: TimeInterval = 300`, `static let staleRequestAge: TimeInterval = 900`, `static let heartbeatMaxAge: TimeInterval = 15`

- [ ] **Step 1: Write failing tests** (temp-dir based)

```swift
import Foundation
import XCTest
@testable import SquishCore

final class RequestSpoolTests: XCTestCase {
    private func tempSpool() throws -> RequestSpool {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("squish-spool-\(UUID().uuidString)")
        let spool = RequestSpool(root: dir)
        try spool.ensureDirectories()
        return spool
    }

    private func sampleRequest(id: String, createdAt: Date = Date()) -> PendingRequest {
        PendingRequest(id: id, sessionId: "claude:s", cwd: "/tmp/p", kind: .permission,
                       toolName: "Bash", inputSummary: "ls", options: nil,
                       tty: nil, pid: nil, ppid: nil, createdAt: createdAt)
    }

    func testWriteAndReadPending() throws {
        let spool = try tempSpool()
        try spool.writeRequest(sampleRequest(id: "r1"))
        XCTAssertEqual(spool.pendingRequests().map(\.id), ["r1"])
    }

    func testDecisionRoundTripAndClear() throws {
        let spool = try tempSpool()
        try spool.writeRequest(sampleRequest(id: "r1"))
        try spool.writeDecision(.deny, for: "r1")
        XCTAssertEqual(spool.readDecision(for: "r1"), .deny)
        spool.clearRequest(id: "r1")
        XCTAssertNil(spool.readDecision(for: "r1"))
        XCTAssertTrue(spool.pendingRequests().isEmpty)
    }

    func testDecidedRequestsAreNotPending() throws {
        let spool = try tempSpool()
        try spool.writeRequest(sampleRequest(id: "r1"))
        try spool.writeDecision(.allow, for: "r1")
        XCTAssertTrue(spool.pendingRequests().isEmpty)
    }

    func testCleanupStale() throws {
        let spool = try tempSpool()
        let now = Date(timeIntervalSince1970: 10_000)
        try spool.writeRequest(sampleRequest(id: "old", createdAt: now.addingTimeInterval(-1000)))
        try spool.writeRequest(sampleRequest(id: "new", createdAt: now.addingTimeInterval(-10)))
        spool.cleanupStale(olderThan: 900, now: now)
        XCTAssertEqual(spool.pendingRequests().map(\.id), ["new"])
    }

    func testHeartbeatFreshness() throws {
        let spool = try tempSpool()
        let now = Date(timeIntervalSince1970: 10_000)
        try spool.writeHeartbeat(pid: 5, monitoredRoot: "/tmp/p", now: now)
        XCTAssertTrue(spool.heartbeatIsFresh(maxAge: 15, now: now.addingTimeInterval(5)))
        XCTAssertFalse(spool.heartbeatIsFresh(maxAge: 15, now: now.addingTimeInterval(60)))
        XCTAssertEqual(spool.readHeartbeat()?.pid, 5)
    }
}
```

- [ ] **Step 2: Run** — `swift test --filter RequestSpoolTests` → FAIL.
- [ ] **Step 3: Implement `RequestSpool.swift`** per Interfaces. Use `Data.write(to:options:.atomic)`; JSON via `JSONEncoder`/`Decoder` with `.iso8601`-compatible date strategy (use `secondsSince1970` to stay simple and match `Date` equality in tests). Enumerate `requests/` with `contentsOfDirectory`.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(core): add request spool and heartbeat"`

---

## Task 3: Settings merge (`HookSettings`)

**Files:**
- Create: `Sources/SquishCore/HookSettings.swift`
- Test: `Tests/SquishCoreTests/HookSettingsTests.swift`

**Interfaces:**
- Produces `enum HookSettings`:
  - `static func installed(in settings: [String: Any], command: String) -> Bool`
  - `static func installing(_ command: String, into settings: [String: Any]) -> [String: Any]` — adds a `PreToolUse` matcher `"*"` whose hooks include `{ "type": "command", "command": command, "timeout": 310 }` tagged so it is identifiable (command path is the identity). Preserves all existing `hooks` entries.
  - `static func removing(_ command: String, from settings: [String: Any]) -> [String: Any]` — removes only the Squish hook entry (matched by `command`), leaving everything else, and prunes now-empty containers.
  - Idempotent: installing twice yields the same structure.

- [ ] **Step 1: Write failing tests**

```swift
import Foundation
import XCTest
@testable import SquishCore

final class HookSettingsTests: XCTestCase {
    let cmd = "/Applications/Squish.app/Contents/MacOS/squish-hook"

    func testInstallIntoEmpty() {
        let out = HookSettings.installing(cmd, into: [:])
        XCTAssertTrue(HookSettings.installed(in: out, command: cmd))
    }

    func testInstallPreservesExistingHooks() {
        let existing: [String: Any] = ["hooks": ["PreToolUse": [
            ["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/bin/true"]]]
        ]]]
        let out = HookSettings.installing(cmd, into: existing)
        XCTAssertTrue(HookSettings.installed(in: out, command: cmd))
        let json = String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!
        XCTAssertTrue(json.contains("/usr/bin/true"))
    }

    func testInstallIsIdempotent() {
        let once = HookSettings.installing(cmd, into: [:])
        let twice = HookSettings.installing(cmd, into: once)
        let a = try! JSONSerialization.data(withJSONObject: once, options: [.sortedKeys])
        let b = try! JSONSerialization.data(withJSONObject: twice, options: [.sortedKeys])
        XCTAssertEqual(a, b)
    }

    func testRemoveRestoresAbsence() {
        let installed = HookSettings.installing(cmd, into: [:])
        let removed = HookSettings.removing(cmd, from: installed)
        XCTAssertFalse(HookSettings.installed(in: removed, command: cmd))
    }

    func testRemoveKeepsOtherHooks() {
        let existing: [String: Any] = ["hooks": ["PreToolUse": [
            ["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/bin/true"]]]
        ]]]
        let installed = HookSettings.installing(cmd, into: existing)
        let removed = HookSettings.removing(cmd, from: installed)
        let json = String(data: try! JSONSerialization.data(withJSONObject: removed), encoding: .utf8)!
        XCTAssertTrue(json.contains("/usr/bin/true"))
        XCTAssertFalse(json.contains("squish-hook"))
    }
}
```

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement `HookSettings.swift`** — dictionary manipulation over `settings["hooks"]["PreToolUse"]` as `[[String: Any]]`; each matcher has `"hooks": [[String: Any]]`. Install appends a Squish command hook under a `"*"` matcher (creating it if absent), dedup by `command`. Remove filters out command-hooks equal to `command`, then drops empty `hooks` arrays / empty matchers / empty `PreToolUse` / empty `hooks`.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(core): add claude hook settings merge"`

---

## Task 4: Activity grouping (`LiveActivity`)

**Files:**
- Create: `Sources/SquishCore/LiveActivity.swift`
- Test: `Tests/SquishCoreTests/LiveActivityTests.swift`

**Interfaces:**
- Consumes: `CodingSession`, `PendingRequest`.
- Produces:
  - `enum LiveStatus: Sendable { case working, waiting, idle }`
  - `struct LiveChat: Identifiable, Sendable { let session: CodingSession; let status: LiveStatus; var id: String { session.id } }`
  - `enum LiveActivity { static func chats(sessions: [CodingSession], pending: [PendingRequest], activeWindow: TimeInterval = 90, workingWindow: TimeInterval = 8, now: Date) -> [LiveChat] }` — a session is included if it has a pending request OR `now - updatedAt <= activeWindow`; status = `.waiting` if it has a pending request, else `.working` if `now - updatedAt <= workingWindow`, else `.idle`. Excludes subagents. Sorted waiting-first, then by `updatedAt` desc.

- [ ] **Step 1: Write failing tests**

```swift
import Foundation
import XCTest
@testable import SquishCore

final class LiveActivityTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 10_000)

    private func session(_ id: String, ago: TimeInterval, sub: Bool = false) -> CodingSession {
        CodingSession(id: id, provider: .claude, title: id, projectPath: "/p", model: "m",
            usage: TokenUsage(), contextTokens: 1, contextWindow: 10,
            startedAt: now.addingTimeInterval(-1000), updatedAt: now.addingTimeInterval(-ago),
            logPath: "/l", lastUserMessageAt: nil, isSubagent: sub)
    }
    private func pending(_ sid: String) -> PendingRequest {
        PendingRequest(id: "req-\(sid)", sessionId: sid, cwd: "/p", kind: .permission,
            toolName: "Bash", inputSummary: "ls", options: nil, tty: nil, pid: nil, ppid: nil, createdAt: now)
    }

    func testActiveWindowFiltersOldSessions() {
        let chats = LiveActivity.chats(sessions: [session("a", ago: 5), session("b", ago: 500)],
                                       pending: [], now: now)
        XCTAssertEqual(chats.map(\.id), ["a"])
    }

    func testStatuses() {
        let chats = LiveActivity.chats(
            sessions: [session("work", ago: 2), session("idle", ago: 60), session("wait", ago: 300)],
            pending: [pending("wait")], now: now)
        let byId = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0.status) })
        XCTAssertEqual(byId["work"], .working)
        XCTAssertEqual(byId["idle"], .idle)
        XCTAssertEqual(byId["wait"], .waiting)
    }

    func testWaitingSortedFirstAndSubagentsExcluded() {
        let chats = LiveActivity.chats(
            sessions: [session("work", ago: 1), session("wait", ago: 400), session("sub", ago: 1, sub: true)],
            pending: [pending("wait")], now: now)
        XCTAssertEqual(chats.first?.id, "wait")
        XCTAssertFalse(chats.contains { $0.id == "sub" })
    }
}
```

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement `LiveActivity.swift`** per Interfaces.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(core): add live activity grouping"`

---

## Task 5: Hook executable (`SquishHook`)

**Files:**
- Create: `Sources/SquishHook/main.swift`
- Modify: `Package.swift` (add `executableTarget(name: "SquishHook", dependencies: ["SquishCore"])` and product).

**Interfaces:**
- Consumes: `RequestSpool`, `PendingRequest`, `AgentDecision`, `ClaudeHookResponse`.
- Behavior: read all stdin (Claude's `PreToolUse` JSON: `tool_name`, `tool_input`, `cwd`, `session_id`). Build `RequestSpool(root: ~/.squish/live)`. If `!heartbeatIsFresh(maxAge:) || heartbeat.monitoredRoot` not a prefix of `cwd` → print nothing, exit 0 (passthrough). Else write a `PendingRequest` (id = UUID, `inputSummary` = compact one-line of `tool_input`, tty from `ttyname(1)` if a TTY, pid = `getpid()`, ppid = `getppid()`), then poll `readDecision(for:)` every 150ms up to `decisionTimeout`. On decision: print `ClaudeHookResponse.json(for:)`, `clearRequest`, exit 0. On timeout: `clearRequest`, exit 0 (passthrough).

- [ ] **Step 1: Add the target to `Package.swift`.** Insert into `targets`:
```swift
.executableTarget(name: "SquishHook", dependencies: ["SquishCore"]),
```
and add `.executable(name: "squish-hook", targets: ["SquishHook"])` to `products`.

- [ ] **Step 2: Implement `Sources/SquishHook/main.swift`** per Interfaces. Read stdin via `FileHandle.standardInput.readDataToEndOfFile()`; parse with `JSONSerialization`. Resolve home via `FileManager.default.homeDirectoryForCurrentUser`.

- [ ] **Step 3: Build** — Run: `swift build` → Expected: builds `SquishHook` and existing targets with no errors.

- [ ] **Step 4: Smoke test the passthrough** — Run:
```bash
echo '{"tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/nope","session_id":"x"}' | swift run squish-hook; echo "exit=$?"
```
Expected: no output, `exit=0` (no heartbeat → passthrough).

- [ ] **Step 5: Commit** — `git commit -m "feat(hook): add squish-hook executable"`

---

## Task 6: Hook installer (`HookInstaller`)

**Files:**
- Create: `Sources/SquishApp/HookInstaller.swift`

**Interfaces:**
- Consumes: `HookSettings`.
- Produces `@MainActor final class HookInstaller`:
  - `var settingsURL: URL` (default `~/.claude/settings.json`)
  - `func hookCommandPath() -> String` — path to the bundled `squish-hook` (in dev: the build products dir via `Bundle.main`/`CommandLine`; in packaged app: `Bundle.main.bundleURL/Contents/MacOS/squish-hook`).
  - `func isInstalled() -> Bool`
  - `func install() throws` — read+decode settings (empty if missing), back up to `settings.json.squish-backup`, write `HookSettings.installing(...)` pretty-printed.
  - `func uninstall() throws` — write `HookSettings.removing(...)`.
  - `var accessibilityGranted: Bool { AXIsProcessTrusted() }`
  - `func requestAccessibility()` — `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`.

- [ ] **Step 1: Implement `HookInstaller.swift`** per Interfaces (no unit test — filesystem/OS-permission side effects; logic lives in tested `HookSettings`).
- [ ] **Step 2: Build** — `swift build` → no errors.
- [ ] **Step 3: Commit** — `git commit -m "feat(app): add hook installer"`

---

## Task 7: Terminal responder (`TerminalResponder`)

**Files:**
- Create: `Sources/SquishApp/TerminalResponder.swift`

**Interfaces:**
- Produces `@MainActor enum TerminalResponder`:
  - `static func deliver(answer: String, toPid pid: Int?)` — if `AXIsProcessTrusted()` and `pid` resolves to a running app: activate that app (`NSRunningApplication(processIdentifier:)`.activate), set clipboard, synthesize Cmd-V then Return via `CGEvent`. Otherwise fallback: set clipboard + post an `NSUserNotification`/`UNUserNotification` telling the user the answer is copied.

- [ ] **Step 1: Implement `TerminalResponder.swift`** per Interfaces. Keep it defensive: every OS call guarded; never throws.
- [ ] **Step 2: Build** — `swift build` → no errors.
- [ ] **Step 3: Commit** — `git commit -m "feat(app): add terminal keystroke responder"`

---

## Task 8: Control center (`AgentControlCenter`)

**Files:**
- Create: `Sources/SquishApp/AgentControlCenter.swift`

**Interfaces:**
- Consumes: `RequestSpool`, `PendingRequest`, `AgentDecision`, `FileSystemEventMonitor`, `TerminalResponder`.
- Produces `@MainActor final class AgentControlCenter: ObservableObject`:
  - `@Published private(set) var pendingRequests: [PendingRequest] = []`
  - `func start(monitoredRoot: URL)` — ensure spool dirs, cleanup stale, start `FileSystemEventMonitor` on `requests/`, start a heartbeat timer (writes every ~5s with `getpid()` + root), do an initial `reload()`.
  - `func stop()` — stop monitor + timer, clear pending, remove heartbeat file.
  - `func resolve(_ request: PendingRequest, with decision: AgentDecision)` — `writeDecision`; if `.answer(let text)` also `TerminalResponder.deliver(answer: text, toPid: request.pid)`; optimistically drop it from `pendingRequests`.
  - private `reload()` — `pendingRequests = spool.pendingRequests()` filtered to `monitoredRoot` prefix.

- [ ] **Step 1: Implement `AgentControlCenter.swift`** per Interfaces. Debounce FSEvent reloads onto the main actor.
- [ ] **Step 2: Build** — `swift build` → no errors.
- [ ] **Step 3: Commit** — `git commit -m "feat(app): add agent control center"`

---

## Task 9: Notch views + controller

**Files:**
- Create: `Sources/SquishApp/LiveChatsViews.swift`, `Sources/SquishApp/LiveChatsNotchController.swift`

**Interfaces:**
- Consumes: `LiveChat`, `LiveStatus`, `PendingRequest`, `AgentDecision`, provider colors.
- Produces:
  - `LiveChatsCompactView(chats:)`, `LiveChatsPanelView(chats:pending:onResolve:onOpenTerminal:)`, `RequestPromptView(pending:selection:onResolve:)` (tab strip + permission buttons / question field).
  - `@MainActor final class LiveChatsNotchController` with `func update(chats: [LiveChat], pending: [PendingRequest], onResolve:)`. Internally holds one `DynamicNotch<AnyView, AnyView, AnyView>`. Logic: if `pending` non-empty → `.expand()` showing `RequestPromptView`; else if a user click is active → `.expand()` showing `LiveChatsPanelView`; else if `chats` non-empty → `.compact()` showing `LiveChatsCompactView` (leading = provider dots, trailing = count); else `.hide()`. Compact content has a tap handler that sets an internal `panelRequested` flag → re-`update`.

- [ ] **Step 1: Implement the SwiftUI views** in `LiveChatsViews.swift`, matching `NotchAlertView`'s visual vocabulary (materials, SF Symbols, monospaced digits, provider colors).
- [ ] **Step 2: Implement `LiveChatsNotchController.swift`** per Interfaces, reusing `NotchAlertController`'s screen-selection logic.
- [ ] **Step 3: Build** — `swift build` → no errors.
- [ ] **Step 4: Commit** — `git commit -m "feat(app): add live chats notch UI"`

---

## Task 10: AppState + settings UI wiring

**Files:**
- Modify: `Sources/SquishApp/AppState.swift`, `Sources/SquishApp/RootView.swift`
- Create: `Sources/SquishApp/LiveChatsSettingsView.swift`

**Interfaces:**
- Consumes: `AgentControlCenter`, `HookInstaller`, `LiveChatsNotchController`, `LiveActivity`.
- Produces:
  - `AppState`: `@Published var liveChatsEnabled: Bool` (persisted `liveChatsEnabled`, default false); owns `AgentControlCenter`, `HookInstaller`, `LiveChatsNotchController`; on enable → `installer.install()` + `requestAccessibility()` + `controlCenter.start(root)`; on disable → `controlCenter.stop()` + `installer.uninstall()`. A Combine sink recomputes `LiveActivity.chats(...)` from `sessions` + `controlCenter.pendingRequests` on a timer/updates and calls `notch.update(...)`.
  - `AppSection.liveChats` (title "Live chats", symbol `"bubble.left.and.bubble.right"`), added to `RootView` sidebar/switch.
  - `LiveChatsSettingsView` — toggle, hook-install status row, Accessibility status row, and a "Preview" button that pushes a fake pending request through `controlCenter` (or directly to the notch).

- [ ] **Step 1: Implement `LiveChatsSettingsView.swift`.**
- [ ] **Step 2: Wire `AppState`** — add the properties/lifecycle above; scope activity + pending to `projectRoot`.
- [ ] **Step 3: Add the section to `RootView`.**
- [ ] **Step 4: Build** — `swift build` → no errors.
- [ ] **Step 5: Run full test suite** — `swift test` → all pass.
- [ ] **Step 6: Commit** — `git commit -m "feat(app): wire live chats feature and settings"`

---

## Task 11: Verification pass

- [ ] **Step 1:** `swift build` clean.
- [ ] **Step 2:** `swift test` — all SquishCore tests green.
- [ ] **Step 3:** Hook passthrough smoke test (Task 5 Step 4) still exits 0.
- [ ] **Step 4:** Seed a heartbeat + a fake request, run the hook, write a decision file out-of-band, confirm it prints allow/deny JSON and clears the files:
```bash
swift run squish-hook < fixture.json &   # with a fresh heartbeat + matching cwd
# in another step: write requests/<id>.decision.json then confirm output
```
- [ ] **Step 5:** Document the manual GUI walkthrough from the spec's "Manual / integration verification" list in the PR description.
- [ ] **Step 6:** Final commit / open PR.

---

## Self-Review

- **Spec coverage:** active-chat display → Tasks 4,9,10; horizontal notch → Task 9; click-to-expand detail → Task 9; vertical-open on request → Tasks 8,9; multi-session tabs → Task 9 (`RequestPromptView`); permissions via hook → Tasks 1,5,8; full answers via keystrokes → Task 7; auto-install w/ consent → Tasks 6,10; heartbeat passthrough safety → Tasks 2,5; toggle + settings → Task 10; provider display-only deep-link → Task 9. All covered.
- **Placeholder scan:** core tasks (1–4) carry full test code + implementation contracts; app/UI tasks (6–10) specify exact files, types, and behavior (no runtime unit tests because they are GUI/OS-permission bound — logic they depend on is unit-tested in core).
- **Type consistency:** `PendingRequest`, `AgentDecision`, `RequestSpool`, `HookSettings`, `LiveChat`/`LiveStatus`, `ClaudeHookResponse.json(for:)` names are used identically across producing and consuming tasks.
