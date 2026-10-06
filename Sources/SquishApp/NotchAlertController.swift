import AppKit
import SquishCore
import SwiftUI

/// The compact alert: takes the island for ten seconds (five for a preview), then gives it
/// back to whatever the live chats were showing.
@MainActor
final class NotchAlertController {
    static let shared = NotchAlertController()

    /// The alert's Compact button: sends the command to the session's terminal.
    var onCompact: ((CodingSession) -> TerminalBridge.Delivery)?

    private init() {}

    func show(session: CodingSession, threshold: Double, isPreview: Bool = false) {
        let onCompact = onCompact
        // A fresh identity per alert, so one alert's "Sent" label never carries into the next.
        let view = AnyView(
            NotchAlertView(session: session, threshold: threshold, isPreview: isPreview, onCompact: onCompact)
                .environment(\.colorScheme, .dark)
                .id("\(session.id)-\(Date().timeIntervalSinceReferenceDate)")
        )
        NotchIsland.shared.showAlert(view, for: .seconds(isPreview ? 5 : 10))
    }
}

private struct NotchAlertView: View {
    let session: CodingSession
    let threshold: Double
    let isPreview: Bool
    let onCompact: ((CodingSession) -> TerminalBridge.Delivery)?
    @State private var delivery: TerminalBridge.Delivery?

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
    }

    private var providerColor: Color {
        switch session.provider {
        case .codex: AppColors.cyan
        case .claude: AppColors.pink
        case .gemini: AppColors.blue
        }
    }
}
