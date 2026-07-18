import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.projectRoot == nil {
                OnboardingView()
            } else {
                DashboardShell()
            }
        }
        .background(AppColors.canvas)
        .preferredColorScheme(.dark)
    }
}

struct DashboardShell: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 224)

            Divider().overlay(.white.opacity(0.05))

            Group {
                switch appState.selectedSection {
                case .costs:
                    CostDashboardView()
                case .compactAlerts:
                    CompactAlertsView()
                case .liveChats:
                    LiveChatsSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppMark(size: 30)
                Text("Squish")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 28)

            Text("WORKSPACE")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.25)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.bottom, 9)

            ForEach(AppSection.allCases) { section in
                Button {
                    appState.selectedSection = section
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 18)
                        Text(section.title)
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        if (section == .compactAlerts && appState.alertsEnabled)
                            || (section == .liveChats && appState.liveChatsEnabled) {
                            Circle()
                                .fill(AppColors.mint)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .foregroundStyle(appState.selectedSection == section ? .white : .secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(appState.selectedSection == section ? AppColors.violet.opacity(0.2) : .clear)
                            .overlay {
                                if appState.selectedSection == section {
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(AppColors.cyan.opacity(0.16), lineWidth: 1)
                                }
                            }
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(appState.isScanning ? AppColors.amber : AppColors.mint)
                        .frame(width: 7, height: 7)
                    Text(appState.isScanning ? "Finding sessions…" : "Watching live")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Text("\(appState.sessions.count) sessions detected")
                    .font(.system(size: 12, weight: .semibold))

                Button("Change folder…") {
                    appState.chooseFolder()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColors.mint)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.14))
        }
        .background(AppColors.sidebar)
    }
}

struct PageHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.25)
                    .foregroundStyle(AppColors.mint)
                Text(title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

enum AppColors {
    static let canvas = Color(red: 0.035, green: 0.043, blue: 0.10)
    static let sidebar = Color(red: 0.045, green: 0.052, blue: 0.125)
    static let card = Color(red: 0.12, green: 0.13, blue: 0.25).opacity(0.42)
    static let stroke = Color(red: 0.64, green: 0.48, blue: 0.82).opacity(0.22)

    static let cyan = Color(red: 0.12, green: 0.72, blue: 0.78)
    static let blue = Color(red: 0.31, green: 0.30, blue: 0.75)
    static let violet = Color(red: 0.63, green: 0.41, blue: 0.70)
    static let magenta = Color(red: 0.75, green: 0.40, blue: 0.70)
    static let pink = Color(red: 0.87, green: 0.60, blue: 0.69)
    static let peach = Color(red: 0.91, green: 0.59, blue: 0.56)

    // Semantic aliases used by status views.
    static let mint = cyan
    static let amber = peach
    static let coral = magenta

    static let gasolineGradient = LinearGradient(
        colors: [pink, magenta, violet, blue, cyan],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct AppMark: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
               let icon = NSImage(contentsOf: iconURL) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .fill(AppColors.gasolineGradient)
                    Image(systemName: "rectangle.compress.vertical")
                        .font(.system(size: size * 0.48, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.72))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppColors.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppColors.stroke, lineWidth: 1)
                    )
            )
    }
}

extension View {
    func appCard() -> some View { modifier(CardModifier()) }
}
