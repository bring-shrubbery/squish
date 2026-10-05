import Foundation

/// The span the Costs page reports on. Calendar periods, so a month matches a provider's bill.
public enum CostPeriod: String, CaseIterable, Identifiable, Sendable {
    case today
    case week
    case month
    case all

    public var id: Self { self }

    public var title: String {
        switch self {
        case .today: "Today"
        case .week: "This Week"
        case .month: "This Month"
        case .all: "All Time"
        }
    }

    /// What the period is compared with: "yesterday", "last week", "last month".
    public var comparisonName: String? {
        switch self {
        case .today: "yesterday"
        case .week: "last week"
        case .month: "last month"
        case .all: nil
        }
    }

    private var component: Calendar.Component? {
        switch self {
        case .today: .day
        case .week: .weekOfYear
        case .month: .month
        case .all: nil
        }
    }

    /// The period containing `now`; nil for all time.
    public func interval(containing now: Date, calendar: Calendar) -> DateInterval? {
        guard let component else { return nil }
        return calendar.dateInterval(of: component, for: now)
    }

    /// The period just before the one containing `now`; nil for all time.
    public func previousInterval(before now: Date, calendar: Calendar) -> DateInterval? {
        guard let component, let current = interval(containing: now, calendar: calendar),
              let earlier = calendar.date(byAdding: component, value: -1, to: current.start)
        else { return nil }
        return calendar.dateInterval(of: component, for: earlier)
    }
}

/// One day's spend, for the chart.
public struct DayCost: Identifiable, Equatable, Sendable {
    public let day: Date
    public let amount: Double

    public var id: Date { day }

    public init(day: Date, amount: Double) {
        self.day = day
        self.amount = amount
    }
}

/// Spend attributed to one project or one model within the period.
public struct CostShare: Identifiable, Equatable, Sendable {
    public let name: String
    public let amount: Double
    public let sessionCount: Int

    public var id: String { name }

    public init(name: String, amount: Double, sessionCount: Int) {
        self.name = name
        self.amount = amount
        self.sessionCount = sessionCount
    }
}

/// What the ledger says about one period: totals, the change from the period before, the
/// spend by day, by project and by model, and the sessions involved. Pure, so it is testable
/// and cheap to rebuild on every ledger change.
public struct CostReport: Sendable {
    public let period: CostPeriod
    public let interval: DateInterval?
    public let total: CostBreakdown
    /// The total of the period before, for the comparison; nil for all time.
    public let previousTotal: CostBreakdown?
    public let dailyCosts: [DayCost]
    public let byProject: [CostShare]
    public let byModel: [CostShare]
    /// The ledger entries with spend in the period (or, unpriced, activity in it), newest first.
    public let entries: [CostLedgerEntry]
    /// Spend in the period per entry, for the export; whole-session cost outside a period.
    public let periodCostByEntryID: [String: CostBreakdown]
    public let pricedSessionCount: Int
    public let unpricedSessionCount: Int

