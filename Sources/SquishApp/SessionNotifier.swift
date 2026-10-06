import AppKit
import Foundation
import SquishCore
import UserNotifications

/// Posts macOS notifications about sessions: a turn finished, an agent is waiting, a
/// budget line crossed. Clicking one brings the session's terminal forward.
///
/// Notifications need an app bundle; under `swift run` there is none and the center is
/// never touched. Permission is asked for the first time a kind of notification is turned
/// on, never at launch.
@MainActor
final class SessionNotifier: NSObject, ObservableObject {
    enum Authorization: Equatable {
        case notDetermined
        case authorized
        /// Turned off in System Settings; Squish cannot ask again.
        case denied
        /// Not running from an app bundle.
        case unavailable
    }

    /// A turn finished.
    @Published var notifiesFinished: Bool {
        didSet {
            defaults.set(notifiesFinished, forKey: Keys.finished)
            if notifiesFinished { requestAuthorization() }
            onSettingsChange?()
        }
    }
    /// An agent is waiting for a permission, an answer or the next prompt.
    @Published var notifiesWaiting: Bool {
        didSet {
            defaults.set(notifiesWaiting, forKey: Keys.waiting)
            if notifiesWaiting { requestAuthorization() }
            onSettingsChange?()
        }
    }
    @Published private(set) var authorization: Authorization

    /// The session a clicked notification was about.
    var onOpen: ((String) -> Void)?
    /// Either toggle changed, so the hooks behind them follow.
    var onSettingsChange: (() -> Void)?

    var isEnabled: Bool { notifiesFinished || notifiesWaiting }

    private enum Keys {
        static let finished = "notifyWhenSessionFinishes"
        static let waiting = "notifyWhenSessionWaits"
    }

    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter?
    /// When each session was last told to be waiting, so the two hooks that can both report
    /// one prompt (PermissionRequest and Notification) produce one notification.
    private var lastWaiting: [String: Date] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notifiesFinished = defaults.object(forKey: Keys.finished) as? Bool ?? false
        notifiesWaiting = defaults.object(forKey: Keys.waiting) as? Bool ?? false
        let bundled = Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
        center = bundled ? UNUserNotificationCenter.current() : nil
        authorization = bundled ? .notDetermined : .unavailable
        super.init()
        center?.delegate = self
        refreshAuthorization()
    }

    // MARK: - Permission

    func refreshAuthorization() {
        guard let center else { return }
        center.getNotificationSettings { [weak self] settings in
            let status: Authorization
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: status = .authorized
            case .denied: status = .denied
            case .notDetermined: status = .notDetermined
            @unknown default: status = .notDetermined
            }
            Task { @MainActor [weak self] in self?.authorization = status }
        }
    }

    func requestAuthorization() {
        guard let center, authorization == .notDetermined else { return }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshAuthorization() }
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Sessions

    func sessionFinished(_ event: AgentEvent, session: CodingSession?) {
        clearWaiting(sessionId: event.sessionId)
        guard notifiesFinished else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(event.provider.displayName) finished"
        content.subtitle = session?.title ?? URL(fileURLWithPath: event.cwd).lastPathComponent
        content.body = event.message ?? "Waiting for your next prompt in \(URL(fileURLWithPath: event.cwd).lastPathComponent)."
        post(content, identifier: "finished:\(event.sessionId):\(event.id)", sessionId: event.sessionId, sound: nil)
    }

    /// A permission prompt, a question or an idle agent. `summary` is what it is waiting for.
    func sessionWaiting(sessionId: String, provider: AgentProvider, session: CodingSession?, folder: String, summary: String) {
        guard notifiesWaiting else { return }
        let now = Date()
        if let last = lastWaiting[sessionId], now.timeIntervalSince(last) < 15 { return }
        lastWaiting[sessionId] = now
        let content = UNMutableNotificationContent()
        content.title = "\(provider.displayName) is waiting"
        content.subtitle = session?.title ?? URL(fileURLWithPath: folder).lastPathComponent
        content.body = summary
        post(content, identifier: "waiting:\(sessionId)", sessionId: sessionId, sound: .default)
    }

    /// The session got its answer or moved on: take the waiting notice back.
    func clearWaiting(sessionId: String) {
        lastWaiting.removeValue(forKey: sessionId)
        center?.removeDeliveredNotifications(withIdentifiers: ["waiting:\(sessionId)"])
        center?.removePendingNotificationRequests(withIdentifiers: ["waiting:\(sessionId)"])
    }

    // MARK: - Budget

    func budgetCrossed(_ status: BudgetStatus, level: BudgetStatus.Level, folder: String) {
        let content = UNMutableNotificationContent()
        switch level {
        case .over: content.title = "Over budget"
        case .near: content.title = "Nearly at budget"
        case .ok: return
        }
        content.subtitle = folder
        content.body = "\(status.summary), \(Int((status.fraction * 100).rounded()))% of the limit."
        post(content, identifier: "budget:\(level.rawValue):\(Int(status.interval.start.timeIntervalSince1970))", sessionId: nil, sound: .default)
    }

    // MARK: - Posting

    private func post(_ content: UNMutableNotificationContent, identifier: String, sessionId: String?, sound: UNNotificationSound?) {
        guard let center, authorization == .authorized else { return }
        content.sound = sound
        if let sessionId {
            content.userInfo = ["sessionId": sessionId]
            content.threadIdentifier = sessionId
        }
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error { NSLog("Squish: notification failed: \(error)") }
        }
    }
}

extension SessionNotifier: UNUserNotificationCenterDelegate {
    /// Show banners even while Squish is the active app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionId = response.notification.request.content.userInfo["sessionId"] as? String
        Task { @MainActor [weak self] in
            if let sessionId { self?.onOpen?(sessionId) }
            completionHandler()
        }
    }
}
