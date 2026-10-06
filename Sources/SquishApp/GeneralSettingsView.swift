import SwiftUI

/// Squish → Settings… (⌘,): how the app stays around.
struct GeneralSettingsView: View {
    @EnvironmentObject private var lifecycle: AppLifecycle
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            NotificationSettings(notifier: appState.notifier)

            Section {
                Toggle("Keep running in the menu bar", isOn: $lifecycle.keepsRunning)
                Toggle("Open at login", isOn: opensAtLogin)
                    .disabled(lifecycle.loginItem == .unavailable)
                if lifecycle.loginItem == .needsApproval {
                    LabeledContent("Waiting for approval in System Settings") {
                        Button("Open System Settings…") { lifecycle.openLoginItemsSettings() }
                    }
                }
            } footer: {
                FormFooter(
                    "Closing the window, with ⌘W or ⌘Q, leaves Squish in the menu bar without a Dock "
                        + "icon, still watching your sessions for compact alerts and live chats. Open or "
                        + "quit it from the menu bar icon. With this off, ⌘Q quits and the Dock icon stays."
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            lifecycle.refreshLoginItem()
            appState.notifier.refreshAuthorization()
        }
    }

    private var opensAtLogin: Binding<Bool> {
        Binding(
            get: { lifecycle.loginItem == .on || lifecycle.loginItem == .needsApproval },
            set: { lifecycle.setOpensAtLogin($0) }
        )
    }
}

/// The notification toggles; a view of its own so it observes the notifier directly.
private struct NotificationSettings: View {
    @ObservedObject var notifier: SessionNotifier

    var body: some View {
        Section {
            Toggle("When a session finishes", isOn: $notifier.notifiesFinished)
            Toggle("When a session waits for input", isOn: $notifier.notifiesWaiting)
            if notifier.authorization == .denied, notifier.isEnabled {
                LabeledContent("Turned off for Squish in System Settings") {
                    Button("Open System Settings…") { notifier.openSystemSettings() }
                }
            }
        } header: {
            Text("Notify Me")
        } footer: {
            FormFooter(
                "Each notification names the session and what it said; clicking one opens its "
                    + "terminal. Turning these on adds a hook to the agents you have, as Live Chats "
                    + "does, so the agent itself reports finishing or waiting."
            )
        }
    }
}
