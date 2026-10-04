import SwiftUI

@main
struct SquishApplication: App {
    @StateObject private var appState = AppState()
    @StateObject private var updates = Updates()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 980, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
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
