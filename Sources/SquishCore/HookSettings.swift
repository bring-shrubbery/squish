import Foundation

/// Pure merge/unmerge of Squish's `PreToolUse` hook into a decoded Claude Code
/// `settings.json` dictionary. Never clobbers the user's other hooks; the Squish
/// hook is identified by its command path.
public enum HookSettings {
    private static let matcherAll = "*"
    private static let hookTimeout = 310

    /// True if a command hook with `command` is present under any `PreToolUse` matcher.
    public static func installed(in settings: [String: Any], command: String) -> Bool {
        for matcher in preToolUse(in: settings) {
            if commandHooks(in: matcher).contains(where: { $0["command"] as? String == command }) {
                return true
            }
        }
        return false
    }

    /// Returns a copy of `settings` with the Squish hook merged in (idempotent).
    public static func installing(_ command: String, into settings: [String: Any]) -> [String: Any] {
        guard !installed(in: settings, command: command) else { return settings }

        var result = settings
        var hooks = dictionary(result["hooks"]) ?? [:]
        var preToolUse = dictionaries(hooks["PreToolUse"])
        let commandHook: [String: Any] = ["type": "command", "command": command, "timeout": hookTimeout]

        if let index = preToolUse.firstIndex(where: { ($0["matcher"] as? String) == matcherAll }) {
            var matcher = preToolUse[index]
            var matcherHooks = dictionaries(matcher["hooks"])
            matcherHooks.append(commandHook)
            matcher["hooks"] = matcherHooks
            preToolUse[index] = matcher
        } else {
            preToolUse.append(["matcher": matcherAll, "hooks": [commandHook]])
        }

        hooks["PreToolUse"] = preToolUse
        result["hooks"] = hooks
        return result
    }

    /// Returns a copy of `settings` with only the Squish hook removed, pruning any
    /// containers left empty.
    public static func removing(_ command: String, from settings: [String: Any]) -> [String: Any] {
        guard var hooks = dictionary(settings["hooks"]) else { return settings }
        var preToolUse = dictionaries(hooks["PreToolUse"])
        guard !preToolUse.isEmpty else { return settings }

        preToolUse = preToolUse.compactMap { matcher -> [String: Any]? in
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
        if preToolUse.isEmpty {
            hooks.removeValue(forKey: "PreToolUse")
        } else {
            hooks["PreToolUse"] = preToolUse
        }
        if hooks.isEmpty {
            result.removeValue(forKey: "hooks")
        } else {
            result["hooks"] = hooks
        }
        return result
    }

    // MARK: - Internals

    private static func preToolUse(in settings: [String: Any]) -> [[String: Any]] {
        dictionaries(dictionary(settings["hooks"])?["PreToolUse"])
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
