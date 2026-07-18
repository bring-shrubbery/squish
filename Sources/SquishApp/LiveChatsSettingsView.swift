import SquishCore
import SwiftUI

struct LiveChatsSettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    PageHeader(
                        eyebrow: "Live control",
                        title: "Live chats",
                        subtitle: "See active agents in the notch and answer Claude Code from it."
                    )
                    Spacer()
                    HStack(spacing: 8) {
                        Circle()
                            .fill(appState.liveChatsEnabled ? AppColors.mint : .secondary)
                            .frame(width: 7, height: 7)
                        Text(appState.liveChatsEnabled ? "LISTENING" : "OFF")
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
                                Text("Live agent chats")
                                    .font(.system(size: 16, weight: .bold))
                                Text("Expands the notch when agents are active; opens it when Claude Code needs you.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Toggle("", isOn: $appState.liveChatsEnabled)
                                .toggleStyle(.switch)
                                .tint(AppColors.mint)
                                .labelsHidden()
                        }

                        Divider().overlay(.white.opacity(0.05))

                        SetupStatusRow(
                            symbol: "link",
                            title: "Claude Code hook",
                            detail: appState.liveChatsHookInstalled
                                ? "Installed in ~/.claude/settings.json"
                                : "Not installed — enable to add it",
                            ok: appState.liveChatsHookInstalled
                        )
                        SetupStatusRow(
                            symbol: "hand.tap.fill",
                            title: "Accessibility",
                            detail: appState.liveChatsAccessibilityGranted
                                ? "Granted — typed answers go straight to the terminal"
                                : "Needed to type answers; approvals work without it",
                            ok: appState.liveChatsAccessibilityGranted
                        )

                        Button {
                            appState.previewLiveChat()
                        } label: {
                            Label("Preview request in notch", systemImage: "play.fill")
                                .font(.system(size: 12, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!appState.liveChatsEnabled)
                        .opacity(appState.liveChatsEnabled ? 1 : 0.5)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity)
                    .appCard()

                    VStack(alignment: .leading, spacing: 16) {
                        Text("How it works")
                            .font(.system(size: 15, weight: .bold))

                        LiveBehaviorRow(symbol: "arrow.left.and.right", title: "Horizontal",
                                        detail: "Active chats grow the notch sideways")
                        LiveBehaviorRow(symbol: "rectangle.expand.vertical", title: "Opens up",
                                        detail: "Permissions and questions drop it down")
                        LiveBehaviorRow(symbol: "checkmark.shield.fill", title: "Answer here",
                                        detail: "Approve, deny, or reply to Claude Code")
                        LiveBehaviorRow(symbol: "rectangle.stack.fill", title: "Tabs",
                                        detail: "One tab per waiting session; closes when answered")

                        Text("Codex and Gemini appear as active chats but open in their terminal to answer.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(18)
                    .frame(width: 300)
                    .appCard()
                }
            }
            .padding(28)
        }
    }
}

private struct SetupStatusRow: View {
    let symbol: String
    let title: String
    let detail: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: ok ? "checkmark.circle.fill" : symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(ok ? AppColors.mint : AppColors.amber)
                .frame(width: 28, height: 28)
                .background((ok ? AppColors.mint : AppColors.amber).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .bold))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}

private struct LiveBehaviorRow: View {
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
