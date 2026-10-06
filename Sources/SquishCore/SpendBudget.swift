import Foundation

/// A spending limit for the watched folder over a calendar period: so much per day, week
/// or month. Nothing is enforced; Squish shows how much of it is used and says when it is
/// nearly and then fully used.
public struct SpendBudget: Codable, Equatable, Sendable {
    public let amount: Double
    public let period: CostPeriod

    /// Nil for a non-positive amount or the all-time period, which cannot be a budget.
    public init?(amount: Double, period: CostPeriod) {
        guard amount > 0, period != .all else { return nil }
        self.amount = amount
        self.period = period
    }

    /// "today", "this week", "this month".
    public var periodPhrase: String {
        switch period {
        case .today: "today"
        case .week: "this week"
        case .month: "this month"
        case .all: "all time"
        }
    }

    /// "per day", "per week", "per month".
    public var rateName: String {
        switch period {
        case .today: "per day"
        case .week: "per week"
        case .month: "per month"
        case .all: "all time"
        }
    }
}

/// Where the spend stands against the budget in the current period.
public struct BudgetStatus: Equatable, Sendable {
    public enum Level: Int, Comparable, Sendable {
        case ok
        /// At or past the warning fraction, under the limit.
        case near
        /// At or past the limit.
        case over

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public static let warningFraction = 0.8

    public let budget: SpendBudget
    public let spent: Double
    /// The current period, so the alert bookkeeping can tell one period from the next.
    public let interval: DateInterval

    public init(budget: SpendBudget, spent: Double, interval: DateInterval) {
        self.budget = budget
        self.spent = max(0, spent)
        self.interval = interval
    }

    /// The budget against the ledger's spend in the period containing `now`.
    public init?(budget: SpendBudget, entries: [CostLedgerEntry], now: Date = Date(), calendar: Calendar = .current) {
        guard let interval = budget.period.interval(containing: now, calendar: calendar) else { return nil }
        let report = CostReport(entries: entries, period: budget.period, now: now, calendar: calendar)
        self.init(budget: budget, spent: report.total.total, interval: interval)
    }

    /// Spend over the amount, not capped, so "140%" reads as such.
    public var fraction: Double { spent / budget.amount }
    public var remaining: Double { max(0, budget.amount - spent) }

    public var level: Level {
        if fraction >= 1 { return .over }
        if fraction >= Self.warningFraction { return .near }
        return .ok
    }

    /// "$42.10 of $100.00 this month", for the menu bar and the Costs page.
    public var summary: String {
        "\(Self.money(spent)) of \(Self.money(budget.amount)) \(budget.periodPhrase)"
    }

    /// Whether moving from `previous` to this status crosses a line worth telling the user
    /// about: the first time the spend is near the limit, and the first time it is over.
    public func crossedLevel(since previous: Level?) -> Level? {
        let before = previous ?? .ok
        guard level > before, level != .ok else { return nil }
        return level
    }

    /// "$3,000.00": two decimals, grouped, whatever the locale.
    static func money(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = true
        return "$" + (formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount))
    }
}
