import AppKit
import Foundation
import SquishCore

/// Gets the user to the terminal running a session, and sends a session's compact command
/// to it.
///
/// The session's process is matched by agent, folder and start time, and its tty names the
/// tab. Terminal and iTerm2 expose tabs by tty to AppleScript, so a tab can be selected or
/// typed into directly, which macOS asks the user to allow once per app. Other terminals
/// are found by walking up from the agent process to the app around it (Ghostty, Warp, an
/// editor's terminal) and brought to the front; a session run under a multiplexer with no
/// app above it falls back to whichever terminal app is running. Typing only ever goes
/// through Terminal and iTerm2; elsewhere the command goes to the clipboard to paste.
@MainActor
enum TerminalBridge {
    /// What happened to a command sent for a session.
    enum Delivery: Equatable {
        /// Typed into the tab of this app ("Terminal", "iTerm2").
        case sent(app: String)
        /// On the clipboard, ready to paste.
        case copied(command: String)

        var label: String {
            switch self {
            case let .sent(app): "Sent to \(app)"
            case .copied: "Copied"
            }
        }
    }

    /// What was brought forward for a session.
    enum Reveal: Equatable {
        /// The session's own tab, in Terminal or iTerm2.
        case tab(app: String)
        /// The app hosting the session, or failing that a terminal app, without the tab.
        case app(name: String)
        /// Nothing to bring forward; the session's folder was shown in Finder instead.
        case folder

        var label: String {
            switch self {
            case let .tab(app): "Opened in \(app)"
            case let .app(name): "Opened \(name)"
            case .folder: "Shown in Finder"
            }
        }
    }

    /// Where a session lives: its process and tty when they can be found, and its folder.
    struct Location {
        var pid: pid_t?
        var tty: String?
        var folder: String

        init(session: CodingSession) {
            let process = AgentProcesses.match(for: session, in: AgentProcesses.running())
            pid = process?.pid
            tty = process?.tty
            folder = session.projectPath
        }

        /// From a hook's request or event: the hook's parent chain leads to the agent and
        /// its terminal, and the hook already recorded the tty.
        init(pid: Int?, tty: String?, folder: String) {
            self.pid = pid.map { pid_t($0) }
            self.tty = tty
            self.folder = folder
        }
    }

    // MARK: - Compact

    static func compact(_ session: CodingSession) -> Delivery {
        let command = Compaction.command(for: session.provider)
        if let tty = Location(session: session).tty {
            for terminal in Terminal.allCases where terminal.isRunning {
                if run(terminal.sendScript(command: command, tty: tty)) {
                    return .sent(app: terminal.name)
                }
            }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        return .copied(command: command)
    }

    // MARK: - Reveal

    @discardableResult
    static func reveal(_ session: CodingSession) -> Reveal {
        reveal(Location(session: session))
    }

    @discardableResult
    static func reveal(_ location: Location) -> Reveal {
        if let tty = location.tty {
            for terminal in Terminal.allCases where terminal.isRunning {
                if run(terminal.selectScript(tty: tty)) {
                    return .tab(app: terminal.name)
                }
            }
        }
        if let pid = location.pid, let app = hostingApp(of: pid) ?? anyTerminalApp() {
            app.activate()
            return .app(name: app.localizedName ?? "the terminal")
        }
        if let app = anyTerminalApp() {
            app.activate()
            return .app(name: app.localizedName ?? "the terminal")
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: location.folder)])
        return .folder
    }

    /// The first ancestor of the process that is an app with a bundle: the terminal or
    /// editor whose window holds the session. Nil under a daemon multiplexer.
    private static func hostingApp(of pid: pid_t) -> NSRunningApplication? {
        for ancestor in ProcessTree.ancestors(of: pid) {
            if let app = NSRunningApplication(processIdentifier: ancestor),
               app.bundleIdentifier != nil, app.activationPolicy != .prohibited {
                return app
            }
        }
        return nil
    }

    /// A running terminal app, the frontmost one first, for sessions whose process leads
    /// to no app.
    private static func anyTerminalApp() -> NSRunningApplication? {
        let candidates = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return terminalBundleIDs.contains(id)
        }
        return candidates.first(where: \.isActive) ?? candidates.first
    }

    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "org.alacritty",
        "io.alacritty",
        "co.zeit.hyper",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.microsoft.VSCode"
    ]

    // MARK: - AppleScript

    private static func run(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("Squish: terminal script failed: \(error)")
            return false
        }
        return result.stringValue == "sent"
    }

    private enum Terminal: CaseIterable {
        case terminal
        case iTerm

        var name: String {
            switch self {
            case .terminal: "Terminal"
            case .iTerm: "iTerm2"
            }
        }

        var bundleID: String {
            switch self {
            case .terminal: "com.apple.Terminal"
            case .iTerm: "com.googlecode.iterm2"
            }
        }

        var isRunning: Bool {
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }

        /// Finds the tab by tty, types the command, brings the tab forward; "sent" or "none".
        func sendScript(command: String, tty: String) -> String {
            let quoted = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            switch self {
            case .terminal: return script(tty: tty, action: "do script \"\(quoted)\" in t")
            case .iTerm: return script(tty: tty, action: "tell s to write text \"\(quoted)\"")
            }
        }

        /// Finds the tab by tty and brings it forward; "sent" or "none".
        func selectScript(tty: String) -> String {
            script(tty: tty, action: "")
        }

        private func script(tty: String, action: String) -> String {
            switch self {
            case .terminal:
                return """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                \(action)
                                set selected tab of w to t
                                set index of w to 1
                                activate
                                return "sent"
                            end if
                        end repeat
                    end repeat
                end tell
                return "none"
                """
            case .iTerm:
                return """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then
                                    \(action)
                                    tell t to select
                                    tell w to select
                                    activate
                                    return "sent"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                return "none"
                """
            }
        }
    }
}
