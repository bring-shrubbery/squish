import AppKit
import SquishCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var worktreeStore: WorktreeStore
    @EnvironmentObject private var lifecycle: AppLifecycle

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
            DebugSnapshots.start(appState, worktrees: worktreeStore, lifecycle: lifecycle)
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
        return count == 1 ? "1 session" : "\(count) sessions"
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

/// A settings-style page: grouped sections in a scroll view. Unlike a grouped `Form`, rows
/// inside a `LazyVStack` here are laid out only when visible, so long lists stay cheap.
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content()
            }
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }
}

/// One rounded group of rows with an optional header above and footer below, drawn like a
/// grouped form's section.
struct SettingsGroup<Content: View, Header: View, Footer: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let header: () -> Header
    @ViewBuilder let footer: () -> Footer

    init(
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder header: @escaping () -> Header = { EmptyView() },
        @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }
    ) {
        self.content = content
        self.header = header
        self.footer = footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header()
                .font(.headline)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            footer()
                .font(.callout)
                .padding(.horizontal, 4)
        }
    }
}

/// The separator between two rows of a `SettingsGroup`.
struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.vertical, 2)
    }
}

/// A row of a `SettingsGroup`: a label on the left, its control on the right.
struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 16)
            content()
        }
        .padding(.vertical, 7)
    }
}
