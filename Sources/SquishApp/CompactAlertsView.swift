import SquishCore
import SwiftUI

struct CompactAlertsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var sessionSort = CompactSessionSort.contextPressure

    private var rankedSessions: [CodingSession] {
        appState.sessions.filter { !$0.isSubagent }.sorted { lhs, rhs in
            switch sessionSort {
            case .contextPressure:
                if lhs.contextFraction == rhs.contextFraction { return lhs.updatedAt > rhs.updatedAt }
                return lhs.contextFraction > rhs.contextFraction
            case .latestActivity:
                if lhs.updatedAt == rhs.updatedAt { return lhs.contextFraction > rhs.contextFraction }
                return lhs.updatedAt > rhs.updatedAt
            }
        }
    }

    var body: some View {
        // A scroll view with lazy rows: a grouped Form lays out every row on every update,
        // which stalls the window once the session list has hundreds of entries.
        let sessions = rankedSessions
        SettingsPage {
            SettingsGroup {
                SettingsRow("Remind me to compact") {
                    Toggle("Remind me to compact", isOn: $appState.alertsEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingsDivider()
                SettingsRow("Alert at") {
                    HStack(spacing: 10) {
                        Slider(value: $appState.alertThreshold, in: 0.5...0.95, step: 0.05)
                            .frame(width: 180)
                        Text("\(Int(appState.alertThreshold * 100))%")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                SettingsDivider()
                SettingsRow("Preview") {
                    Button("Show in Notch") { appState.previewAlert() }
                }
            } footer: {
                FormFooter(
                    "Squish checks changed session logs every second and shows the reminder once, "
                        + "naming the session that is close to its limit. It arms again after the context "
                        + "drops. On Macs without a notch the reminder appears at the top of the screen. "
                        + "Compact sends the command to the session's tab in Terminal or iTerm2, which "
                        + "macOS asks you to allow once; in other terminals it copies the command to paste."
                )
            }

            SettingsGroup {
                if sessions.isEmpty {
                    Text("No sessions yet. New Codex, Claude Code and Gemini sessions appear automatically.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(sessions) { session in
                            SessionContextRow(session: session, threshold: appState.alertThreshold)
                                .equatable()
                            if session.id != sessions.last?.id {
                                SettingsDivider()
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Sessions")
                    Spacer()
                    Picker("Sort", selection: $sessionSort) {
                        ForEach(CompactSessionSort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
            }

            if !appState.recentAlerts.isEmpty {
                let recent = Array(appState.recentAlerts.prefix(4))
                SettingsGroup {
                    ForEach(recent) { alert in
                        SettingsRow(alert.title) {
                            Text(alert.date, format: .relative(presentation: .named))
                                .foregroundStyle(.secondary)
                        }
                        if alert.id != recent.last?.id {
                            SettingsDivider()
                        }
                    }
                } header: {
                    Text("Recent Reminders")
                }
            }
        }
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        guard appState.alertsEnabled else { return "Paused" }
        let count = rankedSessions.count
        return count == 1 ? "Watching 1 session" : "Watching \(count) sessions"
    }
}

private enum CompactSessionSort: String, CaseIterable, Identifiable {
    case contextPressure
    case latestActivity

    var id: Self { self }

    var title: String {
        switch self {
        case .contextPressure: "Fullest First"
        case .latestActivity: "Latest First"
        }
    }
}

private struct SessionContextRow: View, Equatable {
    let session: CodingSession
    let threshold: Double
    @State private var delivery: CompactionSender.Delivery?

    static func == (lhs: SessionContextRow, rhs: SessionContextRow) -> Bool {
        lhs.session == rhs.session && lhs.threshold == rhs.threshold
    }

    private var isOver: Bool { session.contextFraction >= threshold }
    private var isClose: Bool { !isOver && session.contextFraction >= threshold - 0.15 }

    /// "about $0.12 to compact", when the model is priced.
    private var estimate: String? {
        Compaction.estimatedCost(for: session).map { "about \(currency($0)) to compact" }
    }

    private var tint: Color {
        if isOver { return .red }
        if isClose { return .orange }
        return .accentColor
    }

    var body: some View {
        HStack(spacing: 10) {
            ProviderIcon(provider: session.provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(1)
                Text("\(session.provider.displayName) · \(session.projectName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if isOver || isClose {
                Button(delivery?.label ?? "Compact") {
                    guard delivery == nil else { return }
                    delivery = CompactionSender.compact(session)
                }
                .controlSize(.small)
                .disabled(delivery != nil)
                .help(estimate ?? "Send the compact command to the session's terminal")
            }
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    if isOver {
                        Text("Compact now")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if isClose {
                        Text("Getting full")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("\(Int(session.contextFraction * 100))%")
                        .monospacedDigit()
                }
                ProgressView(value: min(session.contextFraction, 1))
                    .tint(tint)
                    .frame(width: 140)
                if isOver || isClose, let estimate {
                    Text(estimate)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }
}
