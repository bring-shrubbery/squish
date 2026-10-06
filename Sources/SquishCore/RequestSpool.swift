import Foundation

/// File-based rendezvous between the agents' hooks and Squish.
///
/// The hook writes a `PendingRequest` into `requests/<id>.json` and blocks
/// polling for `requests/<id>.decision.json`; Squish watches the directory,
/// shows the notch, and writes the decision back. One-way news (`AgentEvent`) goes
/// into `events/<id>.json`, which Squish reads and removes. A heartbeat file lets the
/// hook detect whether Squish is actually listening before it ever blocks.
public struct RequestSpool: Sendable {
    /// How long the hook waits for a decision before falling back to Claude's
    /// native prompt.
    public static let decisionTimeout: TimeInterval = 300
    /// Requests older than this are considered abandoned and swept.
    public static let staleRequestAge: TimeInterval = 900
    /// Maximum heartbeat age for Squish to be considered present.
    public static let heartbeatMaxAge: TimeInterval = 15

    public let root: URL

    public var requestsDirectory: URL { root.appendingPathComponent("requests", isDirectory: true) }
    public var eventsDirectory: URL { root.appendingPathComponent("events", isDirectory: true) }
    public var heartbeatURL: URL { root.appendingPathComponent("heartbeat", isDirectory: false) }

    public init(root: URL) {
        self.root = root
    }

    /// The default spool location: `~/.squish/live`.
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".squish", isDirectory: true)
            .appendingPathComponent("live", isDirectory: true)
    }

    public func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: requestsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Requests

    public func writeRequest(_ request: PendingRequest) throws {
        let data = try encoder.encode(request)
        try data.write(to: requestURL(for: request.id), options: .atomic)
    }

    public func pendingRequests() -> [PendingRequest] {
        requestFiles()
            .compactMap { url -> PendingRequest? in
                guard !FileManager.default.fileExists(atPath: decisionURL(for: idFromRequestURL(url)).path),
                      let data = try? Data(contentsOf: url),
                      let request = try? decoder.decode(PendingRequest.self, from: data)
                else { return nil }
                return request
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func clearRequest(id: String) {
        try? FileManager.default.removeItem(at: requestURL(for: id))
        try? FileManager.default.removeItem(at: decisionURL(for: id))
    }

    public func cleanupStale(olderThan seconds: TimeInterval, now: Date = Date()) {
        for url in requestFiles() {
            guard let data = try? Data(contentsOf: url),
                  let request = try? decoder.decode(PendingRequest.self, from: data) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if now.timeIntervalSince(request.createdAt) > seconds {
                clearRequest(id: request.id)
            }
        }
    }

    // MARK: - Events

    public func writeEvent(_ event: AgentEvent) throws {
        let data = try encoder.encode(event)
        try data.write(to: eventURL(for: event.id), options: .atomic)
    }

    /// Every event not yet taken, oldest first. Unreadable files are dropped.
    public func pendingEvents() -> [AgentEvent] {
        eventFiles()
            .compactMap { url -> AgentEvent? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                guard let event = try? decoder.decode(AgentEvent.self, from: data) else {
                    try? FileManager.default.removeItem(at: url)
                    return nil
                }
                return event
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func clearEvent(id: String) {
        try? FileManager.default.removeItem(at: eventURL(for: id))
    }

    /// Drops events nobody took in time, for instance ones written while no app was reading.
    public func cleanupStaleEvents(olderThan seconds: TimeInterval, now: Date = Date()) {
        for event in pendingEvents() where now.timeIntervalSince(event.createdAt) > seconds {
            clearEvent(id: event.id)
        }
    }

    // MARK: - Decisions

    public func writeDecision(_ decision: AgentDecision, for id: String) throws {
        try decision.encoded().write(to: decisionURL(for: id), options: .atomic)
    }

    public func readDecision(for id: String) -> AgentDecision? {
        guard let data = try? Data(contentsOf: decisionURL(for: id)) else { return nil }
        return AgentDecision.decode(data)
    }

    // MARK: - Heartbeat

    public struct Heartbeat: Codable, Equatable, Sendable {
        public let pid: Int
        public let monitoredRoot: String
        public let timestamp: Date
    }

    public func writeHeartbeat(pid: Int, monitoredRoot: String, now: Date = Date()) throws {
        let beat = Heartbeat(pid: pid, monitoredRoot: monitoredRoot, timestamp: now)
        try encoder.encode(beat).write(to: heartbeatURL, options: .atomic)
    }

    public func readHeartbeat() -> Heartbeat? {
        guard let data = try? Data(contentsOf: heartbeatURL) else { return nil }
        return try? decoder.decode(Heartbeat.self, from: data)
    }

    public func heartbeatIsFresh(maxAge: TimeInterval, now: Date = Date()) -> Bool {
        guard let beat = readHeartbeat() else { return false }
        return now.timeIntervalSince(beat.timestamp) <= maxAge
    }

    public func removeHeartbeat() {
        try? FileManager.default.removeItem(at: heartbeatURL)
    }

    // MARK: - Internals

    private func requestURL(for id: String) -> URL {
        requestsDirectory.appendingPathComponent("\(id).json", isDirectory: false)
    }

    private func decisionURL(for id: String) -> URL {
        requestsDirectory.appendingPathComponent("\(id).decision.json", isDirectory: false)
    }

    private func eventURL(for id: String) -> URL {
        eventsDirectory.appendingPathComponent("\(id).json", isDirectory: false)
    }

    private func eventFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: eventsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter { $0.pathExtension == "json" }
    }

    private func idFromRequestURL(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private func requestFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: requestsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".decision.json") }
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
