import Foundation

/// Pure merge/unmerge of Squish's `PermissionRequest` hook into a decoded Claude
/// Code `settings.json` dictionary. Never clobbers the user's other hooks; the
/// Squish hook is identified by its command path.
///
/// `PermissionRequest` (not `PreToolUse`) is used deliberately: it fires only when
/// Claude would actually prompt the user, so auto-approved tool calls never reach
/// the notch.
public enum HookSettings {
    private static let event = "PermissionRequest"
    private static let matcherAll = "*"
    private static let hookTimeout = 310

    /// True if a command hook with `command` is present under any `PreToolUse` matcher.
    public static func installed(in settings: [String: Any], command: String) -> Bool {
        for matcher in eventMatchers(in: settings) {
            if commandHooks(in: matcher).contains(where: { $0["command"] as? String == command }) {
                return true
            }
        }
        return false
    }

    /// Returns a copy of `settings` with the Squish hook merged in (idempotent).
    public static func installing(_ command: String, into settings: [String: Any]) -> [String: Any] {
        // Migrate away any legacy PreToolUse registration of the same command from
        // an older Squish version, which would otherwise intercept every tool call.
        let migrated = removing(command, fromEvent: "PreToolUse", in: settings)
        guard !installed(in: migrated, command: command) else { return migrated }

        var result = migrated
        var hooks = dictionary(result["hooks"]) ?? [:]
        var eventHooks = dictionaries(hooks[event])
        let commandHook: [String: Any] = ["type": "command", "command": command, "timeout": hookTimeout]

        if let index = eventHooks.firstIndex(where: { ($0["matcher"] as? String) == matcherAll }) {
            var matcher = eventHooks[index]
            var matcherHooks = dictionaries(matcher["hooks"])
            matcherHooks.append(commandHook)
            matcher["hooks"] = matcherHooks
            eventHooks[index] = matcher
        } else {
            eventHooks.append(["matcher": matcherAll, "hooks": [commandHook]])
        }

        hooks[event] = eventHooks
        result["hooks"] = hooks
        return result
    }

    /// Returns a copy of `settings` with only the Squish hook removed, pruning any
    /// containers left empty.
    public static func removing(_ command: String, from settings: [String: Any]) -> [String: Any] {
        removing(command, fromEvent: event, in: settings)
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

    private static func eventMatchers(in settings: [String: Any]) -> [[String: Any]] {
        dictionaries(dictionary(settings["hooks"])?[event])
    }

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
