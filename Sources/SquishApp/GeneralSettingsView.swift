import SwiftUI

/// Squish → Settings… (⌘,): how the app stays around.
struct GeneralSettingsView: View {
    @EnvironmentObject private var lifecycle: AppLifecycle

    var body: some View {
        Form {
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
                    "⌘Q closes the window and leaves Squish in the menu bar, where it keeps watching "
                        + "your sessions for compact alerts and live chats. Quit it from the menu bar "
                        + "icon. With this off, ⌘Q quits."
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            lifecycle.refreshLoginItem()
        }
    }

    private var opensAtLogin: Binding<Bool> {
        Binding(
            get: { lifecycle.loginItem == .on || lifecycle.loginItem == .needsApproval },
            set: { lifecycle.setOpensAtLogin($0) }
        )
    }
}
