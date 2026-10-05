import Foundation

/// Pure merge/unmerge of Squish's `PermissionRequest` hook into a decoded Claude
/// Code `settings.json` dictionary. Never clobbers the user's other hooks; the
/// Squish hook is identified by its command path.
///
/// `PermissionRequest` (not `PreToolUse`) is used deliberately: it fires only when
/// Claude would actually prompt the user, so auto-approved tool calls never reach
/// the notch.
public enum HookSettings {
    /// Where the hook goes in one agent's settings. Claude Code and Codex share the schema
    /// (`PermissionRequest`, timeout in seconds); Gemini CLI only tells us it is waiting
    /// (`Notification`, timeout in milliseconds) and matches everything when no matcher is set.
    public struct Registration: Equatable, Sendable {
        public let event: String
        public let matcher: String?
        public let timeout: Int

        public init(event: String, matcher: String?, timeout: Int) {
            self.event = event
            self.matcher = matcher
            self.timeout = timeout
        }

        /// Claude Code (`~/.claude/settings.json`) and Codex (`~/.codex/hooks.json`).
        public static let permissionRequest = Registration(event: "PermissionRequest", matcher: "*", timeout: 310)
        /// Gemini CLI (`~/.gemini/settings.json`): fires when a tool waits for permission.
        public static let geminiNotification = Registration(event: "Notification", matcher: nil, timeout: 5_000)
    }

    private static let event = Registration.permissionRequest.event

    /// True if a command hook with `command` is present under the registration's event.
    public static func installed(
        in settings: [String: Any],
        command: String,
        registration: Registration = .permissionRequest
    ) -> Bool {
        for matcher in dictionaries(dictionary(settings["hooks"])?[registration.event]) {
            if commandHooks(in: matcher).contains(where: { $0["command"] as? String == command }) {
                return true
            }
        }
        return false
    }

    /// Returns a copy of `settings` with the Squish hook merged in (idempotent).
    public static func installing(
        _ command: String,
        into settings: [String: Any],
        registration: Registration = .permissionRequest
    ) -> [String: Any] {
        // Migrate away any legacy PreToolUse registration of the same command from
        // an older Squish version, which would otherwise intercept every tool call.
        let migrated = removing(command, fromEvent: "PreToolUse", in: settings)
        guard !installed(in: migrated, command: command, registration: registration) else { return migrated }

        var result = migrated
        var hooks = dictionary(result["hooks"]) ?? [:]
        var eventHooks = dictionaries(hooks[registration.event])
        let commandHook: [String: Any] = ["type": "command", "command": command, "timeout": registration.timeout]

        if let index = eventHooks.firstIndex(where: { ($0["matcher"] as? String) == registration.matcher }) {
            var matcher = eventHooks[index]
            var matcherHooks = dictionaries(matcher["hooks"])
            matcherHooks.append(commandHook)
            matcher["hooks"] = matcherHooks
            eventHooks[index] = matcher
        } else if let matcher = registration.matcher {
            eventHooks.append(["matcher": matcher, "hooks": [commandHook]])
        } else {
            eventHooks.append(["hooks": [commandHook]])
        }

        hooks[registration.event] = eventHooks
        result["hooks"] = hooks
        return result
    }

    /// Returns a copy of `settings` with only the Squish hook removed, pruning any
    /// containers left empty.
    public static func removing(
        _ command: String,
        from settings: [String: Any],
        registration: Registration = .permissionRequest
    ) -> [String: Any] {
        removing(command, fromEvent: registration.event, in: settings)
    }

    /// Removes the Squish command hook from a specific event, pruning empties.
    public static func removing(
        _ command: String,
        fromEvent event: String,
        in settings: [String: Any]
    ) -> [String: Any] {
        guard var hooks = dictionary(settings["hooks"]) else { return settings }
        var eventHooks = dictionaries(hooks[event])
        guard !eventHooks.isEmpty else { return settings }

        eventHooks = eventHooks.compactMap { matcher -> [String: Any]? in
            var matcher = matcher
            let filtered = commandHooks(in: matcher).filter { $0["command"] as? String != command }
            // Preserve non-command hooks (e.g. other hook types) as well.
            let nonCommand = dictionaries(matcher["hooks"])
                .filter { ($0["type"] as? String) != "command" }
            let combined = filtered + nonCommand
            if combined.isEmpty { return nil }
            matcher["hooks"] = combined
            return matcher
        }

        var result = settings
        if eventHooks.isEmpty {
            hooks.removeValue(forKey: event)
        } else {
            hooks[event] = eventHooks
        }
        if hooks.isEmpty {
            result.removeValue(forKey: "hooks")
        } else {
            result["hooks"] = hooks
        }
        return result
    }

    // MARK: - Internals

    private static func commandHooks(in matcher: [String: Any]) -> [[String: Any]] {
        dictionaries(matcher["hooks"]).filter { ($0["type"] as? String) == "command" }
    }

    /// Robust cast that tolerates both Swift-native and JSON-deserialized values.
    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func dictionaries(_ value: Any?) -> [[String: Any]] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { $0 as? [String: Any] }
    }
}
