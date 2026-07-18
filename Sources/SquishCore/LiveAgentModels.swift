import Foundation

/// The kind of interaction a live agent is requesting.
public enum RequestKind: String, Codable, Sendable {
    /// A tool-permission prompt that resolves to allow / deny.
    case permission
    /// A free-text or multiple-choice question.
    case question
}

/// A request written by the Claude Code hook and awaiting a decision from Squish.
///
/// This is the on-disk wire format shared verbatim between the app and the
/// bundled `squish-hook` executable, so both sides encode/decode the same type.
public struct PendingRequest: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionId: String
    public let cwd: String
    public let kind: RequestKind
    public let toolName: String
    public let inputSummary: String
    public let options: [String]?
    public let tty: String?
    public let pid: Int?
    public let ppid: Int?
    public let createdAt: Date

    public init(
        id: String,
        sessionId: String,
        cwd: String,
        kind: RequestKind,
        toolName: String,
        inputSummary: String,
        options: [String]?,
        tty: String?,
        pid: Int?,
        ppid: Int?,
        createdAt: Date
    ) {
        self.id = id
        self.sessionId = sessionId
        self.cwd = cwd
        self.kind = kind
        self.toolName = toolName
        self.inputSummary = inputSummary
        self.options = options
        self.tty = tty
        self.pid = pid
        self.ppid = ppid
        self.createdAt = createdAt
    }
}

/// The user's answer to a `PendingRequest`.
public enum AgentDecision: Equatable, Sendable {
    case allow
    case deny
    case alwaysAllow
    case answer(String)

    private struct Wire: Codable {
        let decision: String
        let text: String?
    }

    private var wire: Wire {
        switch self {
        case .allow: Wire(decision: "allow", text: nil)
        case .deny: Wire(decision: "deny", text: nil)
        case .alwaysAllow: Wire(decision: "alwaysAllow", text: nil)
        case let .answer(text): Wire(decision: "answer", text: text)
        }
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(wire)) ?? Data()
    }

    public static func decode(_ data: Data) -> AgentDecision? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        switch wire.decision {
        case "allow": return .allow
        case "deny": return .deny
        case "alwaysAllow": return .alwaysAllow
        case "answer": return .answer(wire.text ?? "")
        default: return nil
        }
    }
}

/// Builds the JSON a `PermissionRequest` hook prints to stdout so Claude Code
/// applies the user's decision.
///
/// `PermissionRequest` fires only when Claude would actually show the user a
/// permission dialog — never for tools auto-approved by the session's permission
/// mode — so the notch only ever surfaces genuine decisions. Its output carries a
/// nested `decision.behavior` of `allow` or `deny` (there is no free-text channel,
/// so typed answers collapse to `deny`).
public enum ClaudeHookResponse {
    public static let eventName = "PermissionRequest"

    public static func json(for decision: AgentDecision) -> String {
        switch decision {
        case .allow, .alwaysAllow:
            return payload(behavior: "allow")
        case .deny, .answer:
            return payload(behavior: "deny")
        }
    }

    private static func payload(behavior: String) -> String {
        "{\"hookSpecificOutput\":{\"hookEventName\":\"\(eventName)\"," +
            "\"decision\":{\"behavior\":\"\(behavior)\"}}}"
    }
}
