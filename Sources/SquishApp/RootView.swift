import AppKit
import SquishCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var worktreeStore: WorktreeStore

    var body: some View {
        Group {
            if appState.projectRoot == nil {
                OnboardingView()
            } else {
                DashboardShell()
            }
        }
        .onAppear {
            #if DEBUG
            DebugSnapshots.start(appState, worktrees: worktreeStore)
            #endif
        }
    }
}

struct DashboardShell: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var worktreeStore: WorktreeStore

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
        } detail: {
            Group {
                switch appState.selectedSection {
                case .costs:
                    CostDashboardView()
                case .compactAlerts:
                    CompactAlertsView()
                case .liveChats:
                    LiveChatsSettingsView()
                case .worktrees:
                    WorktreesView()
                }
            }
            .navigationTitle(appState.selectedSection.title)
        }
        .onAppear {
            worktreeStore.update(root: appState.projectRoot, sessions: appState.sessions)
        }
        .onReceive(appState.$projectRoot) { root in
            worktreeStore.update(root: root, sessions: appState.sessions)
        }
        .onReceive(appState.$sessions) { sessions in
            worktreeStore.update(root: appState.projectRoot, sessions: sessions)
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var worktreeStore: WorktreeStore

    var body: some View {
        List(selection: selection) {
            ForEach(AppSection.allCases) { section in
                Label(section.title, systemImage: section.symbol)
                    .badge(section == .worktrees ? worktreeStore.flaggedCount : 0)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FolderFooter()
        }
    }

    private var selection: Binding<AppSection?> {
        Binding(
            get: { appState.selectedSection },
            set: { if let section = $0 { appState.selectedSection = section } }
        )
    }
}

/// The watched folder, pinned under the sidebar like a navigator's filter bar.
private struct FolderFooter: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(appState.projectRoot?.lastPathComponent ?? "")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help(appState.projectRoot?.path ?? "")
                Spacer(minLength: 4)
                Menu {
                    Button("Choose Folder…") { appState.chooseFolder() }
                    Button("Show in Finder") {
                        if let root = appState.projectRoot {
                            NSWorkspace.shared.activateFileViewerSelecting([root])
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private var status: String {
        if appState.isScanning { return "Scanning…" }
        let count = appState.sessions.count
        return count == 1 ? "1 active session" : "\(count) active sessions"
    }
}

/// The notch overlays draw on black, outside the window; they keep their own palette.
enum AppColors {
    static let cyan = Color(red: 0.12, green: 0.72, blue: 0.78)
    static let blue = Color(red: 0.31, green: 0.30, blue: 0.75)
    static let violet = Color(red: 0.63, green: 0.41, blue: 0.70)
    static let magenta = Color(red: 0.75, green: 0.40, blue: 0.70)
    static let pink = Color(red: 0.87, green: 0.60, blue: 0.69)
    static let peach = Color(red: 0.91, green: 0.59, blue: 0.56)

    // Semantic aliases used by the notch views.
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

/// A provider's initial in a quiet rounded square, for session rows.
struct ProviderIcon: View {
    let provider: AgentProvider

    var body: some View {
        Text(String(provider.displayName.prefix(1)))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A grouped form's explanatory text, leading-aligned under its section.
struct FormFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
