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

/// The status item's menu: what is going on, each live session with its actions, the budget,
/// the window, updates, settings, and the real Quit.
struct MenuBarMenu: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var updates: Updates
    @EnvironmentObject private var lifecycle: AppLifecycle

    var body: some View {
        Text(summary)
        if let status = appState.budgetStatus {
            Text(budgetLine(status))
        }
        if !appState.liveChats.isEmpty {
            Divider()
            ForEach(appState.liveChats) { chat in
                SessionMenu(chat: chat, request: appState.pendingRequests.first { $0.sessionId == chat.id })
            }
        }
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

    /// "$42.10 of $100.00 this month, 42%", with the level named once it matters.
    private func budgetLine(_ status: BudgetStatus) -> String {
        let percent = "\(Int((status.fraction * 100).rounded()))%"
        switch status.level {
        case .over: return "Over budget: \(status.summary), \(percent)"
        case .near: return "Nearly at budget: \(status.summary), \(percent)"
        case .ok: return "\(status.summary), \(percent)"
        }
    }
}

/// One live session: its title with a status mark, and under it what it is doing, Allow and
/// Deny when it waits on a permission, Open in Terminal and Compact.
private struct SessionMenu: View {
    @EnvironmentObject private var appState: AppState
    let chat: LiveChat
    let request: PendingRequest?

    var body: some View {
        Menu {
            Text(statusLine)
            if let request {
                Text(requestLine(request))
                if request.isDecidable {
                    Button("Allow") { appState.resolve(request, with: .allow) }
                    Button("Deny") { appState.resolve(request, with: .deny) }
                } else {
                    Button("Dismiss") { appState.resolve(request, with: .deny) }
                }
            }
            Divider()
            Button("Open in Terminal") { appState.reveal(chat.session) }
            Button(compactTitle) { appState.compact(chat.session) }
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private var title: String {
        let title = chat.session.title
        return title.count > 56 ? String(title.prefix(55)).trimmingCharacters(in: .whitespaces) + "…" : title
    }

    private var symbol: String {
        switch chat.status {
        case .waiting: "exclamationmark.circle.fill"
        case .working: "circle.fill"
        case .idle: "circle"
        }
    }

    /// "Working · 43% of context · Claude Code · squish"
    private var statusLine: String {
        let status: String
        switch chat.status {
        case .waiting: status = "Waiting for an answer"
        case .working: status = "Working"
        case .idle: status = "Idle"
        }
        return [
            status,
            "\(Int(chat.session.contextFraction * 100))% of context",
            chat.session.provider.displayName,
            chat.session.projectName
        ].joined(separator: " · ")
    }

    private func requestLine(_ request: PendingRequest) -> String {
        let text = request.kind == .question ? request.inputSummary : "\(request.toolName): \(request.inputSummary)"
        return text.count > 72 ? String(text.prefix(71)) + "…" : text
    }

    private var compactTitle: String {
        if let cost = Compaction.estimatedCost(for: chat.session) {
            return "Compact (about \(currency(cost)))"
        }
        return "Compact"
    }
}
