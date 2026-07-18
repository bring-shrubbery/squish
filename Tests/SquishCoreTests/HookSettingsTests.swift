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
