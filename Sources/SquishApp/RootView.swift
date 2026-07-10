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
                        if section == .compactAlerts && appState.alertsEnabled {
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
                            .fill(appState.selectedSection == section ? .white.opacity(0.08) : .clear)
                    )
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
    static let canvas = Color(red: 0.055, green: 0.062, blue: 0.073)
    static let sidebar = Color(red: 0.044, green: 0.049, blue: 0.059)
    static let card = Color.white.opacity(0.045)
    static let stroke = Color.white.opacity(0.075)
    static let mint = Color(red: 0.35, green: 0.89, blue: 0.65)
    static let amber = Color(red: 0.98, green: 0.68, blue: 0.28)
    static let coral = Color(red: 0.95, green: 0.44, blue: 0.43)
    static let blue = Color(red: 0.43, green: 0.62, blue: 0.98)
}

struct AppMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [AppColors.mint, Color(red: 0.23, green: 0.64, blue: 0.76)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "rectangle.compress.vertical")
                .font(.system(size: size * 0.48, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.72))
        }
        .frame(width: size, height: size)
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
