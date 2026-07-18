import Foundation

/// Live status of an agent chat, derived from log recency and pending requests.
public enum LiveStatus: Sendable, Equatable {
    /// Streaming / very recently wrote to its log.
    case working
    /// Blocked on a pending permission or question.
    case waiting
    /// Active within the window but not currently writing.
    case idle
}

/// A session surfaced in the live-chats notch, paired with its status.
public struct LiveChat: Identifiable, Sendable, Equatable {
    public let session: CodingSession
    public let status: LiveStatus
    public var id: String { session.id }

    public init(session: CodingSession, status: LiveStatus) {
        self.session = session
        self.status = status
    }
}

/// Derives the list of live chats to display from sessions + pending requests.
public enum LiveActivity {
    public static func chats(
        sessions: [CodingSession],
        pending: [PendingRequest],
        activeWindow: TimeInterval = 90,
        workingWindow: TimeInterval = 8,
        now: Date = Date()
    ) -> [LiveChat] {
        let waitingSessionIDs = Set(pending.map(\.sessionId))

        let chats = sessions.compactMap { session -> LiveChat? in
            guard !session.isSubagent else { return nil }
            let isWaiting = waitingSessionIDs.contains(session.id)
            let age = now.timeIntervalSince(session.updatedAt)
            guard isWaiting || age <= activeWindow else { return nil }

            let status: LiveStatus
            if isWaiting {
                status = .waiting
            } else if age <= workingWindow {
                status = .working
            } else {
                status = .idle
            }
            return LiveChat(session: session, status: status)
        }

        return chats.sorted { lhs, rhs in
            if (lhs.status == .waiting) != (rhs.status == .waiting) {
                return lhs.status == .waiting
            }
            return lhs.session.updatedAt > rhs.session.updatedAt
        }
    }
}
