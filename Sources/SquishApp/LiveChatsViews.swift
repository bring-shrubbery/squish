import SquishCore
import SwiftUI

/// Shared, observable state backing the live-chats notch. The notch content views
/// observe this object so the notch updates in place as chats and requests change.
@MainActor
final class LiveChatsModel: ObservableObject {
    enum Mode { case panel, prompt }

    @Published var chats: [LiveChat] = []
    @Published var pending: [PendingRequest] = []
    @Published var mode: Mode = .panel
    @Published var selectedTabID: String?

    /// Called when the user resolves a request (approve / deny / answer).
    var onResolve: ((PendingRequest, AgentDecision) -> Void)?
    /// Called when the compact pill is tapped to open the detail panel.
    var onExpandRequested: (() -> Void)?
    /// Called when the panel's close chevron is tapped.
    var onCollapseRequested: (() -> Void)?
    /// Called to deep-link a non-interactive provider out to its terminal.
    var onOpenTerminal: ((LiveChat) -> Void)?

    var selectedRequest: PendingRequest? {
        pending.first { $0.id == selectedTabID } ?? pending.first
    }
}

func liveProviderColor(_ provider: AgentProvider) -> Color {
    switch provider {
    case .codex: AppColors.cyan
    case .claude: AppColors.pink
    case .gemini: AppColors.blue
    }
}

// MARK: - Compact (horizontal) content

struct LiveChatsCompactLeading: View {
    @ObservedObject var model: LiveChatsModel
    @State private var pulse = false

    private var isCoding: Bool { model.chats.contains { $0.status == .working } }

    var body: some View {
        HStack(spacing: -4) {
            ForEach(model.chats.prefix(4)) { chat in
                Circle()
                    .fill(liveProviderColor(chat.session.provider))
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1.5))
                    .opacity(chat.status == .idle ? 0.55 : 1)
                    .scaleEffect(chat.status == .working && pulse ? 1.18 : 1)
            }
        }
        .padding(.leading, 6)
        .contentShape(Rectangle())
        .onTapGesture { model.onExpandRequested?() }
        .onAppear { updatePulse() }
        .onChange(of: isCoding) { updatePulse() }
    }

    private func updatePulse() {
        if isCoding {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                pulse = true
            }
        } else {
            withAnimation(.default) { pulse = false }
        }
    }
}

struct LiveChatsCompactTrailing: View {
    @ObservedObject var model: LiveChatsModel

    private var waitingCount: Int { model.chats.filter { $0.status == .waiting }.count }

    var body: some View {
        HStack(spacing: 5) {
            if waitingCount > 0 {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppColors.peach)
            }
            Text("\(model.chats.count)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.trailing, 6)
        .contentShape(Rectangle())
        .onTapGesture { model.onExpandRequested?() }
    }
}

// MARK: - Expanded content (panel or prompt)

struct LiveChatsExpandedView: View {
    @ObservedObject var model: LiveChatsModel

    var body: some View {
        Group {
            switch model.mode {
            case .prompt: RequestPromptView(model: model)
            case .panel: LiveChatsPanelView(model: model)
            }
        }
        .frame(width: 380)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .environment(\.colorScheme, .dark)
    }
}

struct LiveChatsPanelView: View {
    @ObservedObject var model: LiveChatsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ACTIVE CHATS")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Button {
                    model.onCollapseRequested?()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }

            if model.chats.isEmpty {
                Text("No active sessions")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                ForEach(model.chats) { chat in
                    LiveChatRow(chat: chat, model: model)
                }
            }
        }
    }
}

private struct LiveChatRow: View {
    let chat: LiveChat
    @ObservedObject var model: LiveChatsModel

    private var pendingForChat: PendingRequest? {
        model.pending.first { $0.sessionId == chat.session.id }
    }

