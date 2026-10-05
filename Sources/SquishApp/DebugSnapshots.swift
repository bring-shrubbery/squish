#if DEBUG
import AppKit
import SwiftUI

/// Lets a script drive the window and save pictures of it, for checking the UI without
/// screen-recording access. Debug builds only. Run with `SQUISH_SNAPSHOT_DIR=/dir`, then
/// append lines to `/dir/commands`:
///
///   folder <path>     watch a folder without saving the choice
///   section <costs|compactAlerts|liveChats|worktrees>
///   appearance <light|dark>
///   select <n>       selects the first n rows of the Worktrees table
///   filters          toggles the Worktrees filter popover
///   remove           opens the removal confirmation for the selection
///   snap <name>      writes <name>-<n>.png for every visible window (main window, popovers, sheets)
///   quit
@MainActor
enum DebugSnapshots {
    static let filtersNotification = Notification.Name("squish.debug.filters")
    static let removeNotification = Notification.Name("squish.debug.remove")

    private static var handled = 0
    private static var timer: Timer?

    static func start(_ appState: AppState, worktrees: WorktreeStore) {
        guard timer == nil, let dir = ProcessInfo.processInfo.environment["SQUISH_SNAPSHOT_DIR"] else { return }
        let commands = URL(fileURLWithPath: dir).appendingPathComponent("commands")
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                let lines = (try? String(contentsOf: commands, encoding: .utf8))?
                    .split(separator: "\n").map(String.init) ?? []
                while handled < lines.count {
                    run(lines[handled], appState: appState, worktrees: worktrees, dir: dir)
                    handled += 1
                }
            }
        }
    }

    private static func run(_ line: String, appState: AppState, worktrees: WorktreeStore, dir: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let command = parts.first else { return }
        let argument = parts.count > 1 ? parts[1] : ""
        switch command {
        case "folder":
            appState.debugSetProjectRoot(URL(fileURLWithPath: argument))
        case "section":
            if let section = AppSection(rawValue: argument) { appState.selectedSection = section }
        case "appearance":
            NSApp.appearance = NSAppearance(named: argument == "dark" ? .darkAqua : .aqua)
        case "select":
            worktrees.selection = Set(worktrees.visibleWorktrees.prefix(Int(argument) ?? 0).map(\.path))
        case "filters":
            NotificationCenter.default.post(name: filtersNotification, object: nil)
        case "remove":
            NotificationCenter.default.post(name: removeNotification, object: nil)
        case "snap":
            snap(named: argument, into: dir)
        case "quit":
            NSApp.terminate(nil)
        default:
            break
        }
    }

    private static func snap(named name: String, into dir: String) {
        for (index, window) in NSApp.windows.filter(\.isVisible).enumerated() {
            guard let content = window.contentView else { continue }
            let view = content.superview ?? content
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(index).png")
            try? data.write(to: url)
        }
    }
}
#endif
