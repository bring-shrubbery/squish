import AppKit
import SquishCore
import SwiftUI

/// Presents the live chats in the island: the compact pill while sessions are active, the
/// detail panel when asked, and the request prompt whenever something waits for an answer.
///
/// The views observe `LiveChatsModel`, so the island's content is set only when the state
/// changes; everything inside updates in place.
@MainActor
final class LiveChatsNotchController {
    private let model = LiveChatsModel()
    private var panelRequested = false
    private var desired: (state: DesiredState, importance: NotchIsland.Importance) = (.hidden, .passive)

    private enum DesiredState: Equatable { case hidden, compact, expanded }

    /// Wire the resolve callback once at construction (from AppState).
    func configure(onResolve: @escaping (PendingRequest, AgentDecision) -> Void,
                   onOpenTerminal: @escaping (LiveChat) -> Void) {
        model.onResolve = { [weak self] request, decision in
            onResolve(request, decision)
            // Optimistically advance the selected tab and re-evaluate.
            self?.model.pending.removeAll { $0.id == request.id }
            self?.reevaluate()
        }
        model.onOpenTerminal = onOpenTerminal
        model.onExpandRequested = { [weak self] in
            self?.panelRequested = true
            self?.reevaluate()
        }
        model.onCollapseRequested = { [weak self] in
            self?.panelRequested = false
            self?.reevaluate()
        }
    }

    /// Push the latest snapshot into the island.
    func update(chats: [LiveChat], pending: [PendingRequest]) {
        model.chats = chats
        model.pending = pending
        if model.selectedTabID == nil || !pending.contains(where: { $0.id == model.selectedTabID }) {
            model.selectedTabID = pending.first?.id
        }
        reevaluate()
    }

    #if DEBUG
    /// For `DebugSnapshots`: what tapping the compact pill does.
    func debugExpand() { model.onExpandRequested?() }
    #endif

    // MARK: - State machine

    private func reevaluate() {
        if !model.pending.isEmpty {
            model.mode = .prompt
            if model.selectedTabID == nil || !model.pending.contains(where: { $0.id == model.selectedTabID }) {
                model.selectedTabID = model.pending.first?.id
            }
            transition(to: .expanded)
        } else if panelRequested, !model.chats.isEmpty {
            model.mode = .panel
            transition(to: .expanded)
        } else if !model.chats.isEmpty {
            panelRequested = false
            transition(to: .compact)
        } else {
            panelRequested = false
            transition(to: .hidden)
        }
    }

    /// Sets the island's standing content when the state changes, or when the same state
    /// comes to matter more or less (a prompt opening inside the panel), which re-shows the
    /// same content under the new priority.
    private func transition(to state: DesiredState) {
        // A prompt must hold the notch against other apps; the panel the user opened and the
        // pill need not.
        let importance: NotchIsland.Importance = switch state {
        case .hidden, .compact: .passive
        case .expanded: model.mode == .prompt ? .urgent : .normal
        }
        guard state != desired.state || importance != desired.importance else { return }
        desired = (state, importance)
        let model = model
        switch state {
        case .hidden:
            NotchIsland.shared.setStanding(.hidden, importance: importance)
        case .compact:
            NotchIsland.shared.setStanding(.compact(
                leading: AnyView(LiveChatsCompactLeading(model: model)),
                trailing: AnyView(LiveChatsCompactTrailing(model: model))
            ), importance: importance)
        case .expanded:
            NotchIsland.shared.setStanding(.expanded(AnyView(LiveChatsExpandedView(model: model))), importance: importance)
        }
    }
}
