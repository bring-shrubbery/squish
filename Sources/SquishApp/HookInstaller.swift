import ApplicationServices
import Foundation
import SquishCore

/// Installs and removes Squish's Claude Code hook in `~/.claude/settings.json`,
/// and manages the Accessibility permission the keystroke write-path needs.
///
/// All settings mutation goes through the pure `HookSettings` merge, so a
/// malformed or unexpected file is never clobbered — it is backed up first and
/// only the Squish hook block is added or removed.
@MainActor
final class HookInstaller {
    let settingsURL: URL

    init(settingsURL: URL? = nil) {
        self.settingsURL = settingsURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    /// Absolute path to the bundled `squish-hook` executable, sitting next to the
    /// app binary in both `swift run` and packaged `.app` layouts.
    func hookCommandPath() -> String {
        let base = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "").deletingLastPathComponent()
        return base.appendingPathComponent("squish-hook").path
    }

    func isInstalled() -> Bool {
        HookSettings.installed(in: loadSettings(), command: hookCommandPath())
    }

    func install() throws {
        let current = loadSettings()
        backupIfNeeded()
        let updated = HookSettings.installing(hookCommandPath(), into: current)
        try writeSettings(updated)
    }

    func uninstall() throws {
        let current = loadSettings()
        let updated = HookSettings.removing(hookCommandPath(), from: current)
        try writeSettings(updated)
    }

    // MARK: - Accessibility

    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Prompts the user to grant Accessibility if not already trusted.
    @discardableResult
    func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Settings IO

    private func loadSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    private func backupIfNeeded() {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let backup = settingsURL.appendingPathExtension("squish-backup")
        // Only create a backup once so we always keep the pre-Squish original.
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: settingsURL, to: backup)
    }
}
