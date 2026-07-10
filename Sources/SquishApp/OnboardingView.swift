import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [AppColors.mint.opacity(0.12), .clear],
                center: .top,
                startRadius: 20,
                endRadius: 520
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                AppMark(size: 58)
                    .shadow(color: AppColors.mint.opacity(0.2), radius: 24, y: 8)

                Text("Keep every coding session in view")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .padding(.top, 22)

                Text("Choose a folder once. Squish finds its agent sessions,\ntracks API cost, and warns you before context gets cramped.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.top, 10)

                HStack(spacing: 12) {
                    OnboardingFeature(symbol: "scope", title: "Auto-detect", detail: "Codex, Claude & Gemini")
                    OnboardingFeature(symbol: "dollarsign.circle", title: "Know the cost", detail: "Per session and model")
                    OnboardingFeature(symbol: "rectangle.topthird.inset.filled", title: "Compact in time", detail: "Live notch reminders")
                }
                .padding(.top, 34)

                Button {
                    appState.chooseFolder()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "folder.badge.plus")
                        Text("Choose folder to monitor")
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black.opacity(0.82))
                    .padding(.horizontal, 20)
                    .frame(height: 46)
                    .background(AppColors.mint, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.top, 32)

                Text("Session contents stay on this Mac.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 13)

                Spacer()
            }
            .padding(40)
        }
    }
}

private struct OnboardingFeature: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppColors.mint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 184, height: 106, alignment: .leading)
        .appCard()
    }
}
