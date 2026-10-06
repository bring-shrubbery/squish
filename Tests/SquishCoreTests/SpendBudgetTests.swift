import Foundation
import XCTest
@testable import SquishCore

final class SpendBudgetTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)!
    }

    private func entry(_ id: String, days: [(String, Double)]) -> CostLedgerEntry {
        let session = CodingSession(
            id: id, provider: .claude, title: id, projectPath: "/p/a", model: "claude-opus-5-5",
            usage: TokenUsage(inputTokens: 1), contextTokens: 1, contextWindow: 100,
            startedAt: date(days.first!.0), updatedAt: date(days.last!.0), logPath: "/l"
        )
        let buckets = days.map { DailyCostBucket(day: date($0.0), cost: CostBreakdown(input: $0.1, cacheRead: 0, cacheWrite: 0, output: 0)) }
        return CostLedgerEntry(session: session, cost: buckets.reduce(.zero) { $0 + $1.cost }, dailyCosts: buckets, pricingEffectiveDate: date("2026-01-01T00:00:00Z"))
    }

    func testBudgetRejectsNothingAndAllTime() {
        XCTAssertNil(SpendBudget(amount: 0, period: .month))
        XCTAssertNil(SpendBudget(amount: -5, period: .week))
        XCTAssertNil(SpendBudget(amount: 10, period: .all))
        XCTAssertEqual(SpendBudget(amount: 10, period: .month)?.periodPhrase, "this month")
        XCTAssertEqual(SpendBudget(amount: 10, period: .week)?.rateName, "per week")
    }

    func testStatusCountsOnlyTheCurrentPeriod() throws {
        let budget = try XCTUnwrap(SpendBudget(amount: 100, period: .month))
        let entries = [
            entry("a", days: [("2026-09-28T00:00:00Z", 50), ("2026-10-02T00:00:00Z", 30)]),
            entry("b", days: [("2026-10-05T00:00:00Z", 12)])
        ]
        let status = try XCTUnwrap(BudgetStatus(budget: budget, entries: entries, now: date("2026-10-06T12:00:00Z"), calendar: calendar))
        XCTAssertEqual(status.spent, 42, accuracy: 0.0001)
        XCTAssertEqual(status.remaining, 58, accuracy: 0.0001)
        XCTAssertEqual(status.fraction, 0.42, accuracy: 0.0001)
        XCTAssertEqual(status.level, .ok)
        XCTAssertEqual(status.summary, "$42.00 of $100.00 this month")
        let big = BudgetStatus(budget: SpendBudget(amount: 3000, period: .month)!, spent: 1234.5, interval: status.interval)
        XCTAssertEqual(big.summary, "$1,234.50 of $3,000.00 this month")
        XCTAssertEqual(status.interval.start, date("2026-10-01T00:00:00Z"))
    }

    func testLevelsAndCrossings() throws {
        let budget = try XCTUnwrap(SpendBudget(amount: 10, period: .today))
        let interval = DateInterval(start: date("2026-10-06T00:00:00Z"), duration: 86_400)
        let ok = BudgetStatus(budget: budget, spent: 5, interval: interval)
        let near = BudgetStatus(budget: budget, spent: 8, interval: interval)
        let over = BudgetStatus(budget: budget, spent: 14, interval: interval)
        XCTAssertEqual(ok.level, .ok)
        XCTAssertEqual(near.level, .near)
        XCTAssertEqual(over.level, .over)
        XCTAssertEqual(over.fraction, 1.4, accuracy: 0.0001)
        XCTAssertEqual(over.remaining, 0)

        XCTAssertNil(ok.crossedLevel(since: nil))
        XCTAssertEqual(near.crossedLevel(since: nil), .near)
        XCTAssertNil(near.crossedLevel(since: .near))
        XCTAssertEqual(over.crossedLevel(since: .near), .over)
        XCTAssertNil(over.crossedLevel(since: .over))
        // A cheaper day after an expensive one does not re-announce the lower level.
        XCTAssertNil(near.crossedLevel(since: .over))
    }
}
