import AppKit
import Combine
import ServiceManagement

/// Keeps Squish alive after ⌘Q so the notch keeps watching, and owns what that needs: the
/// menu bar item, the one-time explanation, and the login item.
///
/// Only the app menu's Quit item is replaced. Every other way of quitting (the menu bar
/// item, the Dock, logging out, a Sparkle update) terminates the app as usual.
@MainActor
final class AppLifecycle: ObservableObject {
    static let mainWindowID = "main"

    /// With this on, ⌘Q closes the window and leaves Squish in the menu bar.
    @Published var keepsRunning: Bool {
        didSet { defaults.set(keepsRunning, forKey: Keys.keepsRunning) }
    }
    @Published private(set) var loginItem: LoginItemState

    enum LoginItemState: Equatable {
        case on
        case off
        /// Registered, but macOS waits for the user to allow it in System Settings.
        case needsApproval
        /// Not a bundled app (`swift run`), so there is nothing to register.
        case unavailable
    }

    private enum Keys {
        static let keepsRunning = "keepRunningInMenuBar"
        static let didExplain = "didExplainBackgroundQuit"
    }

    /// Recreates the main window through the scene; set by the menu bar label, which is the
    /// one view that stays alive while the window is closed.
    var openMainWindow: (() -> Void)?

    private let defaults: UserDefaults
    private var previousApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var isExplaining = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keepsRunning = defaults.object(forKey: Keys.keepsRunning) as? Bool ?? true
        loginItem = Self.currentLoginItemState()

        // Remember where the user came from, so ⌘Q can hand the screen back.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else { return }
            MainActor.assumeIsolated { self?.previousApp = app }
        }
    }

    // MARK: - Quitting

    /// The app menu's Quit Squish (⌘Q).
    func quitCommand() {
        guard keepsRunning else {
            quit()
            return
        }
        guard !isExplaining else { return }
        if !defaults.bool(forKey: Keys.didExplain), let window = mainWindows.first {
            explain(on: window)
        } else {
            retire()
        }
    }

    /// Quits for real: the menu bar item's Quit Squish and the explanation's second button.
    func quit() {
        NSApp.terminate(nil)
    }

    /// Closes the windows and brings back the app the user was in before.
    func retire() {
        for window in mainWindows {
            window.close()
        }
        guard let previousApp, !previousApp.isTerminated else { return }
        if !previousApp.activate(from: .current, options: []) {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate()
        }
    }

    /// The menu bar item's Open Squish: brings the window back, recreating it when ⌘Q
    /// closed it.
    func open() {
        if mainWindows.isEmpty {
            openMainWindow?()
        }
        NSApp.activate()
        mainWindows.first?.makeKeyAndOrderFront(nil)
    }

    /// The document-style windows: not the notch panels, not popovers or sheets.
    private var mainWindows: [NSWindow] {
        NSApp.windows.filter { window in
            window.isVisible && !(window is NSPanel) && window.styleMask.contains(.titled)
                && window.styleMask.contains(.closable)
        }
    }

    private func explain(on window: NSWindow) {
        isExplaining = true
        let alert = NSAlert()
        alert.messageText = "Squish keeps running in the menu bar"
        alert.informativeText = "The window closes, but Squish keeps watching your sessions, so compact "
            + "alerts and live chats still work. To quit, choose Quit Squish from the menu bar icon. "
            + "You can change this in Settings."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Quit Squish")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.isExplaining = false
                self.defaults.set(true, forKey: Keys.didExplain)
                if response == .alertSecondButtonReturn {
                    self.quit()
                } else {
                    self.retire()
                }
            }
        }
    }

    // MARK: - Login item

    func setOpensAtLogin(_ on: Bool) {
        guard loginItem != .unavailable else { return }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Squish: login item change failed: \(error)")
        }
        loginItem = Self.currentLoginItemState()
    }

    /// Re-reads the status, for when the user comes back from System Settings.
    func refreshLoginItem() {
        loginItem = Self.currentLoginItemState()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func currentLoginItemState() -> LoginItemState {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .off
        @unknown default: return .off
        }
    }
}