    var body: some View {
        HStack(spacing: 11) {
            Circle()
                .fill(liveProviderColor(chat.session.provider))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(chat.session.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(chat.session.projectName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                    Text("\(Int(chat.session.contextFraction * 100))%")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            Spacer(minLength: 6)

            statuscontrol
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statuscontrol: some View {
        if chat.session.provider == .claude, let request = pendingForChat {
            HStack(spacing: 6) {
                Button("Deny") { model.onResolve?(request, .deny) }
                    .buttonStyle(NotchButtonStyle(tint: AppColors.magenta))
                Button("Allow") { model.onResolve?(request, .allow) }
                    .buttonStyle(NotchButtonStyle(tint: AppColors.cyan))
            }
        } else if pendingForChat != nil {
            Button("Open") { model.onOpenTerminal?(chat) }
                .buttonStyle(NotchButtonStyle(tint: .white.opacity(0.14)))
        } else {
            StatusChip(status: chat.status)
        }
    }
}

private struct StatusChip: View {
    let status: LiveStatus

    private var label: String {
        switch status {
        case .working: "Working"
        case .waiting: "Waiting"
        case .idle: "Idle"
        }
    }

    private var color: Color {
        switch status {
        case .working: AppColors.cyan
        case .waiting: AppColors.peach
        case .idle: .white.opacity(0.4)
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }
}

// MARK: - Request prompt (vertical-open)

struct RequestPromptView: View {
    @ObservedObject var model: LiveChatsModel
    @State private var answer: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.pending.count > 1 { tabStrip }

            if let request = model.selectedRequest {
                body(for: request)
            } else {
                Text("No pending requests")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 6) {
            ForEach(model.pending) { request in
                let selected = request.id == model.selectedRequest?.id
                Button {
                    model.selectedTabID = request.id
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(AppColors.pink)
                            .frame(width: 6, height: 6)
                        Text(shortLabel(for: request))
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(
                        Capsule().fill(.white.opacity(selected ? 0.16 : 0.05))
                    )
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.6))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func body(for request: PendingRequest) -> some View {
        let isQuestion = request.kind == .question
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: isQuestion ? "questionmark.bubble.fill" : "lock.shield.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.pink)
                Text(isQuestion ? "Question" : request.toolName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
            }

            Text(request.inputSummary)
                .font(.system(size: isQuestion ? 13 : 12,
                              weight: isQuestion ? .semibold : .medium,
                              design: isQuestion ? .default : .monospaced))
                .foregroundStyle(.white.opacity(isQuestion ? 0.95 : 0.8))
                .lineLimit(isQuestion ? 4 : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))

            if isQuestion {
                answerField(for: request)
            } else {
                permissionButtons(for: request)
            }
        }
    }

    private func permissionButtons(for request: PendingRequest) -> some View {
        HStack(spacing: 8) {
            Button("Deny") { model.onResolve?(request, .deny) }
                .buttonStyle(NotchButtonStyle(tint: AppColors.magenta))
            Button("Allow") { model.onResolve?(request, .allow) }
                .buttonStyle(NotchButtonStyle(tint: AppColors.cyan))
        }
    }

    private func answerField(for request: PendingRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let options = request.options, !options.isEmpty {
                VStack(spacing: 6) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        Button {
                            model.onResolve?(request, .answer(option))
                            answer = ""
                        } label: {
                            HStack(spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .frame(width: 16)
                                Text(option)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Type an answer…", text: $answer)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit { submit(request) }
                Button("Send") { submit(request) }
                    .buttonStyle(NotchButtonStyle(tint: AppColors.cyan))
                    .disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func submit(_ request: PendingRequest) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.onResolve?(request, .answer(text))
        answer = ""
    }

    private func shortLabel(for request: PendingRequest) -> String {
        let name = URL(fileURLWithPath: request.cwd).lastPathComponent
        return name.isEmpty ? request.toolName : name
    }
}

// MARK: - Styling

struct NotchButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(tint.opacity(configuration.isPressed ? 0.4 : 0.85), in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
