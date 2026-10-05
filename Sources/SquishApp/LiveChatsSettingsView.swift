import SquishCore
import SwiftUI

struct LiveChatsSettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsPage {
            SettingsGroup {
                SettingsRow("Show live chats in the notch") {
                    Toggle("Show live chats in the notch", isOn: $appState.liveChatsEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingsDivider()
                HookRow(name: "Claude Code hook", status: appState.hookInstaller.status(for: .claude))
                SettingsDivider()
                HookRow(name: "Codex hook", status: appState.hookInstaller.status(for: .codex))
                SettingsDivider()
                HookRow(name: "Gemini CLI hook", status: appState.hookInstaller.status(for: .gemini))
                SettingsDivider()
                SettingsRow("Accessibility") {
                    HStack(spacing: 10) {
                        SetupStatus(
                            ok: appState.liveChatsAccessibilityGranted,
                            text: appState.liveChatsAccessibilityGranted ? "Granted" : "Not granted"
                        )
                        if !appState.liveChatsAccessibilityGranted {
                            Button("Grant…") { appState.hookInstaller.requestAccessibility() }
                        }
                    }
                }
                SettingsDivider()
                SettingsRow("Preview") {
                    Button("Show a Request") { appState.previewLiveChat() }
                        .disabled(!appState.liveChatsEnabled)
                }
            } footer: {
                FormFooter(
                    "Active chats widen the notch. When Claude Code or Codex asks for permission, or "
                        + "Claude Code asks a question, the notch opens so you can approve, deny or reply, "
                        + "one tab per waiting session. Gemini CLI only reports that it is waiting; the "
                        + "answer goes in its terminal. Turning this on adds a hook to ~/.claude/settings.json, "
                        + "~/.codex/hooks.json (with hooks enabled in config.toml) and ~/.gemini/settings.json "
                        + "for the agents you have. Accessibility lets Squish type replies into the "
                        + "terminal; approvals work without it."
                )
            }
        }
        .navigationSubtitle(appState.liveChatsEnabled ? "On" : "Off")
    }
}

private struct HookRow: View {
    let name: String
    let status: HookInstaller.Status

    var body: some View {
        SettingsRow(name) {
            switch status {
            case .installed:
                SetupStatus(ok: true, text: "Installed")
            case .notInstalled:
                SetupStatus(ok: false, text: "Not installed")
            case .agentNotFound:
                Text("Not found")
                    .foregroundStyle(.tertiary)
            case .needsManualStep:
                SetupStatus(ok: false, text: "Add hooks = true under [features] in ~/.codex/config.toml")
            }
        }
    }
}

private struct SetupStatus: View {
    let ok: Bool
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}
