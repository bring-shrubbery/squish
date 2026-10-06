#if DEBUG
import AppKit
import SquishCore
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
///   unpriced         toggles the Costs page's unpriced-models popover
///   period <today|week|month|all>   selects the Costs page's period
///   budget <amount> <today|week|month>   sets the spending limit; "budget none" removes it
///   budgeteditor     toggles the Costs page's budget popover
///   previewalert     shows the compact alert in the notch, as the Preview button does
///   chats <compact|expanded|prompt|off>   puts made-up live chats in the island
///   quitcommand      what the app menu's Quit Squish (⌘Q) does
///   open             what the menu bar item's Open Squish does
///   closewindow      closes the main window, as ⌘W does
///   front            appends the frontmost app and the window count to <dir>/front.log
///   sheet <1|2>      presses the first or second button of the window's alert sheet
///   settings         opens the Settings window
///   scroll <dy> [n]  posts n scroll-wheel events of dy points to the window (default 1)
///   hover <x> <y>    posts a mouse-moved event at window coordinates
///   snap <name>      writes <name>-<n>.png for every visible window (main window, popovers, sheets)
///   quit
@MainActor
enum DebugSnapshots {
    static let filtersNotification = Notification.Name("squish.debug.filters")
    static let removeNotification = Notification.Name("squish.debug.remove")
    static let unpricedNotification = Notification.Name("squish.debug.unpriced")
    static let periodNotification = Notification.Name("squish.debug.period")
    static let budgetEditorNotification = Notification.Name("squish.debug.budgetEditor")

    private static var handled = 0
    private static var timer: Timer?

    static func start(_ appState: AppState, worktrees: WorktreeStore, lifecycle: AppLifecycle) {
        guard timer == nil, let dir = ProcessInfo.processInfo.environment["SQUISH_SNAPSHOT_DIR"] else { return }
        let commands = URL(fileURLWithPath: dir).appendingPathComponent("commands")
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                let lines = (try? String(contentsOf: commands, encoding: .utf8))?
                    .split(separator: "\n").map(String.init) ?? []
                while handled < lines.count {
                    run(lines[handled], appState: appState, worktrees: worktrees, lifecycle: lifecycle, dir: dir)
                    handled += 1
                }
            }
        }
    }

    private static func run(
        _ line: String, appState: AppState, worktrees: WorktreeStore, lifecycle: AppLifecycle, dir: String
    ) {
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
        case "unpriced":
            NotificationCenter.default.post(name: unpricedNotification, object: nil)
        case "previewalert":
            appState.previewAlert()
        case "chats":
            appState.debugPreviewLiveChats(argument)
        case "period":
            NotificationCenter.default.post(name: periodNotification, object: argument)
        case "budgeteditor":
            NotificationCenter.default.post(name: budgetEditorNotification, object: nil)
        case "budget":
            let parts = argument.split(separator: " ").map(String.init)
            if parts.count == 2, let amount = Double(parts[0]), let period = CostPeriod(rawValue: parts[1]) {
                appState.budget = SpendBudget(amount: amount, period: period)
            } else {
                appState.budget = nil
            }
        case "quitcommand":
            lifecycle.quitCommand()
        case "open":
            lifecycle.open()
        case "closewindow":
            NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.closable) }?.performClose(nil)
        case "sheet":
            if let window = NSApp.windows.first(where: { $0.attachedSheet != nil }), let sheet = window.attachedSheet {
                let code: NSApplication.ModalResponse = argument == "2" ? .alertSecondButtonReturn : .alertFirstButtonReturn
                window.endSheet(sheet, returnCode: code)
            }
        case "settings":
            // The Settings scene only opens while the app is active, which a terminal launch on
            // a locked screen never is; host the same view in a plain window to check its layout.
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: GeneralSettingsView().environmentObject(lifecycle).environmentObject(appState)
            ))
            window.title = "Settings"
            window.orderFrontRegardless()
        case "front":
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
            let windows = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }.count
            let list = NSApp.windows.map { "[\(type(of: $0)) '\($0.title)' visible=\($0.isVisible)]" }.joined(separator: " ")
            let policy = NSApp.activationPolicy() == .regular ? "regular" : "accessory"
            let line = "\(front) windows=\(windows) active=\(NSApp.isActive) policy=\(policy) \(list)\n"
            let url = URL(fileURLWithPath: dir).appendingPathComponent("front.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        case "scroll":
            let parts = argument.split(separator: " ").compactMap { Int($0) }
            let dy = parts.first ?? -10
            for _ in 0..<(parts.count > 1 ? parts[1] : 1) { post(scrollBy: dy) }
        case "hover":
            let parts = argument.split(separator: " ").compactMap { Double($0) }
            if parts.count == 2 { post(mouseMovedTo: CGPoint(x: parts[0], y: parts[1])) }
        case "snap":
            snap(named: argument, into: dir)
        case "quit":
            NSApp.terminate(nil)
        default:
            break
        }
    }

    private static func post(scrollBy dy: Int) {
        guard let window = NSApp.windows.first(where: \.isVisible),
              let cgEvent = CGEvent(
                  scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                  wheel1: Int32(dy), wheel2: 0, wheel3: 0
              )
        else { return }
        let center = CGPoint(x: window.frame.midX + 200, y: window.frame.midY)
        cgEvent.location = CGPoint(x: center.x, y: NSScreen.screens[0].frame.height - center.y)
        if let event = NSEvent(cgEvent: cgEvent) { window.sendEvent(event) }
    }

    private static func post(mouseMovedTo point: CGPoint) {
        guard let window = NSApp.windows.first(where: \.isVisible) else { return }
        let event = NSEvent.mouseEvent(
            with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        )
        if let event { window.sendEvent(event) }
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
