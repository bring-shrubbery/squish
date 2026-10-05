import SwiftUI

@main
struct SquishApplication: App {
    @StateObject private var appState = AppState()
    @StateObject private var updates = Updates()
    @StateObject private var worktreeStore = WorktreeStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(worktreeStore)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
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
        }
    }
}
