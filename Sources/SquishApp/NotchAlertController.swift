import AppKit
import SquishCore
import SwiftUI

@MainActor
final class NotchAlertController {
    static let shared = NotchAlertController()

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(session: CodingSession, threshold: Double, isPreview: Bool = false) {
        dismissTask?.cancel()
        panel?.orderOut(nil)

        let size = NSSize(width: 420, height: 108)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(
            rootView: NotchAlertView(session: session, threshold: threshold, isPreview: isPreview)
        )

        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - 4
        ))
        panel.orderFrontRegardless()
        self.panel = panel

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: isPreview ? 5_000_000_000 : 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
            self?.panel = nil
        }
    }
}

private struct NotchAlertView: View {
    let session: CodingSession
    let threshold: Double
    let isPreview: Bool

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
                        .frame(width: 150)
                    Text("\(Int(session.contextFraction * 100))% context")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            Spacer(minLength: 4)

            Text("/compact")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.09), lineWidth: 1)
                )
        )
        .padding(8)
    }

    private var providerColor: Color {
        switch session.provider {
        case .codex: AppColors.cyan
        case .claude: AppColors.pink
        case .gemini: AppColors.blue
        }
    }
}
