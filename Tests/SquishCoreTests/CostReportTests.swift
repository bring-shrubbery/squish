import Foundation
import XCTest
@testable import SquishCore

final class CostReportTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    /// Wednesday 14 Oct 2026, 12:00 UTC.
    private let now = ISO8601DateFormatter().date(from: "2026-10-14T12:00:00Z")!

    private func day(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso + "T00:00:00Z")!
    }

    private func entry(
        id: String,
        project: String = "/p/alpha",
        model: String = "gpt-5.4",
        updatedAt: String,
        days: [(String, Double)],
        priced: Bool = true
    ) -> CostLedgerEntry {
        let session = CodingSession(
            id: id, provider: .codex, title: "Session \(id)", projectPath: project, model: model,
            usage: TokenUsage(inputTokens: 1_000, outputTokens: 100), contextTokens: 1_000, contextWindow: 100_000,
            startedAt: day(updatedAt), updatedAt: day(updatedAt).addingTimeInterval(3_600), logPath: "/l/\(id)"
        )
        let buckets = days.map { DailyCostBucket(day: day($0.0), cost: CostBreakdown(input: $0.1, cacheRead: 0, cacheWrite: 0, output: 0)) }
        let total = buckets.reduce(CostBreakdown.zero) { $0 + $1.cost }
        return CostLedgerEntry(
            session: session,
            cost: priced ? total : nil,
            dailyCosts: priced ? buckets : [],
            pricingEffectiveDate: now
        )
    }

    func testWeekTotalsOnlyCountDaysInsideTheWeekAndCompareWithLastWeek() {
        let entries = [
            // Spans last week and this week.
            entry(id: "a", updatedAt: "2026-10-13", days: [("2026-10-09", 4), ("2026-10-13", 6)]),
            entry(id: "b", project: "/p/beta", updatedAt: "2026-10-12", days: [("2026-10-12", 2)]),
            // Entirely last week.
            entry(id: "c", updatedAt: "2026-10-07", days: [("2026-10-07", 10)])
        ]
        let report = CostReport(entries: entries, period: .week, now: now, calendar: calendar)

        XCTAssertEqual(report.total.total, 8, accuracy: 0.0001)
        XCTAssertEqual(report.previousTotal?.total ?? 0, 14, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(report.changeFromPrevious), (8.0 - 14.0) / 14.0, accuracy: 0.0001)
        XCTAssertEqual(report.entries.map(\.id), ["a", "b"])
        XCTAssertEqual(report.periodCostByEntryID["a"]?.total ?? 0, 6, accuracy: 0.0001)
        XCTAssertEqual(report.dailyCosts.map(\.amount), [2, 6])
        XCTAssertEqual(report.byProject.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(report.byProject.first?.amount ?? 0, 6, accuracy: 0.0001)
    }

    func testAllTimeHasNoComparisonAndIncludesEverything() {
        let entries = [
            entry(id: "a", updatedAt: "2026-10-13", days: [("2026-09-01", 1)]),
            entry(id: "u", updatedAt: "2026-01-01", days: [], priced: false)
        ]
        let report = CostReport(entries: entries, period: .all, now: now, calendar: calendar)

        XCTAssertNil(report.previousTotal)
        XCTAssertNil(report.changeFromPrevious)
        XCTAssertEqual(report.entries.count, 2)
        XCTAssertEqual(report.pricedSessionCount, 1)
        XCTAssertEqual(report.unpricedSessionCount, 1)
        XCTAssertEqual(report.total.total, 1, accuracy: 0.0001)
    }

    func testUnpricedSessionsBelongToThePeriodTheyWereActiveIn() {
        let entries = [
            entry(id: "today", updatedAt: "2026-10-14", days: [], priced: false),
            entry(id: "old", updatedAt: "2026-10-01", days: [], priced: false)
        ]
        let report = CostReport(entries: entries, period: .today, now: now, calendar: calendar)
        XCTAssertEqual(report.entries.map(\.id), ["today"])
        XCTAssertEqual(report.unpricedSessionCount, 1)
    }

    func testByModelGroupsSpendAndCountsSessions() {
        let entries = [
            entry(id: "a", model: "gpt-5.4", updatedAt: "2026-10-13", days: [("2026-10-13", 3)]),
            entry(id: "b", model: "gpt-5.4", updatedAt: "2026-10-12", days: [("2026-10-12", 1)]),
            entry(id: "c", model: "gpt-6-astra", updatedAt: "2026-10-12", days: [("2026-10-12", 2)])
        ]
        let report = CostReport(entries: entries, period: .month, now: now, calendar: calendar)
        XCTAssertEqual(report.byModel.map { ($0.name, $0.sessionCount) }.map { "\($0.0):\($0.1)" }, ["gpt-5.4:2", "gpt-6-astra:1"])
        XCTAssertEqual(report.byModel.first?.amount ?? 0, 4, accuracy: 0.0001)
    }

    func testCSVQuotesFieldsAndReportsPeriodCost() {
        let entries = [
            entry(id: "a", updatedAt: "2026-10-13", days: [("2026-10-09", 4), ("2026-10-13", 6)])
        ]
        var report = CostReport(entries: entries, period: .week, now: now, calendar: calendar)
        var lines = report.csv().split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("Total Cost,Cost In Period"))
        XCTAssertTrue(lines[1].hasSuffix(",10.000000,6.000000"), lines[1])

        let quoted = CostLedgerEntry(
            session: CodingSession(
                id: "q", provider: .claude, title: "Fix \"it\", please", projectPath: "/p", model: "m",
                usage: TokenUsage(), contextTokens: 0, contextWindow: 1, startedAt: now, updatedAt: now, logPath: "/l"
            ),
            cost: .zero,
            pricingEffectiveDate: now
        )
        report = CostReport(entries: [quoted], period: .all, now: now, calendar: calendar)
        lines = report.csv().split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[1].contains("\"Fix \"\"it\"\", please\""), lines[1])
    }

    func testPeriodsAreCalendarBased() {
        let week = try? XCTUnwrap(CostPeriod.week.interval(containing: now, calendar: calendar))
        XCTAssertEqual(week?.start, day("2026-10-12"))
        XCTAssertEqual(week?.end, day("2026-10-19"))
        let previousMonth = try? XCTUnwrap(CostPeriod.month.previousInterval(before: now, calendar: calendar))
        XCTAssertEqual(previousMonth?.start, day("2026-09-01"))
        XCTAssertEqual(previousMonth?.end, day("2026-10-01"))
        XCTAssertNil(CostPeriod.all.interval(containing: now, calendar: calendar))
    }
}
