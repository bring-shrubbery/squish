import Foundation

/// Something an agent told its hook that Squish only needs to hear about once: the turn
/// finished, or the agent is waiting for the user. Unlike a `PendingRequest`, nothing is
/// answered; the hook writes the event and returns at once.
///
/// This is the on-disk wire format shared between the app and `squish-hook`.
public struct AgentEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// The agent finished its turn and is waiting for the next prompt.
        case finished
        /// The agent is waiting for the user: a permission prompt, a question, or idle.
        case waiting
    }

    public let id: String
    public let sessionId: String
    public let cwd: String
    public let kind: Kind
    /// What the agent said, cut short: the end of its last message, or the prompt text.
    public let message: String?
    public let tty: String?
    public let pid: Int?
    public let ppid: Int?
    public let createdAt: Date

    public init(
        id: String,
        sessionId: String,
        cwd: String,
        kind: Kind,
        message: String?,
        tty: String?,
        pid: Int?,
        ppid: Int?,
        createdAt: Date
    ) {
        self.id = id
        self.sessionId = sessionId
        self.cwd = cwd
        self.kind = kind
        self.message = message
        self.tty = tty
        self.pid = pid
        self.ppid = ppid
        self.createdAt = createdAt
    }

    /// The agent the event came from, from the session id's prefix.
    public var provider: AgentProvider {
        if sessionId.hasPrefix("codex:") { return .codex }
        if sessionId.hasPrefix("gemini:") { return .gemini }
        return .claude
    }

    /// A one-line excerpt of a message for a notification body: whitespace collapsed, the
    /// first `limit` characters, with an ellipsis when cut.
    public static func excerpt(_ text: String?, limit: Int = 160) -> String? {
        guard let text else { return nil }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
