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
                SettingsRow("Claude Code hook") {
                    SetupStatus(
                        ok: appState.liveChatsHookInstalled,
                        text: appState.liveChatsHookInstalled ? "Installed" : "Not installed"
                    )
                }
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
                    "Active chats widen the notch. When Claude Code asks for permission or a question, "
                        + "the notch opens so you can approve, deny or reply, one tab per waiting session. "
                        + "Turning this on adds a hook to ~/.claude/settings.json. Accessibility lets Squish "
                        + "type replies into the terminal; approvals work without it. Codex and Gemini are "
                        + "listed but answer in their own terminal."
                )
            }
        }
        .navigationSubtitle(appState.liveChatsEnabled ? "On" : "Off")
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
