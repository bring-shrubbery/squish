import Foundation
import XCTest
@testable import SquishCore

final class CostLedgerStoreTests: XCTestCase {
    func testLegacyWholeSessionCostMigratesToDailyBucket() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let ledgerDirectory = root.appendingPathComponent("ledger", isDirectory: true)
        try FileManager.default.createDirectory(at: ledgerDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = makeSession(projectPath: root.path)
        let entry = CostLedgerEntry(
            session: session,
            cost: session.cost(),
            pricingEffectiveDate: PricingCatalog.current.effectiveDate
        )
        let encoded = try JSONEncoder().encode(entry)
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "dailyCosts")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        try legacyData.write(to: ledgerDirectory.appendingPathComponent("legacy.json"))

        let ledger = CostLedgerStore(directory: ledgerDirectory)
        let loadedEntries = await ledger.entries(projectRoot: root)
        let loaded = try XCTUnwrap(loadedEntries.first)
        XCTAssertEqual(loaded.dailyCosts.count, 1)
        XCTAssertEqual(loaded.dailyCosts.first?.cost, loaded.cost)
    }

    func testLedgerRetainsCostAfterSourceSessionDisappears() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let ledgerDirectory = root.appendingPathComponent("ledger", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = makeSession(projectPath: root.appendingPathComponent("project").path)
        let ledger = CostLedgerStore(directory: ledgerDirectory)
        let recorded = await ledger.merge(sessions: [session], projectRoot: root)
        let expectedCost = try XCTUnwrap(recorded.first?.cost?.total)
        XCTAssertGreaterThan(expectedCost, 0)

        let afterDeletion = await ledger.merge(sessions: [], projectRoot: root)
        XCTAssertEqual(afterDeletion.count, 1)
        XCTAssertEqual(afterDeletion.first?.cost?.total, expectedCost)

        let reloadedLedger = CostLedgerStore(directory: ledgerDirectory)
        let reloaded = await reloadedLedger.entries(projectRoot: root)
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.session.id, session.id)
        XCTAssertEqual(reloaded.first?.cost?.total, expectedCost)
    }

    func testLedgerUpdatesCostOnlyWhenSessionUsageChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ledger = CostLedgerStore(directory: root.appendingPathComponent("ledger"))
        let dayOne = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-09T12:00:00Z"))
        let dayTwo = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-10T12:00:00Z"))
        let original = makeSession(projectPath: root.path, inputTokens: 1_000, updatedAt: dayOne)
        let firstEntries = await ledger.merge(sessions: [original], projectRoot: root)
        let first = try XCTUnwrap(firstEntries.first)
        let cachedDayOneCost = try XCTUnwrap(first.dailyCosts.first?.cost)
        let unchangedEntries = await ledger.merge(sessions: [original], projectRoot: root)
        let unchanged = try XCTUnwrap(unchangedEntries.first)
        XCTAssertEqual(unchanged, first)

        let updated = makeSession(projectPath: root.path, inputTokens: 2_000, updatedAt: dayTwo)
        let refreshedEntries = await ledger.merge(sessions: [updated], projectRoot: root)
        let refreshed = try XCTUnwrap(refreshedEntries.first)
        XCTAssertGreaterThan(try XCTUnwrap(refreshed.cost?.total), try XCTUnwrap(first.cost?.total))
        XCTAssertEqual(refreshed.dailyCosts.count, 2)
        XCTAssertEqual(refreshed.dailyCosts.first?.cost, cachedDayOneCost)
        XCTAssertEqual(
            refreshed.dailyCosts.reduce(.zero) { $0 + $1.cost }.total,
            try XCTUnwrap(refreshed.cost?.total),
            accuracy: 0.000_000_1
        )

        let sameDayUpdate = makeSession(projectPath: root.path, inputTokens: 3_000, updatedAt: dayTwo)
        let sameDayEntries = await ledger.merge(sessions: [sameDayUpdate], projectRoot: root)
        let sameDayRefreshed = try XCTUnwrap(sameDayEntries.first)
        XCTAssertEqual(sameDayRefreshed.dailyCosts.count, 2)
        XCTAssertEqual(sameDayRefreshed.dailyCosts.first?.cost, cachedDayOneCost)
    }

    private func makeSession(
        projectPath: String,
        inputTokens: Int = 1_000,
        updatedAt: Date? = nil
    ) -> CodingSession {
        CodingSession(
            id: "codex:ledger-test",
            provider: .codex,
            title: "Ledger test",
            projectPath: projectPath,
            model: "gpt-5.4",
            usage: TokenUsage(inputTokens: inputTokens, cachedReadTokens: 500, outputTokens: 250),
            contextTokens: inputTokens,
            contextWindow: 100_000,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: updatedAt ?? Date(timeIntervalSince1970: TimeInterval(100 + inputTokens)),
            logPath: "/tmp/ledger-test.jsonl"
        )
    }
}
