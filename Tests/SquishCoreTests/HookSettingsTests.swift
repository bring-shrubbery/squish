import Foundation
import XCTest
@testable import SquishCore

final class HookSettingsTests: XCTestCase {
    let cmd = "/Applications/Squish.app/Contents/MacOS/squish-hook"

    private func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
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
        XCTAssertTrue(HookSettings.installed(in: out, command: "/usr/bin/true"))
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
        XCTAssertTrue(HookSettings.installed(in: removed, command: "/usr/bin/true"))
        XCTAssertFalse(HookSettings.installed(in: removed, command: cmd))
    }

    func testInstalledIsFalseForEmpty() {
        XCTAssertFalse(HookSettings.installed(in: [:], command: cmd))
    }
}
