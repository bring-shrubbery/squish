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
    @Published private(set) var costEntries: [CostLedgerEntry] = []
    @Published var selectedSection: AppSection = .costs
    @Published var isScanning = false
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
    private let costLedger = CostLedgerStore()
    private var monitorTask: Task<Void, Never>?
    private var eventRefreshTask: Task<Void, Never>?
    private var costLedgerTask: Task<Void, Never>?
    private var fileSystemMonitor: FileSystemEventMonitor?
    private var monitoredRootPaths = Set<String>()
    private var fileEventsAreActive = false
    private var pendingChangedPaths = Set<URL>()
    private var scopedURL: URL?
    private var scopedAccessStarted = false
    private var alertIsArmed: Set<String> = []
    private var alertBaselineIsEstablished = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.alertsEnabled = defaults.object(forKey: Keys.alertsEnabled) as? Bool ?? true
        let storedThreshold = defaults.double(forKey: Keys.alertThreshold)
        self.alertThreshold = storedThreshold > 0 ? storedThreshold : 0.8
        restoreFolder()
    }

    deinit {
        monitorTask?.cancel()
        eventRefreshTask?.cancel()
        costLedgerTask?.cancel()
        fileSystemMonitor?.stop()
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
        stopMonitoring()
        let scanner = scanner
        Task.detached(priority: .background) { scanner.reset() }
        sessions = []
        costEntries = []
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
        stopMonitoring()
        if scopedAccessStarted { scopedURL?.stopAccessingSecurityScopedResource() }

        let normalized = url.standardizedFileURL
        scopedURL = normalized
        scopedAccessStarted = normalized.startAccessingSecurityScopedResource()
        projectRoot = normalized
        sessions = []
        costEntries = []
        recentAlerts = []
        alertIsArmed = []
        alertBaselineIsEstablished = false

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
        installFileSystemMonitor(for: root)
        loadCostLedger(for: root)

        monitorTask = Task { [weak self] in
            guard let self else { return }
            isScanning = true
            var batch = await scanner.scanInitialBatch(
                projectRoot: root,
                maxFullParses: 2,
                maxCandidates: 300
            )
            guard !Task.isCancelled, isCurrentProject(root) else { return }
            apply(batch.sessions, alertsMayFire: false)
            alertBaselineIsEstablished = true
            isScanning = false

            var lastHistoryPublish = Date()
            while batch.hasMoreHistory, !Task.isCancelled {
                batch = await scanner.loadNextHistoryBatch(
                    projectRoot: root,
                    maxFullParses: 4,
                    maxCandidates: 300
                )
                guard !Task.isCancelled, isCurrentProject(root) else { return }
                if !batch.hasMoreHistory || Date().timeIntervalSince(lastHistoryPublish) >= 0.5 {
                    apply(batch.sessions, alertsMayFire: false)
                    lastHistoryPublish = Date()
                }
                do {
                    try await Task.sleep(nanoseconds: 10_000_000)
                } catch {
                    return
                }
            }

            var fallbackTicks = 0
            while !Task.isCancelled {
                let interval = fileEventsAreActive ? 30_000_000_000 : 1_000_000_000
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval))
                } catch {
                    return
                }

                fallbackTicks += 1
                let shouldDiscover = fileEventsAreActive || fallbackTicks >= 30
                let discovered: [CodingSession]
                if shouldDiscover {
                    discovered = await scanner.discoverNewSessions(projectRoot: root)
                } else {
                    discovered = await scanner.refreshKnownSessions(projectRoot: root)
                }
                guard !Task.isCancelled, isCurrentProject(root) else { return }
                apply(discovered)
                if shouldDiscover {
                    fallbackTicks = 0
                    installFileSystemMonitor(for: root)
                }
            }
        }
    }

    private func installFileSystemMonitor(for root: URL) {
        let monitoringRoots = SessionScanner.monitoringRoots(projectRoot: root)
        let paths = Set(monitoringRoots.map { $0.path })
        guard paths != monitoredRootPaths || fileSystemMonitor == nil || !fileEventsAreActive else { return }

        fileSystemMonitor?.stop()
        let monitor = FileSystemEventMonitor(paths: monitoringRoots) { [weak self] paths in
            Task { @MainActor [weak self] in
                self?.enqueueFileChanges(paths, projectRoot: root)
            }
        }
        fileEventsAreActive = monitor.start()
        fileSystemMonitor = monitor
        monitoredRootPaths = paths
    }

    private func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        eventRefreshTask?.cancel()
        eventRefreshTask = nil
        costLedgerTask?.cancel()
        costLedgerTask = nil
        pendingChangedPaths.removeAll()
        fileSystemMonitor?.stop()
        fileSystemMonitor = nil
        monitoredRootPaths.removeAll()
        fileEventsAreActive = false
        isScanning = false
        alertBaselineIsEstablished = false
    }

    private func enqueueFileChanges(_ paths: [URL], projectRoot: URL) {
        guard isCurrentProject(projectRoot) else { return }
        pendingChangedPaths.formUnion(paths)
        guard eventRefreshTask == nil else { return }

        eventRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !pendingChangedPaths.isEmpty {
                let paths = Array(pendingChangedPaths)
                pendingChangedPaths.removeAll(keepingCapacity: true)
                let discovered = await scanner.refresh(projectRoot: projectRoot, changedPaths: paths)
                guard !Task.isCancelled, isCurrentProject(projectRoot) else { return }
                apply(discovered)
            }
            eventRefreshTask = nil
        }
    }

    private func apply(_ discovered: [CodingSession], alertsMayFire: Bool = true) {
        guard discovered != sessions else { return }
        var previousByID: [String: CodingSession] = [:]
        for session in sessions {
            if previousByID[session.id]?.updatedAt ?? .distantPast < session.updatedAt {
                previousByID[session.id] = session
            }
        }
        sessions = discovered
        evaluateCompactAlerts(
            in: discovered,
            previousByID: previousByID,
            alertsMayFire: alertsMayFire
        )
        guard let root = projectRoot else { return }
        mergeCostLedger(sessions: discovered, projectRoot: root)
    }

    private func loadCostLedger(for root: URL) {
        costLedgerTask?.cancel()
        costLedgerTask = Task { [weak self] in
            guard let self else { return }
            let entries = await costLedger.entries(projectRoot: root)
            guard !Task.isCancelled, isCurrentProject(root) else { return }
            if entries != costEntries { costEntries = entries }
        }
    }

    private func mergeCostLedger(sessions: [CodingSession], projectRoot: URL) {
        costLedgerTask?.cancel()
        costLedgerTask = Task { [weak self] in
            guard let self else { return }
            let entries = await costLedger.merge(
                sessions: sessions,
                projectRoot: projectRoot
            )
            guard !Task.isCancelled, isCurrentProject(projectRoot) else { return }
            if entries != costEntries { costEntries = entries }
        }
    }

    private func isCurrentProject(_ root: URL) -> Bool {
        projectRoot?.standardizedFileURL.resolvingSymlinksInPath().path
            == root.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func evaluateCompactAlerts(
        in sessions: [CodingSession],
        previousByID: [String: CodingSession],
        alertsMayFire: Bool
    ) {
        let alertableSessions = sessions.filter { !$0.isSubagent }
        let sessionIDs = Set(alertableSessions.map(\.id))
        alertIsArmed.formIntersection(sessionIDs)

        for session in alertableSessions {
            let fraction = session.contextFraction
            if fraction < max(0.1, alertThreshold - 0.08) {
                alertIsArmed.insert(session.id)
                continue
            }

            let hasAlerted = recentAlerts.contains { $0.sessionID == session.id }
            if alertsEnabled,
               CompactAlertPolicy.shouldNotify(
                    previous: previousByID[session.id],
                    current: session,
                    threshold: alertThreshold,
                    isArmed: alertIsArmed.contains(session.id),
                    hasAlerted: hasAlerted,
                    monitoringIsEstablished: alertBaselineIsEstablished && alertsMayFire
               ) {
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
