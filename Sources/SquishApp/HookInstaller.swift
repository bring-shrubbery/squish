import ApplicationServices
import Foundation
import SquishCore

/// Installs and removes Squish's hook in each agent's settings, and manages the
/// Accessibility permission the keystroke write-path needs.
///
/// - Claude Code: `~/.claude/settings.json`, a `PermissionRequest` hook.
/// - Codex: `~/.codex/hooks.json`, the same hook, plus `hooks = true` under `[features]` in
///   `~/.codex/config.toml`, which Codex needs before it reads hooks at all.
/// - Gemini CLI: `~/.gemini/settings.json`, a `Notification` hook that only reports waiting.
///
/// All settings mutation goes through the pure `HookSettings` merge, so a malformed or
/// unexpected file is never clobbered: it is backed up first and only the Squish hook block
/// is added or removed. An agent whose folder does not exist is left alone.
@MainActor
final class HookInstaller {
    enum Status: Equatable {
        case installed
        case notInstalled
        /// The agent's settings folder is missing: it is not installed, or never ran.
        case agentNotFound
        /// Installed, but Codex's `config.toml` keeps `features` in a form Squish does not
        /// rewrite; the user adds `hooks = true` under `[features]` by hand.
        case needsManualStep
    }

    private struct Target {
        let provider: AgentProvider
        let settingsURL: URL
        let registration: HookSettings.Registration
    }

    private let targets: [Target]
    private let codexConfigURL: URL?

    /// `~/.claude/settings.json` by default; tests pass their own files.
    init(settingsURL: URL? = nil, codexHooksURL: URL? = nil, codexConfigURL: URL? = nil, geminiSettingsURL: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        targets = [
            Target(
                provider: .claude,
                settingsURL: settingsURL ?? home.appendingPathComponent(".claude/settings.json"),
                registration: .permissionRequest
            ),
            Target(
                provider: .codex,
                settingsURL: codexHooksURL ?? home.appendingPathComponent(".codex/hooks.json"),
                registration: .permissionRequest
            ),
            Target(
                provider: .gemini,
                settingsURL: geminiSettingsURL ?? home.appendingPathComponent(".gemini/settings.json"),
                registration: .geminiNotification
            )
        ]
        self.codexConfigURL = codexConfigURL ?? home.appendingPathComponent(".codex/config.toml")
    }

    var settingsURL: URL { targets[0].settingsURL }

    /// Absolute path to the bundled `squish-hook` executable, sitting next to the
    /// app binary in both `swift run` and packaged `.app` layouts.
    func hookCommandPath() -> String {
        let base = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "").deletingLastPathComponent()
        return base.appendingPathComponent("squish-hook").path
    }

    func isInstalled() -> Bool {
        status(for: .claude) == .installed
    }

    func status(for provider: AgentProvider) -> Status {
        guard let target = targets.first(where: { $0.provider == provider }) else { return .agentNotFound }
        guard agentIsPresent(target) else { return .agentNotFound }
        guard HookSettings.installed(in: loadSettings(target.settingsURL), command: hookCommandPath(), registration: target.registration) else {
            return .notInstalled
        }
        if provider == .codex, let codexConfigURL,
           let config = try? String(contentsOf: codexConfigURL, encoding: .utf8),
           !CodexConfig.hooksEnabled(in: config) {
            return .needsManualStep
        }
        return .installed
    }

    /// Installs the hook for every agent present. Throws the first write error after trying
    /// them all, so one agent's broken file does not block the others.
    func install() throws {
        var firstError: Error?
        for target in targets where agentIsPresent(target) {
            do {
                let current = loadSettings(target.settingsURL)
                backupIfNeeded(target.settingsURL)
                let updated = HookSettings.installing(hookCommandPath(), into: current, registration: target.registration)
                try writeSettings(updated, to: target.settingsURL)
                if target.provider == .codex { try enableCodexHooks() }
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    func uninstall() throws {
        var firstError: Error?
        for target in targets where FileManager.default.fileExists(atPath: target.settingsURL.path) {
            do {
                let current = loadSettings(target.settingsURL)
                let updated = HookSettings.removing(hookCommandPath(), from: current, registration: target.registration)
                try writeSettings(updated, to: target.settingsURL)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
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

    // MARK: - Codex

    private func enableCodexHooks() throws {
        guard let codexConfigURL else { return }
        let current = (try? String(contentsOf: codexConfigURL, encoding: .utf8)) ?? ""
        guard let updated = CodexConfig.enablingHooks(in: current), updated != current else { return }
        backupIfNeeded(codexConfigURL)
        try updated.write(to: codexConfigURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Settings IO

    private func agentIsPresent(_ target: Target) -> Bool {
        FileManager.default.fileExists(atPath: target.settingsURL.deletingLastPathComponent().path)
    }

    private func loadSettings(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func writeSettings(_ settings: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    private func backupIfNeeded(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let backup = url.appendingPathExtension("squish-backup")
        // Only create a backup once so we always keep the pre-Squish original.
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: url, to: backup)
    }
}
