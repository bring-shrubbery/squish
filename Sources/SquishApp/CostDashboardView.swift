import Charts
import SquishCore
import SwiftUI

struct CostDashboardView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let snapshot = CostDashboardSnapshot(entries: appState.costEntries)
        let liveSessionIDs = Set(appState.sessions.map(\.id))
        Form {
            Section {
                HStack(alignment: .top, spacing: 0) {
                    Stat(
                        label: "Total",
                        value: currency(snapshot.total.total),
                        detail: "\(snapshot.pricedSessionCount) priced sessions"
                    )
                    Divider()
                    Stat(
                        label: "Input",
                        value: currency(snapshot.total.input),
                        detail: "\(compactTokenCount(snapshot.inputTokens)) tokens"
                    )
                    Divider()
                    Stat(
                        label: "Cache",
                        value: currency(snapshot.total.cacheRead + snapshot.total.cacheWrite),
                        detail: "\(compactTokenCount(snapshot.cachedReadTokens)) tokens read"
                    )
                    Divider()
                    Stat(
                        label: "Output",
                        value: currency(snapshot.total.output),
                        detail: "\(compactTokenCount(snapshot.outputTokens)) tokens"
                    )
                }
                .padding(.vertical, 6)
            }

            Section("Spend by Day") {
                if snapshot.dailyCosts.isEmpty {
                    Text("Usage appears after a session is detected.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    Chart(snapshot.dailyCosts) { point in
                        BarMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value("Cost", point.amount)
                        )
                        .foregroundStyle(Color.accentColor)
                        .cornerRadius(3)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let amount = value.as(Double.self) {
                                    Text(currency(amount))
                                }
                            }
                        }
                    }
                    .frame(height: 160)
                    .padding(.vertical, 6)
                }
            }

            Section("Composition") {
                CompositionRow(label: "Input", amount: snapshot.total.input, total: snapshot.total.total)
                CompositionRow(label: "Cache reads", amount: snapshot.total.cacheRead, total: snapshot.total.total)
                CompositionRow(label: "Cache writes", amount: snapshot.total.cacheWrite, total: snapshot.total.total)
                CompositionRow(label: "Output", amount: snapshot.total.output, total: snapshot.total.total)
            }

            Section {
                if appState.costEntries.isEmpty {
                    Text("No sessions yet. Start a coding agent in this folder or one of its subfolders.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.costEntries) { entry in
                        SessionCostRow(
                            session: entry.session,
                            cost: entry.cost,
                            isArchived: !liveSessionIDs.contains(entry.id)
                        )
                        .equatable()
                    }
                }
            } header: {
                HStack {
                    Text("Sessions")
                    Spacer()
                    if snapshot.unpricedSessionCount > 0 {
                        Text("\(snapshot.unpricedSessionCount) without pricing")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                FormFooter("Prices are API equivalents in USD, updated 10 Jul 2026. Subscription plans may differ.")
            }
        }
        .formStyle(.grouped)
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        let count = appState.costEntries.count
        return count == 1 ? "1 session" : "\(count) sessions"
    }
}

private struct Stat: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }
}

private struct CompositionRow: View {
    let label: String
    let amount: Double
    let total: Double

    var body: some View {
        let fraction = total > 0 ? amount / total : 0
        LabeledContent(label) {
            HStack(spacing: 12) {
                ProgressView(value: fraction)
                    .frame(width: 140)
                Text("\(Int((fraction * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                Text(currency(amount))
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
            }
        }
    }
}

private struct SessionCostRow: View, Equatable {
    let session: CodingSession
    let cost: CostBreakdown?
    let isArchived: Bool

    private var details: String {
        var parts = [session.provider.displayName, session.model, session.projectName]
        if session.isSubagent { parts.append("Subagent") }
        if isArchived { parts.append("Ended") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            ProviderIcon(provider: session.provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(1)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                if let cost {
                    Text(currency(cost.total))
                        .monospacedDigit()
                } else {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
                Text("\(compactTokenCount(session.usage.totalTokens)) tokens · \(Int(session.contextFraction * 100))% context")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(session.contextFraction >= 0.8 ? .orange : .secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DailyCost: Identifiable {
    let date: Date
    let amount: Double
    var id: Date { date }
}

private struct CostDashboardSnapshot {
    let total: CostBreakdown
    let pricedSessionCount: Int
    let unpricedSessionCount: Int
    let inputTokens: Int
    let cachedReadTokens: Int
    let outputTokens: Int
    let dailyCosts: [DailyCost]

    init(entries: [CostLedgerEntry]) {
        let priced = entries.compactMap { entry in
            entry.cost.map { (entry, $0) }
        }
        total = priced.reduce(.zero) { $0 + $1.1 }
        pricedSessionCount = priced.count
        unpricedSessionCount = entries.count - priced.count
        inputTokens = entries.reduce(0) { $0 + $1.session.usage.inputTokens }
        cachedReadTokens = entries.reduce(0) { $0 + $1.session.usage.cachedReadTokens }
        outputTokens = entries.reduce(0) { $0 + $1.session.usage.outputTokens }

        let calendar = Calendar.current
        let buckets = entries.flatMap(\.dailyCosts)
        let grouped = Dictionary(grouping: buckets) { calendar.startOfDay(for: $0.day) }
        dailyCosts = grouped.map { date, rows in
            DailyCost(date: date, amount: rows.reduce(0) { $0 + $1.cost.total })
        }
        .sorted { $0.date < $1.date }
    }
}

func currency(_ amount: Double) -> String {
    if amount > 0 && amount < 0.01 { return String(format: "$%.4f", amount) }
    return String(format: "$%.2f", amount)
}

func compactTokenCount(_ count: Int) -> String {
    switch count {
    case 1_000_000...: return String(format: "%.2fM", Double(count) / 1_000_000)
    case 1_000...: return String(format: "%.1fK", Double(count) / 1_000)
    default: return "\(count)"
    }
}
