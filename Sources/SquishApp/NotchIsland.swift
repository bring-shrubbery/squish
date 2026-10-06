import AppKit
import DynamicLanding
import SwiftUI

/// The one island Squish shows at the notch, shared by everything that wants it.
///
/// DynamicLanding draws one island per instance, so the live chats and the compact alert go
/// through here. The live chats own the island's standing content (hidden, the compact pill,
/// or the expanded panel); an alert takes it over for a while, and the island morphs back to
/// the standing content when the alert is done. Everything is a reshape of the same island,
/// never a second one on top.
///
/// Other apps' islands are DynamicLanding's business: each piece of content carries a
/// priority, so a passive pill gives way to another app's timer, and a permission prompt
/// holds the notch against it. A yielded island keeps its content and comes back by itself.
@MainActor
final class NotchIsland {
    static let shared = NotchIsland()

    enum Content {
        case hidden
        case compact(leading: AnyView, trailing: AnyView)
        case expanded(AnyView)
    }

    /// How much each piece of content matters next to other apps' islands.
    enum Importance {
        /// The active-sessions pill: anything may replace it.
        case passive
        /// The panel the user opened, or the compact alert.
        case normal
        /// A permission prompt or a question waiting for an answer.
        case urgent

        var priority: IslandPriority {
            switch self {
            case .passive: .background
            case .normal: .normal
            case .urgent: .urgent
            }
        }
    }

    private let island: DynamicLanding
    private var standing: Content = .hidden
    private var standingImportance: Importance = .passive
    private var alertTask: Task<Void, Never>?
    private(set) var isShowingAlert = false

    private init() {
        var configuration = IslandConfiguration()
        // Content keeps its own inner spacing small; the island adds the frame around it.
        configuration.contentPadding = EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 16)
        // A hide waits while the pointer is on the island, so a prompt or an alert being read
        // does not vanish under the cursor.
        configuration.hoverBehavior = [.keepVisible]
        // The notched display when there is one, otherwise whichever is main at each show.
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        island = DynamicLanding(configuration: configuration, screen: screen)
    }

    /// What the island shows when no alert has it. Applied at once unless an alert is up, in
    /// which case it is what the island returns to.
    func setStanding(_ content: Content, importance: Importance) {
        standing = content
        standingImportance = importance
        guard !isShowingAlert else { return }
        apply(content, importance: importance)
    }

    /// Takes the island for `duration`, then hands it back to the standing content. A newer
    /// alert replaces the one showing.
    func showAlert(_ view: AnyView, for duration: Duration) {
        alertTask?.cancel()
        isShowingAlert = true
        apply(.expanded(view), importance: .normal)
        alertTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            self.isShowingAlert = false
            self.alertTask = nil
            self.apply(self.standing, importance: self.standingImportance)
        }
    }

    /// Each call takes effect before it first suspends, so calls apply in order and the last
    /// one wins, which is the library's contract. The priority is read at each show.
    private func apply(_ content: Content, importance: Importance) {
        let island = island
        island.configuration.priority = importance.priority
        Task { @MainActor in
            switch content {
            case .hidden:
                await island.hide()
            case let .compact(leading, trailing):
                await island.show(compactLeading: { leading }, trailing: { trailing })
            case let .expanded(view):
                await island.show(expanded: { view })
            }
        }
    }
}
