import Foundation
import XCTest
@testable import SquishCore

final class RequestSpoolTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func tempSpool() throws -> RequestSpool {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("squish-spool-\(UUID().uuidString)")
        roots.append(dir)
        let spool = RequestSpool(root: dir)
        try spool.ensureDirectories()
        return spool
    }

    private func sampleRequest(id: String, createdAt: Date = Date()) -> PendingRequest {
        PendingRequest(id: id, sessionId: "claude:s", cwd: "/tmp/p", kind: .permission,
                       toolName: "Bash", inputSummary: "ls", options: nil,
                       tty: nil, pid: nil, ppid: nil, createdAt: createdAt)
    }

    func testWriteAndReadPending() throws {
        let spool = try tempSpool()
        try spool.writeRequest(sampleRequest(id: "r1"))
        XCTAssertEqual(spool.pendingRequests().map(\.id), ["r1"])
    }

    func testDecisionRoundTripAndClear() throws {
        let spool = try tempSpool()
        try spool.writeRequest(sampleRequest(id: "r1"))
        try spool.writeDecision(.deny, for: "r1")
        XCTAssertEqual(spool.readDecision(for: "r1"), .deny)
        spool.clearRequest(id: "r1")
        XCTAssertNil(spool.readDecision(for: "r1"))
        XCTAssertTrue(spool.pendingRequests().isEmpty)
    }

    func testDecidedRequestsAreNotPending() throws {
        let spool = try tempSpool()
        try spool.writeRequest(sampleRequest(id: "r1"))
        try spool.writeDecision(.allow, for: "r1")
        XCTAssertTrue(spool.pendingRequests().isEmpty)
    }

    func testPendingSortedByCreatedAt() throws {
        let spool = try tempSpool()
        let now = Date(timeIntervalSince1970: 10_000)
        try spool.writeRequest(sampleRequest(id: "second", createdAt: now.addingTimeInterval(10)))
        try spool.writeRequest(sampleRequest(id: "first", createdAt: now))
        XCTAssertEqual(spool.pendingRequests().map(\.id), ["first", "second"])
    }

    func testCleanupStale() throws {
        let spool = try tempSpool()
        let now = Date(timeIntervalSince1970: 10_000)
        try spool.writeRequest(sampleRequest(id: "old", createdAt: now.addingTimeInterval(-1000)))
        try spool.writeRequest(sampleRequest(id: "new", createdAt: now.addingTimeInterval(-10)))
        spool.cleanupStale(olderThan: 900, now: now)
        XCTAssertEqual(spool.pendingRequests().map(\.id), ["new"])
    }

    func testHeartbeatFreshness() throws {
        let spool = try tempSpool()
        let now = Date(timeIntervalSince1970: 10_000)
        try spool.writeHeartbeat(pid: 5, monitoredRoot: "/tmp/p", now: now)
        XCTAssertTrue(spool.heartbeatIsFresh(maxAge: 15, now: now.addingTimeInterval(5)))
        XCTAssertFalse(spool.heartbeatIsFresh(maxAge: 15, now: now.addingTimeInterval(60)))
        XCTAssertEqual(spool.readHeartbeat()?.pid, 5)
        XCTAssertEqual(spool.readHeartbeat()?.monitoredRoot, "/tmp/p")
    }

    func testMissingHeartbeatIsNotFresh() throws {
        let spool = try tempSpool()
        XCTAssertFalse(spool.heartbeatIsFresh(maxAge: 15, now: Date()))
        XCTAssertNil(spool.readHeartbeat())
    }
}

final class AgentEventSpoolTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func tempSpool() throws -> RequestSpool {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("squish-spool-\(UUID().uuidString)")
        roots.append(dir)
        let spool = RequestSpool(root: dir)
        try spool.ensureDirectories()
        return spool
    }

    private func event(_ id: String, kind: AgentEvent.Kind = .finished, createdAt: Date = Date()) -> AgentEvent {
        AgentEvent(id: id, sessionId: "codex:s", cwd: "/tmp/p", kind: kind, message: "done",
                   tty: "/dev/ttys001", pid: 1, ppid: 2, createdAt: createdAt)
    }

    func testEventsRoundTripOldestFirstAndClear() throws {
        let spool = try tempSpool()
        let now = Date(timeIntervalSince1970: 10_000)
        try spool.writeEvent(event("later", createdAt: now.addingTimeInterval(5)))
        try spool.writeEvent(event("first", kind: .waiting, createdAt: now))
        let events = spool.pendingEvents()
        XCTAssertEqual(events.map(\.id), ["first", "later"])
        XCTAssertEqual(events.first?.kind, .waiting)
        XCTAssertEqual(events.first?.provider, .codex)
        XCTAssertEqual(events.first?.message, "done")
        spool.clearEvent(id: "first")
        XCTAssertEqual(spool.pendingEvents().map(\.id), ["later"])
    }

    func testStaleEventsAreSweptAndGarbageDropped() throws {
        let spool = try tempSpool()
        let now = Date(timeIntervalSince1970: 10_000)
        try spool.writeEvent(event("old", createdAt: now.addingTimeInterval(-1000)))
        try spool.writeEvent(event("new", createdAt: now.addingTimeInterval(-10)))
        try Data("not json".utf8).write(to: spool.eventsDirectory.appendingPathComponent("junk.json"))
        spool.cleanupStaleEvents(olderThan: 600, now: now)
        XCTAssertEqual(spool.pendingEvents().map(\.id), ["new"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.eventsDirectory.appendingPathComponent("junk.json").path))
    }

    func testExcerptCollapsesWhitespaceAndCuts() {
        XCTAssertNil(AgentEvent.excerpt(nil))
        XCTAssertNil(AgentEvent.excerpt("  \n "))
        XCTAssertEqual(AgentEvent.excerpt("Done.\n\nAll  tests pass."), "Done. All tests pass.")
        let long = String(repeating: "word ", count: 60)
        let cut = AgentEvent.excerpt(long, limit: 40)!
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertLessThanOrEqual(cut.count, 40)
    }
}
