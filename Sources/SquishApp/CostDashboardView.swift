import AppKit
import Charts
import SquishCore
import SwiftUI
import UniformTypeIdentifiers

struct CostDashboardView: View {
    @EnvironmentObject private var appState: AppState
    @State private var period = CostPeriod.month
    @State private var isShowingUnpriced = false

    var body: some View {
        let report = CostReport(entries: appState.costEntries, period: period)
        let liveSessionIDs = Set(appState.sessions.map(\.id))
        // A scroll view with lazy session rows: a grouped Form lays out every row on every
        // update, which stalls the window once the ledger has hundreds of sessions.
        SettingsPage {
            SettingsGroup {
                HStack(alignment: .top, spacing: 0) {
                    Stat(
                        label: period.title,
                        value: currency(report.total.total),
                        detail: comparison(for: report)
                    )
                    Divider()
                    Stat(
                        label: "Input",
                        value: currency(report.total.input),
                        detail: share(report.total.input, of: report.total.total)
                    )
                    Divider()
                    Stat(
                        label: "Cache",
                        value: currency(report.total.cacheRead + report.total.cacheWrite),
                        detail: share(report.total.cacheRead + report.total.cacheWrite, of: report.total.total)
                    )
                    Divider()
                    Stat(
                        label: "Output",
                        value: currency(report.total.output),
                        detail: share(report.total.output, of: report.total.total)
                    )
                }
                .padding(.vertical, 10)
            }

            SettingsGroup {
                if report.dailyCosts.isEmpty {
                    Text(report.entries.isEmpty ? "Usage appears after a session is detected." : "No spend \(periodPhrase).")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    SpendChart(dailyCosts: report.dailyCosts, interval: report.interval)
                        .frame(height: 160)
                        .padding(.vertical, 10)
                }
            } header: {
                Text("Spend by Day")
            }

            ShareGroup(title: "By Project", shares: report.byProject, total: report.total.total, periodPhrase: periodPhrase)
            ShareGroup(title: "By Model", shares: report.byModel, total: report.total.total, periodPhrase: periodPhrase)

            SettingsGroup {
                if report.entries.isEmpty {
                    Text(appState.costEntries.isEmpty
                        ? "No sessions yet. Start a coding agent in this folder or one of its subfolders."
                        : "No sessions \(periodPhrase).")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(report.entries) { entry in
                            SessionCostRow(
                                session: entry.session,
                                cost: entry.cost,
                                periodCost: period == .all ? nil : report.periodCostByEntryID[entry.id],
                                isArchived: !liveSessionIDs.contains(entry.id)
                            )
                            .equatable()
                            if entry.id != report.entries.last?.id {
                                SettingsDivider()
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Sessions")
                    Spacer()
                    if report.unpricedSessionCount > 0 {
                        Button {
                            isShowingUnpriced.toggle()
                        } label: {
                            HStack(spacing: 3) {
                                Text("\(report.unpricedSessionCount) without pricing")
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
                            UnpricedModelsPopover(models: unpricedModels(in: report))
                        }
                    }
                }
            } footer: {
                FormFooter(
                    "Prices are API equivalents in USD, updated \(PricingCatalog.current.effectiveDate.formatted(date: .abbreviated, time: .omitted)). "
                        + "Subscription plans may differ."
                )
            }
        }
        .navigationSubtitle(subtitle(for: report))
        .toolbar {
            ToolbarItemGroup {
                Picker("Period", selection: $period) {
                    ForEach(CostPeriod.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .help("The period the totals, breakdowns and sessions cover")
                Button {
                    export(report)
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .help("Save the sessions shown as a CSV file")
                .disabled(report.entries.isEmpty)
            }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugSnapshots.unpricedNotification)) { _ in
            isShowingUnpriced.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: DebugSnapshots.periodNotification)) { notification in
            if let raw = notification.object as? String, let next = CostPeriod(rawValue: raw) { period = next }
        }
        #endif
    }

    private var periodPhrase: String {
        switch period {
        case .today: "today"
        case .week: "this week"
        case .month: "this month"
        case .all: "yet"
        }
    }

    private func subtitle(for report: CostReport) -> String {
        let count = report.entries.count
        let sessions = count == 1 ? "1 session" : "\(count) sessions"
        return period == .all ? sessions : "\(sessions) \(periodPhrase)"
    }

    /// "+12% vs last week", or the session count when there is nothing to compare with.
    private func comparison(for report: CostReport) -> String {
        let count = report.pricedSessionCount
        let sessions = count == 1 ? "1 priced session" : "\(count) priced sessions"
        guard let name = period.comparisonName else { return sessions }
        guard let change = report.changeFromPrevious else {
            if let previous = report.previousTotal, previous.total == 0, report.total.total == 0 {
                return "Nothing \(name) either"
            }
            return "Nothing spent \(name)"
        }
        if change >= 9 {
            return "\(Int((change + 1).rounded()))× \(name)"
        }
        let percent = Int((abs(change) * 100).rounded())
        let sign = change < 0 ? "−" : "+"
        return "\(sign)\(percent)% vs \(name)"
    }

    private func share(_ amount: Double, of total: Double) -> String {
        guard total > 0 else { return "0% of total" }
        return "\(Int((amount / total * 100).rounded()))% of total"
    }

    private func unpricedModels(in report: CostReport) -> [UnpricedModel] {
        let unpriced = Dictionary(grouping: report.entries.filter { $0.cost == nil }) {
            "\($0.session.provider.rawValue):\($0.session.model)"
        }
        return unpriced.values.compactMap { group in
            group.first.map { UnpricedModel(provider: $0.session.provider, model: $0.session.model, count: group.count) }
        }
        .sorted { lhs, rhs in
            lhs.count != rhs.count ? lhs.count > rhs.count : lhs.model < rhs.model
        }
    }

    private func export(_ report: CostReport) {
        let panel = NSSavePanel()
        panel.title = "Export Costs"
        panel.nameFieldStringValue = exportFileName(for: report)
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? report.csv().write(to: url, atomically: true, encoding: .utf8)
    }

    private func exportFileName(for report: CostReport) -> String {
        let folder = appState.projectRoot?.lastPathComponent ?? "Squish"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let suffix: String
        switch period {
        case .all: suffix = "all-time"
        case .today: suffix = formatter.string(from: Date())
        case .week, .month:
            suffix = report.interval.map {
                "\(formatter.string(from: $0.start))-to-\(formatter.string(from: $0.end.addingTimeInterval(-1)))"
            } ?? period.rawValue
        }
        return "\(folder) costs \(suffix).csv"
    }
}

/// Daily bars over the period, with the period's full span as the axis so a quiet week still
/// shows its seven days.
private struct SpendChart: View {
    let dailyCosts: [DayCost]
    let interval: DateInterval?

    var body: some View {
        Chart(dailyCosts) { point in
            BarMark(
                x: .value("Day", point.day, unit: .day),
                y: .value("Cost", point.amount)
            )
            .foregroundStyle(Color.accentColor)
            .cornerRadius(3)
        }
        .chartXScale(domain: domain)
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
    }

    private var domain: ClosedRange<Date> {
        if let interval {
            return interval.start...interval.end
        }
        let first = dailyCosts.first?.day ?? Date()
        let last = dailyCosts.last?.day ?? Date()
        return first...Calendar.current.date(byAdding: .day, value: 1, to: last)!
    }
}

/// Spend by project or by model: the largest first, the rest folded into one line.
private struct ShareGroup: View {
    let title: String
    let shares: [CostShare]
    let total: Double
    let periodPhrase: String

    private static let shown = 8

    var body: some View {
        SettingsGroup {
            if shares.isEmpty {
                Text("No spend \(periodPhrase).")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                let top = shares.prefix(Self.shown)
                ForEach(top) { share in
                    ShareRow(name: share.name, detail: sessionCount(share.sessionCount), amount: share.amount, total: total)
                    if share.id != top.last?.id || shares.count > Self.shown {
                        SettingsDivider()
                    }
                }
                if shares.count > Self.shown {
                    let rest = shares.dropFirst(Self.shown)
                    ShareRow(
                        name: "\(rest.count) more",
                        detail: sessionCount(rest.reduce(0) { $0 + $1.sessionCount }),
                        amount: rest.reduce(0) { $0 + $1.amount },
                        total: total
                    )
                }
            }
        } header: {
            Text(title)
        }
    }

    private func sessionCount(_ count: Int) -> String {
        count == 1 ? "1 session" : "\(count) sessions"
    }
}

private struct ShareRow: View {
    let name: String
    let detail: String
    let amount: Double
    let total: Double

    var body: some View {
        let fraction = total > 0 ? amount / total : 0
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
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
        .padding(.vertical, 7)
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

private struct SessionCostRow: View, Equatable {
    let session: CodingSession
    let cost: CostBreakdown?
    /// The part of the cost that falls in the selected period; nil for all time.
    let periodCost: CostBreakdown?
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
                    if let periodCost, abs(periodCost.total - cost.total) >= 0.005 {
                        Text("\(currency(periodCost.total)) of \(currency(cost.total))")
                            .monospacedDigit()
                    } else {
                        Text(currency(cost.total))
                            .monospacedDigit()
                    }
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
