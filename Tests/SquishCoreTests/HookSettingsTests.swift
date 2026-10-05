import Foundation
import XCTest
@testable import SquishCore

final class HookSettingsTests: XCTestCase {
    let cmd = "/Applications/Squish.app/Contents/MacOS/squish-hook"

    private func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    /// Recursively searches for a string value anywhere in a settings tree,
    /// avoiding JSON slash-escaping pitfalls.
    private func contains(_ value: Any, _ needle: String) -> Bool {
        if let string = value as? String { return string == needle }
        if let dict = value as? [String: Any] { return dict.values.contains { contains($0, needle) } }
        if let array = value as? [Any] { return array.contains { contains($0, needle) } }
        return false
    }

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
        XCTAssertTrue(contains(out, "/usr/bin/true"))
    }

    func testInstallPreservesUnrelatedTopLevelKeys() {
        let existing: [String: Any] = ["model": "opus", "permissions": ["allow": ["Bash"]]]
        let out = HookSettings.installing(cmd, into: existing)
        XCTAssertTrue(json(out).contains("\"model\""))
        XCTAssertTrue(json(out).contains("opus"))
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
        XCTAssertTrue(contains(removed, "/usr/bin/true"))
        XCTAssertFalse(HookSettings.installed(in: removed, command: cmd))
    }

    func testInstalledIsFalseForEmpty() {
        XCTAssertFalse(HookSettings.installed(in: [:], command: cmd))
    }

    func testRegistersUnderPermissionRequestNotPreToolUse() {
        let out = HookSettings.installing(cmd, into: [:])
        let hooks = out["hooks"] as? [String: Any]
        XCTAssertNotNil(hooks?["PermissionRequest"])
        XCTAssertNil(hooks?["PreToolUse"])
    }

    func testInstallMigratesLegacyPreToolUseEntry() {
        // Simulate an older Squish version that registered under PreToolUse.
        let legacy: [String: Any] = ["hooks": ["PreToolUse": [
            ["matcher": "*", "hooks": [["type": "command", "command": cmd, "timeout": 310]]]
        ]]]
        let out = HookSettings.installing(cmd, into: legacy)
        let hooks = out["hooks"] as? [String: Any]
        // The legacy PreToolUse entry is gone; the command lives under PermissionRequest.
        XCTAssertNil(hooks?["PreToolUse"])
        XCTAssertTrue(HookSettings.installed(in: out, command: cmd))
        // Only one registration of the command remains.
        XCTAssertFalse(contains(hooks?["PreToolUse"] as Any, cmd))
    }

    func testMigrationKeepsOtherPreToolUseHooks() {
        let legacy: [String: Any] = ["hooks": ["PreToolUse": [
            ["matcher": "*", "hooks": [
                ["type": "command", "command": cmd],
                ["type": "command", "command": "/usr/bin/true"]
            ]]
        ]]]
        let out = HookSettings.installing(cmd, into: legacy)
        XCTAssertTrue(contains(out, "/usr/bin/true"))
        // /usr/bin/true stays under PreToolUse; squish-hook moved to PermissionRequest.
        let pre = (out["hooks"] as? [String: Any])?["PreToolUse"]
        XCTAssertFalse(contains(pre as Any, cmd))
    }

    func testInstalledIgnoresSameCommandUnderOtherEvent() {
        // The command registered under a different event must not count as installed.
        let existing: [String: Any] = ["hooks": ["PreToolUse": [
            ["matcher": "*", "hooks": [["type": "command", "command": cmd]]]
        ]]]
        XCTAssertFalse(HookSettings.installed(in: existing, command: cmd))
    }
}

final class HookRegistrationTests: XCTestCase {
    let cmd = "/Applications/Squish.app/Contents/MacOS/squish-hook"

    func testGeminiNotificationHookHasNoMatcherAndMillisecondTimeout() {
        let out = HookSettings.installing(cmd, into: [:], registration: .geminiNotification)
        let notification = (out["hooks"] as? [String: Any])?["Notification"] as? [[String: Any]]
        XCTAssertEqual(notification?.count, 1)
        XCTAssertNil(notification?.first?["matcher"])
        let hook = (notification?.first?["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(hook?["command"] as? String, cmd)
        XCTAssertEqual(hook?["timeout"] as? Int, 5_000)
        XCTAssertTrue(HookSettings.installed(in: out, command: cmd, registration: .geminiNotification))
        XCTAssertFalse(HookSettings.installed(in: out, command: cmd))

        let twice = HookSettings.installing(cmd, into: out, registration: .geminiNotification)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: twice, options: [.sortedKeys]),
                       try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]))
        let removed = HookSettings.removing(cmd, from: out, registration: .geminiNotification)
        XCTAssertNil(removed["hooks"])
    }

    func testCodexHooksFileKeepsItsDescription() {
        let existing: [String: Any] = ["description": "mine", "hooks": ["SessionStart": [["hooks": [["type": "command", "command": "/usr/bin/true"]]]]]]
        let out = HookSettings.installing(cmd, into: existing)
        XCTAssertEqual(out["description"] as? String, "mine")
        XCTAssertTrue(HookSettings.installed(in: out, command: cmd))
        XCTAssertNotNil((out["hooks"] as? [String: Any])?["SessionStart"])
    }

    func testPendingRequestDecidabilityAndProvider() throws {
        let shown = PendingRequest(id: "g", sessionId: "gemini:1", cwd: "/p", kind: .permission, toolName: "write_file",
                                   inputSummary: "x", options: nil, tty: nil, pid: nil, ppid: nil, createdAt: Date(), isDecidable: false)
        XCTAssertFalse(shown.isDecidable)
        XCTAssertEqual(shown.provider, .gemini)
        let decoded = try JSONDecoder().decode(PendingRequest.self, from: try JSONEncoder().encode(shown))
        XCTAssertFalse(decoded.isDecidable)

        // Files from older versions have no flag: they were all answerable Claude requests.
        let legacy = Data("""
        {"id":"c","sessionId":"claude:1","cwd":"/p","kind":"permission","toolName":"Bash","inputSummary":"ls","createdAt":1000}
        """.utf8)
        let old = try JSONDecoder().decode(PendingRequest.self, from: legacy)
        XCTAssertTrue(old.isDecidable)
        XCTAssertEqual(old.provider, .claude)
        XCTAssertEqual(PendingRequest(id: "x", sessionId: "codex:9", cwd: "/", kind: .permission, toolName: "Bash", inputSummary: "",
                                      options: nil, tty: nil, pid: nil, ppid: nil, createdAt: Date()).provider, .codex)
    }

    func testHookProviderFromTranscriptPath() {
        XCTAssertEqual(HookProvider.provider(transcriptPath: "/Users/a/.codex/sessions/2026/10/05/rollout.jsonl"), .codex)
        XCTAssertEqual(HookProvider.provider(transcriptPath: "/Users/a/.gemini/tmp/abc/chats/session.json"), .gemini)
        XCTAssertEqual(HookProvider.provider(transcriptPath: "/Users/a/.claude/projects/-p/s.jsonl"), .claude)
        XCTAssertEqual(HookProvider.provider(transcriptPath: nil), .claude)
        XCTAssertEqual(HookProvider.sessionID("abc", provider: .codex), "codex:abc")
        XCTAssertEqual(HookProvider.sessionID(nil, provider: .claude), "claude:unknown")
    }
}
