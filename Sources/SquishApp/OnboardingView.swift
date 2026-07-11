import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            ZStack {
                RadialGradient(
                    colors: [AppColors.pink.opacity(0.18), .clear],
                    center: .topLeading,
                    startRadius: 10,
                    endRadius: 540
                )
                RadialGradient(
                    colors: [AppColors.cyan.opacity(0.15), .clear],
                    center: .trailing,
                    startRadius: 10,
                    endRadius: 500
                )
                RadialGradient(
                    colors: [AppColors.violet.opacity(0.16), .clear],
                    center: .bottom,
                    startRadius: 10,
                    endRadius: 560
                )
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                AppMark(size: 58)
                    .shadow(color: AppColors.magenta.opacity(0.34), radius: 26, y: 8)

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
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(height: 46)
                    .background(AppColors.gasolineGradient, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.white.opacity(0.18), lineWidth: 1)
                    }
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
