import AppKit
import ApplicationServices
import Foundation
import UserNotifications

/// Delivers a free-text answer into the terminal running an agent session.
///
/// The write-path is intentionally best-effort and defensive: it never throws.
/// When Accessibility is granted and the owning process resolves to a running
/// app, it activates that app, puts the answer on the pasteboard, and synthesizes
/// Cmd-V + Return. Otherwise it falls back to copying the answer and notifying the
/// user so nothing is silently lost.
@MainActor
enum TerminalResponder {
    static func deliver(answer: String, toPid pid: Int?) {
        setClipboard(answer)

        guard AXIsProcessTrusted(),
              let pid,
              let app = NSRunningApplication(processIdentifier: pid_t(pid)) ?? terminalAppOwning(pid: pid) else {
            notifyFallback(answer: answer)
            return
        }

        app.activate()
        // Give the app a beat to come forward before we paste.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            sendPasteAndReturn()
        }
    }

    // MARK: - Clipboard

    private static func setClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Keystrokes

    private static func sendPasteAndReturn() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09       // 'v'
        let returnKey: CGKeyCode = 0x24  // Return

        // Cmd-V
        if let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
           let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) {
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }

        // Return, shortly after the paste registers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let down = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
               let up = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false) {
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        }
    }

    /// Walks up from the agent process to the terminal app hosting it.
    private static func terminalAppOwning(pid: Int) -> NSRunningApplication? {
        // The agent's direct app rarely equals the terminal; match by frontmost
        // terminal-like app as a pragmatic fallback.
        let terminalBundleIDs: Set<String> = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "dev.warp.Warp-Stable",
            "net.kovidgoyal.kitty",
            "com.github.wez.wezterm",
            "io.alacritty",
            "co.zeit.hyper"
        ]
        return NSWorkspace.shared.runningApplications.first {
            guard let id = $0.bundleIdentifier else { return false }
            return terminalBundleIDs.contains(id) && $0.isActive
        }
    }

    // MARK: - Fallback

    private static func notifyFallback(answer: String) {
        let content = UNMutableNotificationContent()
        content.title = "Squish — answer copied"
        content.body = "Paste it into your terminal: \(answer.prefix(80))"
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
