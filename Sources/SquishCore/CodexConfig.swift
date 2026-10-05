import Foundation

/// The one edit Squish makes to `~/.codex/config.toml`: `hooks = true` under `[features]`,
/// which Codex needs before it reads `hooks.json`. Line-based on purpose: the file is the
/// user's, and anything beyond that line is left exactly as written.
public enum CodexConfig {
    /// `text` with hooks enabled, or nil when the file keeps `features` in a form this does
    /// not rewrite (an inline table), in which case the user enables it by hand.
    public static func enablingHooks(in text: String) -> String? {
        if hooksEnabled(in: text) { return text }
        var lines = text.components(separatedBy: "\n")

        // `features = { ... }`: editing inside an inline table is not worth the risk.
        if lines.contains(where: { $0.range(of: #"^\s*features\s*=\s*\{"#, options: .regularExpression) != nil }) {
            return nil
        }

        // A dotted key at the top level: `features.hooks = false`.
        if let index = lines.firstIndex(where: { $0.range(of: #"^\s*features\.hooks\s*="#, options: .regularExpression) != nil }) {
            lines[index] = "features.hooks = true"
            return lines.joined(separator: "\n")
        }

        // A [features] table: set or add the key inside it.
        if let header = lines.firstIndex(where: { $0.range(of: #"^\s*\[features\]\s*(#.*)?$"#, options: .regularExpression) != nil }) {
            var index = header + 1
            while index < lines.count, lines[index].range(of: #"^\s*\["#, options: .regularExpression) == nil {
                if lines[index].range(of: #"^\s*hooks\s*="#, options: .regularExpression) != nil {
                    lines[index] = "hooks = true"
                    return lines.joined(separator: "\n")
                }
                index += 1
            }
            lines.insert("hooks = true", at: header + 1)
            return lines.joined(separator: "\n")
        }

        // No features table yet: add one at the end.
        var result = text
        if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        if !result.isEmpty { result += "\n" }
        return result + "[features]\nhooks = true\n"
    }

    public static func hooksEnabled(in text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        if lines.contains(where: { $0.range(of: #"^\s*features\.hooks\s*=\s*true\b"#, options: .regularExpression) != nil }) {
            return true
        }
        if lines.contains(where: { $0.range(of: #"^\s*features\s*=\s*\{.*\bhooks\s*=\s*true\b"#, options: .regularExpression) != nil }) {
            return true
        }
        guard let header = lines.firstIndex(where: { $0.range(of: #"^\s*\[features\]\s*(#.*)?$"#, options: .regularExpression) != nil }) else {
            return false
        }
        var index = header + 1
        while index < lines.count, lines[index].range(of: #"^\s*\["#, options: .regularExpression) == nil {
            if lines[index].range(of: #"^\s*hooks\s*=\s*true\b"#, options: .regularExpression) != nil { return true }
            index += 1
        }
        return false
    }
}
