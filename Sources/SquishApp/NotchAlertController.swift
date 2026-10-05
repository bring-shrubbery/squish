import AppKit
import DynamicNotchKit
import SquishCore
import SwiftUI

@MainActor
final class NotchAlertController {
    static let shared = NotchAlertController()

    private typealias AlertNotch = DynamicNotch<AnyView, EmptyView, EmptyView>

    private var notch: AlertNotch?
    private var presentationTask: Task<Void, Never>?

    /// Called just before an alert takes over the notch, so another notch (e.g.
    /// live chats) can step aside and be replaced rather than overlaid.
    var onWillShow: (() -> Void)?
    /// Called once the alert has fully hidden and nothing is replacing it.
    var onDidHide: (() -> Void)?
    /// The alert's Compact button: sends the command to the session's terminal.
    var onCompact: ((CodingSession) -> CompactionSender.Delivery)?

    private init() {}

    func show(session: CodingSession, threshold: Double, isPreview: Bool = false) {
        presentationTask?.cancel()
        onWillShow?()

        let previousNotch = notch
        let onCompact = onCompact
        let nextNotch = AlertNotch(style: .notch) {
            AnyView(
                NotchAlertView(session: session, threshold: threshold, isPreview: isPreview, onCompact: onCompact)
                    .environment(\.colorScheme, .dark)
            )
        }
        notch = nextNotch

        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        presentationTask = Task { [weak self] in
            if let previousNotch { await previousNotch.hide() }
            guard !Task.isCancelled else { return }
            await nextNotch.expand(on: screen)

            do {
                try await Task.sleep(for: .seconds(isPreview ? 5 : 10))
            } catch {
                // Cancelled because a newer alert is replacing this one; that
                // newer show() already fired onWillShow, so don't resume here.
                return
            }

            await nextNotch.hide()
            if self?.notch === nextNotch {
                self?.notch = nil
                self?.onDidHide?()
            }
        }
    }
}

private struct NotchAlertView: View {
    let session: CodingSession
    let threshold: Double
    let isPreview: Bool
    let onCompact: ((CodingSession) -> CompactionSender.Delivery)?
    @State private var delivery: CompactionSender.Delivery?

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(providerColor.opacity(0.2))
                Image(systemName: "arrow.down.message.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(providerColor)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(isPreview ? "PREVIEW" : "COMPACT SOON")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(providerColor)
                    Text(session.provider.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }

                Text(session.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 7) {
                    ProgressView(value: session.contextFraction)
                        .progressViewStyle(.linear)
                        .tint(providerColor)
                        .frame(width: 120)
                    Text("\(Int(session.contextFraction * 100))% context")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .fixedSize()
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 5) {
                Button {
                    guard delivery == nil else { return }
                    delivery = onCompact?(session)
                } label: {
                    Text(delivery?.label ?? Compaction.command(for: session.provider))
                        .font(.system(size: 12, weight: .semibold, design: delivery == nil ? .monospaced : .default))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            (delivery == nil ? providerColor.opacity(0.35) : Color.white.opacity(0.11)),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(delivery == nil ? "Send the command to the session's terminal" : "")
                if let estimate = Compaction.estimatedCost(for: session) {
                    Text("about \(currency(estimate))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: 390)
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var providerColor: Color {
        switch session.provider {
        case .codex: AppColors.cyan
        case .claude: AppColors.pink
        case .gemini: AppColors.blue
        }
    }
}
