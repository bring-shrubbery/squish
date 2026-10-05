import AppKit
import SquishCore
import SwiftUI

/// The status item: the app's mark, with the number of sessions waiting for an answer.
struct MenuBarLabel: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var lifecycle: AppLifecycle
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let waiting = appState.waitingRequestCount
        Label {
            if waiting > 0 { Text("\(waiting)") }
        } icon: {
            Image(systemName: "rectangle.compress.vertical")
        }
        .labelStyle(.titleAndIcon)
        .onAppear {
            lifecycle.openMainWindow = { openWindow(id: AppLifecycle.mainWindowID) }
        }
    }
}

/// The status item's menu: what is going on, the window, updates, settings, and the real Quit.
struct MenuBarMenu: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var updates: Updates
    @EnvironmentObject private var lifecycle: AppLifecycle

    var body: some View {
        Text(summary)
        Divider()
        Button("Open Squish") {
            lifecycle.open()
        }
        Divider()
        Button("Check for Updates…") {
            updates.check()
        }
        .disabled(!updates.canCheckForUpdates)
        SettingsLink {
            Text("Settings…")
        }
        Divider()
        Button("Quit Squish") {
            lifecycle.quit()
        }
    }

    private var summary: String {
        guard let root = appState.projectRoot else { return "No folder chosen" }
        if appState.isScanning { return "Scanning \(root.lastPathComponent)…" }
        let active = appState.activeSessionCount
        let waiting = appState.waitingRequestCount
        var parts: [String] = []
        switch active {
        case 0: parts.append("No active sessions")
        case 1: parts.append("1 active session")
        default: parts.append("\(active) active sessions")
        }
        switch waiting {
        case 0: break
        case 1: parts.append("1 waiting for an answer")
        default: parts.append("\(waiting) waiting for an answer")
        }
        return parts.joined(separator: ", ")
    }
}
