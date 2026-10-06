import SwiftUI

@main
struct SquishApplication: App {
    @StateObject private var appState = AppState()
    @StateObject private var updates = Updates()
    @StateObject private var worktreeStore = WorktreeStore()
    @StateObject private var lifecycle = AppLifecycle()

    var body: some Scene {
        WindowGroup(id: AppLifecycle.mainWindowID) {
            RootView()
                .environmentObject(appState)
                .environmentObject(worktreeStore)
                .environmentObject(lifecycle)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            SquishCommands(appState: appState, updates: updates, lifecycle: lifecycle)
        }

        Settings {
            GeneralSettingsView()
                .environmentObject(lifecycle)
                .environmentObject(appState)
        }

        MenuBarExtra(isInserted: menuBarItemIsInserted) {
            MenuBarMenu()
                .environmentObject(appState)
                .environmentObject(updates)
                .environmentObject(lifecycle)
        } label: {
            MenuBarLabel()
                .environmentObject(appState)
                .environmentObject(lifecycle)
        }
    }
}

extension SquishApplication {
    /// `MenuBarExtra` writes this binding on every pass through the scene body; publishing
    /// the same value again would re-run the body, and so on without end.
    private var menuBarItemIsInserted: Binding<Bool> {
        Binding(
            get: { lifecycle.keepsRunning },
            set: { if $0 != lifecycle.keepsRunning { lifecycle.keepsRunning = $0 } }
        )
    }
}

/// The app's menu items. A separate type: inlining three groups in `.commands` made the
/// Swift runtime recurse without end while resolving the closure's opaque type at launch.
private struct SquishCommands: Commands {
    @ObservedObject var appState: AppState
    @ObservedObject var updates: Updates
    @ObservedObject var lifecycle: AppLifecycle

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                updates.check()
            }
            .disabled(!updates.canCheckForUpdates)
        }
        CommandGroup(after: .newItem) {
            Button("Choose Project Folder…") {
                appState.chooseFolder()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        // ⌘Q leaves Squish in the menu bar; the menu bar item's Quit Squish quits.
        CommandGroup(replacing: .appTermination) {
            Button("Quit Squish") {
                lifecycle.quitCommand()
            }
            .keyboardShortcut("q")
        }
    }
}
