import ApplicationServices
import Foundation
import SquishCore

/// Installs and removes Squish's hook in each agent's settings, and manages the
/// Accessibility permission the keystroke write-path needs.
///
/// - Claude Code: `~/.claude/settings.json`: `PermissionRequest` for live chats; `Stop` and
///   `Notification` for notifications.
/// - Codex: `~/.codex/hooks.json`: `PermissionRequest` and `Stop`, plus `hooks = true`
///   under `[features]` in `~/.codex/config.toml`, which Codex needs before it reads hooks.
/// - Gemini CLI: `~/.gemini/settings.json`: `Notification`, which only reports waiting, for
///   either feature; `AfterAgent` for notifications.
///
/// Each feature wants some registrations; `sync` makes every present agent's file carry
/// exactly the union. All settings mutation goes through the pure `HookSettings` merge, so a
/// malformed or unexpected file is never clobbered: it is backed up first and only the
/// Squish hook blocks are added or removed. An agent whose folder does not exist is left alone.
@MainActor
final class HookInstaller {
    /// What the hook is installed for.
    enum Feature: Hashable {
        /// Permission prompts and questions answered from the notch.
        case liveChats
        /// Finished and waiting notifications.
        case notifications
    }

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
    }

    /// The registrations a provider's file should carry for these features.
    static func registrations(for provider: AgentProvider, features: Set<Feature>) -> [HookSettings.Registration] {
        var result: [HookSettings.Registration] = []
        switch provider {
        case .claude:
            if features.contains(.liveChats) { result.append(.permissionRequest) }
            if features.contains(.notifications) { result += [.claudeStop, .claudeNotification] }
        case .codex:
            if features.contains(.liveChats) { result.append(.permissionRequest) }
            if features.contains(.notifications) { result.append(.codexStop) }
        case .gemini:
            if !features.isEmpty { result.append(.geminiNotification) }
            if features.contains(.notifications) { result.append(.geminiAfterAgent) }
        }
        return result
    }

    private let targets: [Target]
    private let codexConfigURL: URL?

    /// `~/.claude/settings.json` by default; tests pass their own files.
    init(settingsURL: URL? = nil, codexHooksURL: URL? = nil, codexConfigURL: URL? = nil, geminiSettingsURL: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        targets = [
            Target(provider: .claude, settingsURL: settingsURL ?? home.appendingPathComponent(".claude/settings.json")),
            Target(provider: .codex, settingsURL: codexHooksURL ?? home.appendingPathComponent(".codex/hooks.json")),
            Target(provider: .gemini, settingsURL: geminiSettingsURL ?? home.appendingPathComponent(".gemini/settings.json"))
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

    /// Whether the live-chats hook is in Claude Code's settings.
    func isInstalled() -> Bool {
        status(for: .claude, features: [.liveChats]) == .installed
    }

    /// Whether the provider's file carries everything `features` want.
    func status(for provider: AgentProvider, features: Set<Feature>) -> Status {
        guard let target = targets.first(where: { $0.provider == provider }) else { return .agentNotFound }
        guard agentIsPresent(target) else { return .agentNotFound }
        let wanted = Self.registrations(for: provider, features: features)
        guard !wanted.isEmpty else { return .notInstalled }
        let settings = loadSettings(target.settingsURL)
        let command = hookCommandPath()
        guard wanted.allSatisfy({ HookSettings.installed(in: settings, command: command, registration: $0) }) else {
            return .notInstalled
        }
        if provider == .codex, let codexConfigURL,
           let config = try? String(contentsOf: codexConfigURL, encoding: .utf8),
           !CodexConfig.hooksEnabled(in: config) {
            return .needsManualStep
        }
        return .installed
    }

    /// Makes every present agent's file carry exactly the registrations `features` want,
    /// removing the rest. With no features, every Squish hook goes. Throws the first write
    /// error after trying them all, so one agent's broken file does not block the others.
    func sync(features: Set<Feature>) throws {
        var firstError: Error?
        let command = hookCommandPath()
        for target in targets {
            let wanted = Self.registrations(for: target.provider, features: features)
            // An absent agent is left alone, unless its file still has our hooks to remove.
            let fileExists = FileManager.default.fileExists(atPath: target.settingsURL.path)
            guard agentIsPresent(target) || (fileExists && wanted.isEmpty) else { continue }
            if wanted.isEmpty && !fileExists { continue }
            do {
                let current = loadSettings(target.settingsURL)
                var updated = current
                for registration in HookSettings.Registration.all(for: target.provider) where !wanted.contains(registration) {
                    updated = HookSettings.removing(command, from: updated, registration: registration)
                }
                for registration in wanted {
                    updated = HookSettings.installing(command, into: updated, registration: registration)
                }
                if !Self.equal(updated, current) {
                    backupIfNeeded(target.settingsURL)
                    try writeSettings(updated, to: target.settingsURL)
                }
                if target.provider == .codex, !wanted.isEmpty { try enableCodexHooks() }
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    private static func equal(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        guard let a = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
              let b = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys]) else { return false }
        return a == b
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
