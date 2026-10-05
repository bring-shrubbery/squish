import AppKit
import Foundation
import SquishCore

/// Sends a session's compact command to the terminal tab running it, when that tab can be
/// found; otherwise puts the command on the clipboard.
///
/// The session's process is matched by agent, folder and start time, and its tty names the
/// tab. Terminal and iTerm2 expose tabs by tty to AppleScript, so the command goes straight to
/// the right one, which macOS asks the user to allow once per app. Other terminals (and
/// sessions run by a multiplexer with no app above them) get the clipboard, and a paste in
/// the right tab finishes the job.
@MainActor
enum CompactionSender {
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

    static func compact(_ session: CodingSession) -> Delivery {
        let command = Compaction.command(for: session.provider)
        if let process = AgentProcesses.match(for: session, in: AgentProcesses.running()),
           let tty = process.tty {
            for terminal in Terminal.allCases where terminal.isRunning {
                if run(terminal.script(command: command, tty: tty)) {
                    return .sent(app: terminal.name)
                }
            }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        return .copied(command: command)
    }

    private static func run(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("Squish: compact script failed: \(error)")
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
        func script(command: String, tty: String) -> String {
            let quoted = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            switch self {
            case .terminal:
                return """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                do script "\(quoted)" in t
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
                                    tell s to write text "\(quoted)"
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
