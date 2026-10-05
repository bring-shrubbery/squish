import AppKit
import Charts
import SquishCore
import SwiftUI

struct CostDashboardView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isShowingUnpriced = false

    var body: some View {
        let snapshot = CostDashboardSnapshot(entries: appState.costEntries)
        let liveSessionIDs = Set(appState.sessions.map(\.id))
        // A scroll view with lazy session rows: a grouped Form lays out every row on every
        // update, which stalls the window once the ledger has hundreds of sessions.
        SettingsPage {
            SettingsGroup {
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
                .padding(.vertical, 10)
            }

            SettingsGroup {
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
                    .padding(.vertical, 10)
                }
            } header: {
                Text("Spend by Day")
            }

            SettingsGroup {
                CompositionRow(label: "Input", amount: snapshot.total.input, total: snapshot.total.total)
                SettingsDivider()
                CompositionRow(label: "Cache reads", amount: snapshot.total.cacheRead, total: snapshot.total.total)
                SettingsDivider()
                CompositionRow(label: "Cache writes", amount: snapshot.total.cacheWrite, total: snapshot.total.total)
                SettingsDivider()
                CompositionRow(label: "Output", amount: snapshot.total.output, total: snapshot.total.total)
            } header: {
                Text("Composition")
            }

            SettingsGroup {
                if appState.costEntries.isEmpty {
                    Text("No sessions yet. Start a coding agent in this folder or one of its subfolders.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(appState.costEntries) { entry in
                            SessionCostRow(
                                session: entry.session,
                                cost: entry.cost,
                                isArchived: !liveSessionIDs.contains(entry.id)
                            )
                            .equatable()
                            if entry.id != appState.costEntries.last?.id {
                                SettingsDivider()
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Sessions")
                    Spacer()
                    if snapshot.unpricedSessionCount > 0 {
                        Button {
                            isShowingUnpriced.toggle()
                        } label: {
                            HStack(spacing: 3) {
                                Text("\(snapshot.unpricedSessionCount) without pricing")
                                Image(systemName: "chevron.down")
                                    .font(.caption2.weight(.semibold))
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Which models have no price in the catalog")
                        .popover(isPresented: $isShowingUnpriced, arrowEdge: .bottom) {
                            UnpricedModelsPopover(models: snapshot.unpricedModels)
                        }
                    }
                }
            } footer: {
                FormFooter("Prices are API equivalents in USD, updated 5 Oct 2026. Subscription plans may differ.")
            }
        }
        .navigationSubtitle(subtitle)
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugSnapshots.unpricedNotification)) { _ in
            isShowingUnpriced.toggle()
        }
        #endif
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
        SettingsRow(label) {
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
        .padding(.vertical, 8)
    }
}

/// A model the catalog has no price for, and how many sessions used it.
struct UnpricedModel: Identifiable {
    let provider: AgentProvider
    let model: String
    let count: Int

    var id: String { "\(provider.rawValue):\(model)" }

    var line: String {
        "\(model) · \(provider.displayName) · \(count == 1 ? "1 session" : "\(count) sessions")"
    }
}

/// The models missing from the pricing catalog, with a copy button for the list.
private struct UnpricedModelsPopover: View {
    let models: [UnpricedModel]
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Models Without Pricing")
                    .font(.headline)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(models.map(\.line).joined(separator: "\n"), forType: .string)
                    copied = true
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(models) { entry in
                        HStack(spacing: 10) {
                            ProviderIcon(provider: entry.provider)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.model)
                                    .textSelection(.enabled)
                                Text(entry.provider.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            Text(entry.count == 1 ? "1 session" : "\(entry.count) sessions")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        if entry.id != models.last?.id {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 380)
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
    /// Most used first.
    let unpricedModels: [UnpricedModel]

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

        let unpriced = Dictionary(grouping: entries.filter { $0.cost == nil }) {
            "\($0.session.provider.rawValue):\($0.session.model)"
        }
        unpricedModels = unpriced.values.compactMap { group in
            group.first.map { UnpricedModel(provider: $0.session.provider, model: $0.session.model, count: group.count) }
        }
        .sorted { lhs, rhs in
            lhs.count != rhs.count ? lhs.count > rhs.count : lhs.model < rhs.model
        }
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
