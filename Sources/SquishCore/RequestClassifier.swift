import Foundation

/// Classifies a Claude Code tool request into a permission vs. a question, and
/// extracts a human-readable summary + any answer options.
///
/// Built-in question tools (e.g. `AskUserQuestion`) arrive through the same
/// `PermissionRequest` hook as ordinary tool permissions, but should be shown as
/// a question with selectable options rather than a raw allow/deny of JSON.
public enum RequestClassifier {
    /// Tool names that represent a question to the user rather than a permission.
    public static let questionTools: Set<String> = ["AskUserQuestion"]

    public struct Classification: Equatable, Sendable {
        public let kind: RequestKind
        public let summary: String
        public let options: [String]?

        public init(kind: RequestKind, summary: String, options: [String]?) {
            self.kind = kind
            self.summary = summary
            self.options = options
        }
    }

    public static func classify(toolName: String, toolInput: [String: Any]?) -> Classification {
        if questionTools.contains(toolName), let input = toolInput {
            return classifyQuestion(input)
        }
        return Classification(
            kind: .permission,
            summary: permissionSummary(toolName: toolName, toolInput: toolInput),
            options: nil
        )
    }

    // MARK: - Questions

    private static func classifyQuestion(_ input: [String: Any]) -> Classification {
        let questions = (input["questions"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        guard let first = questions.first else {
            return Classification(kind: .question, summary: "Question", options: nil)
        }

        let text = (first["question"] as? String)
            ?? (first["header"] as? String)
            ?? "Question"
        let extra = questions.count > 1 ? " (+\(questions.count - 1) more)" : ""

        let options = (first["options"] as? [Any])?
            .compactMap { ($0 as? [String: Any])?["label"] as? String }
        let cleanedOptions = (options?.isEmpty == true) ? nil : options

        return Classification(kind: .question, summary: text + extra, options: cleanedOptions)
    }

    // MARK: - Permissions

    private static func permissionSummary(toolName: String, toolInput: [String: Any]?) -> String {
        guard let dict = toolInput else { return toolName }
        for key in ["command", "file_path", "path", "url", "pattern", "description", "prompt"] {
            if let value = dict[key] as? String, !value.isEmpty {
                return String(value.replacingOccurrences(of: "\n", with: " ").prefix(200))
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) {
            return String(json.prefix(200))
        }
        return toolName
    }
}
