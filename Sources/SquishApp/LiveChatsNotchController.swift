import AppKit
import DynamicNotchKit
import SquishCore
import SwiftUI

/// Presents the live-chats notch, driving DynamicNotchKit between the horizontal
/// (compact), detail-panel (expanded), and request-prompt (expanded) states based
/// on the current chats and pending requests.
@MainActor
final class LiveChatsNotchController {
    private typealias Notch = DynamicNotch<
        LiveChatsExpandedView,
        LiveChatsCompactLeading,
        LiveChatsCompactTrailing
    >

    private let model = LiveChatsModel()
    private var notch: Notch?
    private var panelRequested = false
    private var desiredState: DesiredState = .hidden
    private var transitionTask: Task<Void, Never>?

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

    /// Push the latest snapshot into the notch.
    func update(chats: [LiveChat], pending: [PendingRequest]) {
        model.chats = chats
        model.pending = pending
        if model.selectedTabID == nil || !pending.contains(where: { $0.id == model.selectedTabID }) {
            model.selectedTabID = pending.first?.id
        }
        reevaluate()
    }

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

    private func transition(to state: DesiredState) {
        guard state != desiredState else { return }
        desiredState = state
        let notch = ensureNotch()
        let screen = Self.preferredScreen()

        transitionTask?.cancel()
        transitionTask = Task { [weak self] in
            switch state {
            case .expanded: await notch.expand(on: screen)
            case .compact: await notch.compact(on: screen)
            case .hidden:
                await notch.hide()
                self?.notch = nil
            }
        }
    }

    private func ensureNotch() -> Notch {
        if let notch { return notch }
        let model = model
        let created = Notch(
            hoverBehavior: [.keepVisible],
            expanded: { LiveChatsExpandedView(model: model) },
            compactLeading: { LiveChatsCompactLeading(model: model) },
            compactTrailing: { LiveChatsCompactTrailing(model: model) }
        )
        notch = created
        return created
    }

    private static func preferredScreen() -> NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}
