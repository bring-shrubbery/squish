import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            AppMark(size: 88)

            Text("Welcome to Squish")
                .font(.largeTitle.weight(.bold))
                .padding(.top, 22)

            Text("Choose a folder, and Squish keeps an eye on the coding agents working in it.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 18) {
                OnboardingFeature(
                    symbol: "chart.bar",
                    title: "Sessions and costs",
                    detail: "Every Codex, Claude Code and Gemini session, priced at API rates."
                )
                OnboardingFeature(
                    symbol: "rectangle.topthird.inset.filled",
                    title: "Compact reminders",
                    detail: "A nudge from the notch before a session's context fills up."
                )
                OnboardingFeature(
                    symbol: "bubble.left.and.bubble.right",
                    title: "Live chats",
                    detail: "Approve, deny or reply to Claude Code without finding its window."
                )
                OnboardingFeature(
                    symbol: "arrow.triangle.branch",
                    title: "Worktree cleanup",
                    detail: "Find the worktrees agents left behind and reclaim the disk."
                )
            }
            .frame(width: 440)
            .padding(.top, 40)

            Button("Choose Folder…") {
                appState.chooseFolder()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 40)

            Text("Everything stays on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 12)

            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OnboardingFeature: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
