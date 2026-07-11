import SquishCore
import SwiftUI

struct CompactAlertsView: View {
    @EnvironmentObject private var appState: AppState

    private var rankedSessions: [CodingSession] {
        appState.sessions.filter { !$0.isSubagent }.sorted {
            if $0.contextFraction == $1.contextFraction { return $0.updatedAt > $1.updatedAt }
            return $0.contextFraction > $1.contextFraction
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    PageHeader(
                        eyebrow: "Context guardian",
                        title: "Compact alerts",
                        subtitle: "A live, session-specific reminder at the top of your display."
                    )
                    Spacer()
                    HStack(spacing: 8) {
                        Circle()
                            .fill(appState.alertsEnabled ? AppColors.mint : .secondary)
                            .frame(width: 7, height: 7)
                        Text(appState.alertsEnabled ? "MONITORING" : "PAUSED")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.9)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 29)
                    .background(.white.opacity(0.055), in: Capsule())
                }

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Notch reminder")
                                    .font(.system(size: 16, weight: .bold))
                                Text("Show once when an active session crosses the threshold.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $appState.alertsEnabled)
                                .toggleStyle(.switch)
                                .tint(AppColors.mint)
                                .labelsHidden()
                        }

                        Divider().overlay(.white.opacity(0.05))

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Alert threshold")
                                    .font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text("\(Int(appState.alertThreshold * 100))%")
                                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                                    .foregroundStyle(AppColors.mint)
                            }

                            Slider(value: $appState.alertThreshold, in: 0.5...0.95, step: 0.05)
                                .tint(AppColors.mint)

                            HStack {
                                Text("Earlier")
                                Spacer()
                                Text("Later")
                            }
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        }

                        Button {
                            appState.previewAlert()
                        } label: {
                            Label("Preview notch alert", systemImage: "play.fill")
                                .font(.system(size: 12, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity)
                    .appCard()

                    VStack(alignment: .leading, spacing: 16) {
                        Text("How it behaves")
                            .font(.system(size: 15, weight: .bold))

                        AlertBehaviorRow(symbol: "bolt.fill", title: "Live", detail: "Checks changed logs every second")
                        AlertBehaviorRow(symbol: "scope", title: "Specific", detail: "Names the exact session and agent")
                        AlertBehaviorRow(symbol: "arrow.counterclockwise", title: "Re-arms", detail: "Alerts again after context drops")

                        Text("On Macs without a camera notch, the panel appears at top-center.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(18)
                    .frame(width: 300)
                    .appCard()
                }

                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Session context")
                                .font(.system(size: 15, weight: .bold))
                            Text("Primary sessions only, highest context pressure first")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(rankedSessions.count) DETECTED")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                    }
                    .padding(18)

                    Divider().overlay(.white.opacity(0.05))

                    if rankedSessions.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.system(size: 22))
                                .foregroundStyle(AppColors.mint)
                            Text("Waiting for a session")
                                .font(.system(size: 13, weight: .bold))
                            Text("New Codex, Claude Code, and Gemini CLI logs are detected automatically.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 150)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(rankedSessions) { session in
                                SessionContextRow(session: session, threshold: appState.alertThreshold)
                                    .equatable()
                                if session.id != rankedSessions.last?.id {
                                    Divider().overlay(.white.opacity(0.04)).padding(.leading, 68)
                                }
                            }
                        }
                    }
                }
                .appCard()

                if !appState.recentAlerts.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Recent reminders")
                            .font(.system(size: 15, weight: .bold))
                        ForEach(appState.recentAlerts.prefix(4)) { alert in
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(AppColors.mint)
                                Text(alert.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                                Spacer()
                                Text(alert.date, style: .relative)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(18)
                    .appCard()
                }
            }
            .padding(28)
        }
    }
}

private struct AlertBehaviorRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AppColors.mint)
                .frame(width: 28, height: 28)
                .background(AppColors.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .bold))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SessionContextRow: View, Equatable {
    let session: CodingSession
    let threshold: Double

    private var statusColor: Color {
        if session.contextFraction >= threshold { return AppColors.coral }
        if session.contextFraction >= threshold - 0.15 { return AppColors.amber }
        return AppColors.mint
    }

    private var statusText: String {
        if session.contextFraction >= threshold { return "Compact now" }
        if session.contextFraction >= threshold - 0.15 { return "Getting full" }
        return "Healthy"
    }

    var body: some View {
        HStack(spacing: 14) {
            ProviderIcon(provider: session.provider)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(session.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(session.projectName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.045), in: Capsule())
                }
                GeometryReader { geometry in
                    Capsule()
                        .fill(.white.opacity(0.06))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(statusColor)
                                .frame(width: geometry.size.width * session.contextFraction)
                        }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(Int(session.contextFraction * 100))%")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                Text("\(compactTokenCount(session.contextTokens)) / \(compactTokenCount(session.contextWindow))")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 112, alignment: .trailing)

            Text(statusText)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(statusColor)
                .frame(width: 86, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: 70)
    }
}
