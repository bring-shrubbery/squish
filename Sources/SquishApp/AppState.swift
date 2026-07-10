import AppKit
import Combine
import Foundation
import SquishCore

enum AppSection: String, CaseIterable, Identifiable {
    case costs
    case compactAlerts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .costs: "Costs"
        case .compactAlerts: "Compact alerts"
        }
    }

    var symbol: String {
        switch self {
        case .costs: "chart.bar.xaxis"
        case .compactAlerts: "rectangle.topthird.inset.filled"
        }
    }
}

struct CompactAlertRecord: Identifiable {
    let id = UUID()
    let sessionID: String
    let title: String
    let date: Date
    let fraction: Double
}

@MainActor
final class AppState: ObservableObject {
    @Published var projectRoot: URL?
    @Published var sessions: [CodingSession] = []
    @Published var selectedSection: AppSection = .costs
    @Published var isScanning = false
    @Published var lastScannedAt: Date?
    @Published var alertsEnabled: Bool {
        didSet { defaults.set(alertsEnabled, forKey: Keys.alertsEnabled) }
    }
    @Published var alertThreshold: Double {
        didSet { defaults.set(alertThreshold, forKey: Keys.alertThreshold) }
    }
    @Published private(set) var recentAlerts: [CompactAlertRecord] = []

    private enum Keys {
        static let bookmark = "selectedProjectBookmark"
        static let pathFallback = "selectedProjectPath"
        static let alertsEnabled = "compactAlertsEnabled"
        static let alertThreshold = "compactAlertThreshold"
    }

    private let defaults: UserDefaults
    private let scanner = SessionScanner()
    private var monitorTask: Task<Void, Never>?
    private var scopedURL: URL?
    private var scopedAccessStarted = false
    private var alertIsArmed: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.alertsEnabled = defaults.object(forKey: Keys.alertsEnabled) as? Bool ?? true
        let storedThreshold = defaults.double(forKey: Keys.alertThreshold)
        self.alertThreshold = storedThreshold > 0 ? storedThreshold : 0.8
        restoreFolder()
    }

    deinit {
        monitorTask?.cancel()
        if scopedAccessStarted { scopedURL?.stopAccessingSecurityScopedResource() }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the folder Squish should monitor"
        panel.message = "Sessions in this folder and its subfolders will be included."
        panel.prompt = "Monitor Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        setProjectRoot(url, persist: true)
    }

    func clearFolder() {
        monitorTask?.cancel()
        monitorTask = nil
        scanner.reset()
        sessions = []
        projectRoot = nil
        defaults.removeObject(forKey: Keys.bookmark)
        defaults.removeObject(forKey: Keys.pathFallback)
        if scopedAccessStarted { scopedURL?.stopAccessingSecurityScopedResource() }
        scopedAccessStarted = false
        scopedURL = nil
    }

    func previewAlert() {
        let session = sessions.max(by: { $0.contextFraction < $1.contextFraction }) ?? CodingSession(
            id: "preview",
            provider: .codex,
            title: "Refactor the authentication flow",
            projectPath: projectRoot?.path ?? "~/Projects/example",
            model: "gpt-5.4",
            usage: TokenUsage(),
            contextTokens: Int(alertThreshold * 353_400),
            contextWindow: 353_400,
            startedAt: Date(),
            updatedAt: Date(),
            logPath: ""
        )
        NotchAlertController.shared.show(session: session, threshold: alertThreshold, isPreview: true)
    }

    private func restoreFolder() {
        if let data = defaults.data(forKey: Keys.bookmark) {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                setProjectRoot(url, persist: stale)
                return
            }
        }

        if let path = defaults.string(forKey: Keys.pathFallback),
           FileManager.default.fileExists(atPath: path) {
            setProjectRoot(URL(fileURLWithPath: path), persist: false)
        }
    }

    private func setProjectRoot(_ url: URL, persist: Bool) {
        monitorTask?.cancel()
        if scopedAccessStarted { scopedURL?.stopAccessingSecurityScopedResource() }

        let normalized = url.standardizedFileURL
        scopedURL = normalized
        scopedAccessStarted = normalized.startAccessingSecurityScopedResource()
        projectRoot = normalized
        sessions = []
        recentAlerts = []
        alertIsArmed = []
        scanner.reset()

        if persist {
            if let bookmark = try? normalized.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                defaults.set(bookmark, forKey: Keys.bookmark)
            }
            defaults.set(normalized.path, forKey: Keys.pathFallback)
        }

        startMonitoring(normalized)
    }

    private func startMonitoring(_ root: URL) {
        monitorTask = Task { [weak self] in
            guard let self else { return }
            var firstScan = true
            while !Task.isCancelled {
                if firstScan { isScanning = true }
                let discovered = await scanner.scan(projectRoot: root)
                guard !Task.isCancelled else { return }
                sessions = discovered
                lastScannedAt = Date()
                isScanning = false
                evaluateCompactAlerts(in: discovered)
                firstScan = false
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func evaluateCompactAlerts(in sessions: [CodingSession]) {
        let sessionIDs = Set(sessions.map(\.id))
        alertIsArmed.formIntersection(sessionIDs)

        for session in sessions {
            let fraction = session.contextFraction
            if fraction < max(0.1, alertThreshold - 0.08) {
                alertIsArmed.insert(session.id)
                continue
            }

            let activeRecently = Date().timeIntervalSince(session.updatedAt) < 120
            if alertsEnabled,
               activeRecently,
               fraction >= alertThreshold,
               alertIsArmed.contains(session.id) || !recentAlerts.contains(where: { $0.sessionID == session.id }) {
                alertIsArmed.remove(session.id)
                let record = CompactAlertRecord(
                    sessionID: session.id,
                    title: session.title,
                    date: Date(),
                    fraction: fraction
                )
                recentAlerts.insert(record, at: 0)
                recentAlerts = Array(recentAlerts.prefix(20))
                NotchAlertController.shared.show(session: session, threshold: alertThreshold)
            }
        }
    }
}