    public init(
        entries: [CostLedgerEntry],
        period: CostPeriod,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        self.period = period
        let interval = period.interval(containing: now, calendar: calendar)
        self.interval = interval
        let previousInterval = period.previousInterval(before: now, calendar: calendar)

        var included: [CostLedgerEntry] = []
        var periodCosts: [String: CostBreakdown] = [:]
        var total = CostBreakdown.zero
        var previousTotal = CostBreakdown.zero
        var byDay: [Date: Double] = [:]
        var byProject: [String: (amount: Double, sessions: Int)] = [:]
        var byModel: [String: (amount: Double, sessions: Int)] = [:]
        var priced = 0
        var unpriced = 0

        for entry in entries {
            let buckets = entry.dailyCosts.filter { bucket in
                interval.map { $0.contains(bucket: bucket) } ?? true
            }
            let spend = buckets.reduce(CostBreakdown.zero) { $0 + $1.cost }
            if let previousInterval {
                previousTotal = previousTotal + entry.dailyCosts
                    .filter { previousInterval.contains(bucket: $0) }
                    .reduce(CostBreakdown.zero) { $0 + $1.cost }
            }

            let isActiveInPeriod = interval.map { $0.contains(entry.session.updatedAt) } ?? true
            let belongs = entry.cost == nil ? isActiveInPeriod : (!buckets.isEmpty || (spend == .zero && isActiveInPeriod))
            guard belongs else { continue }

            included.append(entry)
            if entry.cost == nil {
                unpriced += 1
            } else {
                priced += 1
                periodCosts[entry.id] = spend
                total = total + spend
                for bucket in buckets {
                    let day = calendar.startOfDay(for: bucket.day)
                    byDay[day, default: 0] += bucket.cost.total
                }
                let project = entry.session.projectName
                byProject[project] = ((byProject[project]?.amount ?? 0) + spend.total, (byProject[project]?.sessions ?? 0) + 1)
                let model = entry.session.model
                byModel[model] = ((byModel[model]?.amount ?? 0) + spend.total, (byModel[model]?.sessions ?? 0) + 1)
            }
        }

        self.entries = included.sorted {
            if $0.session.updatedAt == $1.session.updatedAt { return $0.id < $1.id }
            return $0.session.updatedAt > $1.session.updatedAt
        }
        self.periodCostByEntryID = periodCosts
        self.total = total
        self.previousTotal = previousInterval == nil ? nil : previousTotal
        self.dailyCosts = byDay.map { DayCost(day: $0.key, amount: $0.value) }.sorted { $0.day < $1.day }
        self.byProject = Self.shares(byProject)
        self.byModel = Self.shares(byModel)
        self.pricedSessionCount = priced
        self.unpricedSessionCount = unpriced
    }

    /// The change from the previous period as a fraction of it; nil without a comparison or
    /// when the previous period had no spend.
    public var changeFromPrevious: Double? {
        guard let previousTotal, previousTotal.total > 0 else { return nil }
        return (total.total - previousTotal.total) / previousTotal.total
    }

    private static func shares(_ groups: [String: (amount: Double, sessions: Int)]) -> [CostShare] {
        groups.map { CostShare(name: $0.key, amount: $0.value.amount, sessionCount: $0.value.sessions) }
            .sorted { lhs, rhs in
                if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
                return lhs.name < rhs.name
            }
    }

    // MARK: - Export

    /// One row per session in the report, for a spreadsheet. Costs are USD; dates are ISO 8601.
    public func csv() -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            [
                "Started", "Last Active", "Provider", "Model", "Project", "Title", "Subagent",
                "Input Tokens", "Cache Read Tokens", "Cache Write Tokens", "Output Tokens",
                "Input Cost", "Cache Read Cost", "Cache Write Cost", "Output Cost", "Total Cost",
                period == .all ? "Cost All Time" : "Cost In Period"
            ].joined(separator: ",")
        ]
        for entry in entries {
            let session = entry.session
            let usage = session.usage
            let cost = entry.cost
            let fields: [String] = [
                formatter.string(from: session.startedAt),
                formatter.string(from: session.updatedAt),
                session.provider.displayName,
                session.model,
                session.projectPath,
                session.title,
                session.isSubagent ? "yes" : "no",
                String(usage.inputTokens),
                String(usage.cachedReadTokens),
                String(usage.cacheWrite5mTokens + usage.cacheWrite1hTokens),
                String(usage.outputTokens),
                Self.money(cost?.input),
                Self.money(cost?.cacheRead),
                Self.money(cost?.cacheWrite),
                Self.money(cost?.output),
                Self.money(cost?.total),
                Self.money(periodCostByEntryID[entry.id]?.total)
            ]
            lines.append(fields.map(Self.csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func money(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.6f", value)
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

private extension DateInterval {
    func contains(bucket: DailyCostBucket) -> Bool {
        bucket.day >= start && bucket.day < end
    }
}
