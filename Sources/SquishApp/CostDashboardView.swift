import Charts
import SquishCore
import SwiftUI

struct CostDashboardView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let snapshot = CostDashboardSnapshot(entries: appState.costEntries)
        let liveSessionIDs = Set(appState.sessions.map(\.id))
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    PageHeader(
                        eyebrow: "Usage intelligence",
                        title: "Session costs",
                        subtitle: "API-equivalent pricing across every detected agent session."
                    )
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text("ALL TIME")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.9)
                            .padding(.horizontal, 10)
                            .frame(height: 27)
                            .background(.white.opacity(0.06), in: Capsule())
                        Text(appState.projectRoot?.lastPathComponent ?? "")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    CostStatCard(
                        label: "Estimated total",
                        value: currency(snapshot.total.total),
                        detail: "\(snapshot.pricedSessionCount) priced sessions",
                        color: AppColors.mint,
                        symbol: "dollarsign"
                    )
                    CostStatCard(
                        label: "Input",
                        value: currency(snapshot.total.input),
                        detail: compactTokenCount(snapshot.inputTokens),
                        color: AppColors.blue,
                        symbol: "arrow.down.left"
                    )
                    CostStatCard(
                        label: "Cache",
                        value: currency(snapshot.total.cacheRead + snapshot.total.cacheWrite),
                        detail: compactTokenCount(snapshot.cachedReadTokens),
                        color: AppColors.amber,
                        symbol: "bolt.horizontal.circle"
                    )
                    CostStatCard(
                        label: "Output",
                        value: currency(snapshot.total.output),
                        detail: compactTokenCount(snapshot.outputTokens),
                        color: Color(red: 0.76, green: 0.53, blue: 0.98),
                        symbol: "arrow.up.right"
                    )
                }

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Spend over time")
                                    .font(.system(size: 15, weight: .bold))
                                Text("Grouped by each session's latest activity")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        if snapshot.dailyCosts.isEmpty {
                            EmptyChartView()
                        } else {
                            Chart(snapshot.dailyCosts) { point in
                                BarMark(
                                    x: .value("Day", point.date, unit: .day),
                                    y: .value("Cost", point.amount)
                                )
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [AppColors.mint, AppColors.mint.opacity(0.36)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .cornerRadius(5)
                            }
                            .chartXAxis {
                                AxisMarks(values: .stride(by: .day)) { _ in
                                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                                        .foregroundStyle(.secondary)
                                    AxisGridLine().foregroundStyle(.white.opacity(0.035))
                                }
                            }
                            .chartYAxis {
                                AxisMarks(position: .leading) { value in
                                    AxisValueLabel {
                                        if let amount = value.as(Double.self) {
                                            Text(currency(amount))
                                        }
                                    }
                                    .foregroundStyle(.secondary)
                                    AxisGridLine().foregroundStyle(.white.opacity(0.05))
                                }
                            }
                            .frame(height: 168)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity)
                    .appCard()

                    CostCompositionCard(cost: snapshot.total)
                        .frame(width: 278)
                }

                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("All sessions")
                                .font(.system(size: 15, weight: .bold))
                            Text("Live sessions and retained cost history")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if snapshot.unpricedSessionCount > 0 {
                            Label("Some models need pricing", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(AppColors.amber)
                        }
                    }
                    .padding(18)

                    Divider().overlay(.white.opacity(0.05))

                    if appState.costEntries.isEmpty {
                        EmptySessionsView()
                    } else {
                        SessionTableHeader()
                        LazyVStack(spacing: 0) {
                            ForEach(appState.costEntries) { entry in
                                SessionCostRow(
                                    session: entry.session,
                                    cost: entry.cost,
                                    isArchived: !liveSessionIDs.contains(entry.id)
                                )
                                    .equatable()
                                if entry.id != appState.costEntries.last?.id {
                                    Divider().overlay(.white.opacity(0.04)).padding(.leading, 64)
                                }
                            }
                        }
                    }
                }
                .appCard()

                Text("Prices are API equivalents in USD, updated 10 Jul 2026. Subscription-plan charges may differ.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 6)
            }
            .padding(28)
        }
    }
}

private struct CostStatCard: View {
    let label: String
    let value: String
    let detail: String
    let color: Color
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 24, height: 24)
                    .background(color.opacity(0.12), in: Circle())
            }
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            Text(detail)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }
}

private struct CostCompositionCard: View {
    let cost: CostBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Cost composition")
                .font(.system(size: 15, weight: .bold))

            CostComponentRow(label: "Input", amount: cost.input, total: cost.total, color: AppColors.blue)
            CostComponentRow(label: "Cache reads", amount: cost.cacheRead, total: cost.total, color: AppColors.amber)
            CostComponentRow(label: "Cache writes", amount: cost.cacheWrite, total: cost.total, color: AppColors.coral)
            CostComponentRow(label: "Output", amount: cost.output, total: cost.total, color: Color(red: 0.76, green: 0.53, blue: 0.98))
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(height: 240, alignment: .top)
        .appCard()
    }
}

private struct CostComponentRow: View {
    let label: String
    let amount: Double
    let total: Double
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(currency(amount))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            GeometryReader { geometry in
                Capsule()
                    .fill(.white.opacity(0.055))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(color)
                            .frame(width: geometry.size.width * (total > 0 ? amount / total : 0))
                    }
            }
            .frame(height: 3)
        }
    }
}

private struct SessionTableHeader: View {
    var body: some View {
        HStack {
            Text("SESSION").frame(maxWidth: .infinity, alignment: .leading)
            Text("TOKENS").frame(width: 90, alignment: .trailing)
            Text("CONTEXT").frame(width: 110, alignment: .trailing)
            Text("COST").frame(width: 90, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .bold))
        .tracking(0.8)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: 32)
        .background(.black.opacity(0.12))
    }
}

private struct SessionCostRow: View, Equatable {
    let session: CodingSession
    let cost: CostBreakdown?
    let isArchived: Bool

    var body: some View {
        HStack(spacing: 12) {
            ProviderIcon(provider: session.provider)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(session.provider.displayName)
                    Text("•")
                    Text(session.model)
                    Text("•")
                    Text(session.projectName)
                    if isArchived {
                        Text("•")
                        Label("History", systemImage: "archivebox")
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(compactTokenCount(session.usage.totalTokens))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 90, alignment: .trailing)

            Text("\(Int(session.contextFraction * 100))%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(session.contextFraction >= 0.8 ? AppColors.amber : .secondary)
                .frame(width: 110, alignment: .trailing)

            if let cost {
                Text(currency(cost.total))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .frame(width: 90, alignment: .trailing)
            } else {
                Text("—")
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .trailing)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 66)
    }
}

struct ProviderIcon: View {
    let provider: AgentProvider

    var color: Color {
        switch provider {
        case .codex: AppColors.mint
        case .claude: Color(red: 0.95, green: 0.57, blue: 0.37)
        case .gemini: AppColors.blue
        }
    }

    var body: some View {
        Text(String(provider.displayName.prefix(1)))
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: 34, height: 34)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct EmptyChartView: View {
    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "chart.bar")
                .font(.system(size: 22))
            Text("Usage will appear after a session is detected")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 168)
    }
}

private struct EmptySessionsView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "scope")
                .font(.system(size: 23))
                .foregroundStyle(AppColors.mint)
            Text("No sessions in this folder yet")
                .font(.system(size: 13, weight: .bold))
            Text("Start a coding agent from this folder or one of its subfolders.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
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
