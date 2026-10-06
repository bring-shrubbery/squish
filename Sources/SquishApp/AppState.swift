import AppKit
import Combine
import Foundation
import SquishCore

enum AppSection: String, CaseIterable, Identifiable {
    case costs
    case compactAlerts
    case liveChats
    case worktrees

    var id: String { rawValue }

    var title: String {
        switch self {
        case .costs: "Costs"
        case .compactAlerts: "Compact Alerts"
        case .liveChats: "Live Chats"
        case .worktrees: "Worktrees"
        }
    }

    var symbol: String {
        switch self {
        case .costs: "chart.bar"
        case .compactAlerts: "rectangle.topthird.inset.filled"
        case .liveChats: "bubble.left.and.bubble.right"
        case .worktrees: "arrow.triangle.branch"
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
    @Published private(set) var costEntries: [CostLedgerEntry] = [] {
        didSet { updateBudgetStatus() }
    }
    /// Which pricing catalog is in use and when it was last checked.
    @Published private(set) var pricing: PricingUpdater.Status
    @Published var selectedSection: AppSection = .costs
    @Published var isScanning = false
    @Published var alertsEnabled: Bool {
        didSet { defaults.set(alertsEnabled, forKey: Keys.alertsEnabled) }
    }
    @Published var alertThreshold: Double {
        didSet { defaults.set(alertThreshold, forKey: Keys.alertThreshold) }
    }
    @Published private(set) var recentAlerts: [CompactAlertRecord] = []
    /// Sessions waiting for an answer, as the menu bar counts them.
    @Published private(set) var waitingRequestCount = 0
    /// Sessions active in the last minute and a half, waiting ones first, for the menu bar.
    @Published private(set) var liveChats: [LiveChat] = []
    /// What the hooks are waiting on, for the menu bar's Allow and Deny.
    @Published private(set) var pendingRequests: [PendingRequest] = []
    @Published var liveChatsEnabled: Bool {
        didSet {
            defaults.set(liveChatsEnabled, forKey: Keys.liveChatsEnabled)
            applyHookFeatures()
        }
    }
    /// The spending limit for the watched folder, if one is set.
    @Published var budget: SpendBudget? {
        didSet {
            if let budget {
                defaults.set(budget.amount, forKey: Keys.budgetAmount)
                defaults.set(budget.period.rawValue, forKey: Keys.budgetPeriod)
                notifier.requestAuthorization()
            } else {
                defaults.removeObject(forKey: Keys.budgetAmount)
                defaults.removeObject(forKey: Keys.budgetPeriod)
            }
            updateBudgetStatus()
        }
    }
    @Published private(set) var budgetStatus: BudgetStatus?

    let hookInstaller = HookInstaller()
    let notifier = SessionNotifier()
    private let pricingUpdater = PricingUpdater()
    private let controlCenter = AgentControlCenter()
    private let liveChatsNotch = LiveChatsNotchController()
    private var liveActivityTimer: Timer?
    private var liveChatsCancellable: AnyCancellable?

    var liveChatsHookInstalled: Bool { hookInstaller.isInstalled() }
    var activeSessionCount: Int { liveChats.count }
    var liveChatsAccessibilityGranted: Bool { hookInstaller.accessibilityGranted }

    /// What the hooks are installed for right now.
    var hookFeatures: Set<HookInstaller.Feature> {
        var features = Set<HookInstaller.Feature>()
        if liveChatsEnabled { features.insert(.liveChats) }
        if notifier.isEnabled { features.insert(.notifications) }
        return features
    }

    private enum Keys {
        static let bookmark = "selectedProjectBookmark"
        static let pathFallback = "selectedProjectPath"
        static let alertsEnabled = "compactAlertsEnabled"
        static let alertThreshold = "compactAlertThreshold"
        static let liveChatsEnabled = "liveChatsEnabled"
        static let budgetAmount = "budgetAmount"
        static let budgetPeriod = "budgetPeriod"
        static let budgetAlertLevel = "budgetAlertLevel"
        static let budgetAlertPeriodStart = "budgetAlertPeriodStart"
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
        self.liveChatsEnabled = defaults.object(forKey: Keys.liveChatsEnabled) as? Bool ?? false
        self.pricing = pricingUpdater.status
        if let period = defaults.string(forKey: Keys.budgetPeriod).flatMap(CostPeriod.init(rawValue:)) {
            self.budget = SpendBudget(amount: defaults.double(forKey: Keys.budgetAmount), period: period)
        }

        liveChatsNotch.configure(
            onResolve: { [weak self] request, decision in
                self?.resolve(request, with: decision)
            },
            onOpenTerminal: { chat in
                TerminalBridge.reveal(chat.session)
            }
        )
        controlCenter.onEvent = { [weak self] event in self?.handle(event) }
        notifier.onOpen = { [weak self] sessionId in self?.openSession(id: sessionId) }
        notifier.onSettingsChange = { [weak self] in self?.applyHookFeatures() }

        NotchAlertController.shared.onCompact = { TerminalBridge.compact($0) }

        pricingUpdater.onCatalogChange = { [weak self] in self?.pricingCatalogDidChange() }
        pricingUpdater.start()
        pricing = pricingUpdater.status
        restoreFolder()
        applyHookFeatures()
        startLiveActivityTimer()
    }

    /// A newer catalog is in use: re-price the ledger (every stored session, not only the
    /// live ones) and re-parse nothing, since usage is unchanged.
    private func pricingCatalogDidChange() {
        pricing = pricingUpdater.status
        guard let root = projectRoot else { return }
        costLedgerTask?.cancel()
        costLedgerTask = Task { [weak self] in
            guard let self else { return }
            let entries = await costLedger.reprice(projectRoot: root)
            guard !Task.isCancelled, isCurrentProject(root) else { return }
            if entries != costEntries { costEntries = entries }
        }
    }

    deinit {
        monitorTask?.cancel()
        eventRefreshTask?.cancel()
        costLedgerTask?.cancel()
        fileSystemMonitor?.stop()
        liveActivityTimer?.invalidate()
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
        stopControlCenter()
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

    func previewLiveChat() {
        guard let root = projectRoot else { return }
        let request = PendingRequest(
            id: "preview-\(UUID().uuidString)",
            sessionId: sessions.first?.id ?? "claude:preview",
            cwd: root.path,
            kind: .permission,
            toolName: "Bash",
            inputSummary: "rm -rf build/",
            options: nil,
            tty: nil,
            pid: nil,
            ppid: nil,
            createdAt: Date()
        )
        controlCenter.injectPreview(request)
        refreshLiveActivity()
    }

    // MARK: - Live chats and notifications

    /// Answers a request from the notch or the menu bar; a request that can only be shown
    /// (Gemini CLI) is dismissed instead.
    func resolve(_ request: PendingRequest, with decision: AgentDecision) {
        if request.isDecidable {
            controlCenter.resolve(request, with: decision)
        } else {
            controlCenter.dismiss(request)
        }
        notifier.clearWaiting(sessionId: request.sessionId)
        refreshLiveActivity()
    }

    /// Brings the session's terminal forward.
    @discardableResult
    func reveal(_ session: CodingSession) -> TerminalBridge.Reveal {
        TerminalBridge.reveal(session)
    }

    @discardableResult
    func compact(_ session: CodingSession) -> TerminalBridge.Delivery {
        TerminalBridge.compact(session)
    }

    /// A clicked notification: the session's terminal, or its folder when the session is gone.
    private func openSession(id: String) {
        if let session = sessions.first(where: { $0.id == id }) {
            TerminalBridge.reveal(session)
        } else if let root = projectRoot {
            NSWorkspace.shared.activateFileViewerSelecting([root])
        }
    }

    /// The hooks follow the features that need them; the control center runs for any of them,
    /// since its heartbeat is what lets the hook speak to Squish at all.
    private func applyHookFeatures() {
        let features = hookFeatures
        try? hookInstaller.sync(features: features)
        guard !features.isEmpty, let root = projectRoot else {
            stopControlCenter()
            return
        }
        controlCenter.start(monitoredRoot: root)
        liveChatsCancellable = controlCenter.$pendingRequests
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshLiveActivity() }
            }
        refreshLiveActivity()
    }

    private func startLiveActivityTimer() {
        liveActivityTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLiveActivity() }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveActivityTimer = timer
        refreshLiveActivity()
    }

    private func stopControlCenter() {
        liveChatsCancellable = nil
        controlCenter.stop()
        refreshLiveActivity()
    }

    /// Recomputes who is working, idle and waiting: on every scan, every two seconds (status
    /// is a matter of time passing), and whenever the hooks write something.
    private func refreshLiveActivity() {
        // A "waiting" notice from Gemini CLI has no answer channel; once the session's log
        // moves on, the user answered in the terminal, so the notice goes away by itself.
        for request in controlCenter.pendingRequests where !request.isDecidable {
            if let session = sessions.first(where: { $0.id == request.sessionId }),
               session.updatedAt > request.createdAt.addingTimeInterval(2) {
                controlCenter.dismiss(request)
            }
        }
        let pending = controlCenter.pendingRequests
        let chats = LiveActivity.chats(sessions: sessions, pending: pending, now: Date())
        if debugNotchIsHeld {
            // A harness preview owns the island; the real activity leaves it alone.
        } else if liveChatsEnabled {
            liveChatsNotch.update(chats: chats, pending: pending)
        } else {
            liveChatsNotch.update(chats: [], pending: [])
        }
        if pending != pendingRequests {
            notifyNewRequests(pending)
            pendingRequests = pending
        }
        if chats != liveChats { liveChats = chats }
        let waiting = Set(pending.map(\.sessionId)).count
        if waiting != waitingRequestCount { waitingRequestCount = waiting }
    }

    /// New requests get a waiting notification; sessions with no request left get theirs
    /// taken back.
    private func notifyNewRequests(_ pending: [PendingRequest]) {
        let known = Set(pendingRequests.map(\.id))
        for request in pending where !known.contains(request.id) && !request.id.hasPrefix("preview-") {
            let summary = request.kind == .question ? request.inputSummary : "\(request.toolName): \(request.inputSummary)"
            notifier.sessionWaiting(
                sessionId: request.sessionId,
                provider: request.provider,
                session: sessions.first { $0.id == request.sessionId },
                folder: request.cwd,
                summary: summary
            )
        }
        let stillWaiting = Set(pending.map(\.sessionId))
        for sessionId in Set(pendingRequests.map(\.sessionId)) where !stillWaiting.contains(sessionId) {
            notifier.clearWaiting(sessionId: sessionId)
        }
    }

    /// Finished and waiting events from the hooks. A waiting event for a session whose
    /// request is already pending says nothing new.
    private func handle(_ event: AgentEvent) {
        let session = sessions.first { $0.id == event.sessionId }
        switch event.kind {
        case .finished:
            notifier.sessionFinished(event, session: session)
        case .waiting:
            guard !controlCenter.pendingRequests.contains(where: { $0.sessionId == event.sessionId }) else { return }
            notifier.sessionWaiting(
                sessionId: event.sessionId,
                provider: event.provider,
                session: session,
                folder: event.cwd,
                summary: event.message ?? "Waiting for your input."
            )
        }
    }

    // MARK: - Budget

    /// Recomputed whenever the ledger or the budget changes; says so, once per period, when
    /// the spend first nears and first passes the limit.
    private func updateBudgetStatus() {
        guard let budget, let status = BudgetStatus(budget: budget, entries: costEntries) else {
            budgetStatus = nil
            return
        }
        if status != budgetStatus { budgetStatus = status }

        let periodStart = status.interval.start.timeIntervalSince1970
        let samePeriod = defaults.double(forKey: Keys.budgetAlertPeriodStart) == periodStart
        let previous = samePeriod ? BudgetStatus.Level(rawValue: defaults.integer(forKey: Keys.budgetAlertLevel)) : nil
        guard let crossed = status.crossedLevel(since: previous) else {
            if !samePeriod {
                defaults.set(periodStart, forKey: Keys.budgetAlertPeriodStart)
                defaults.set(BudgetStatus.Level.ok.rawValue, forKey: Keys.budgetAlertLevel)
            }
            return
        }
        defaults.set(periodStart, forKey: Keys.budgetAlertPeriodStart)
        defaults.set(crossed.rawValue, forKey: Keys.budgetAlertLevel)
        notifier.budgetCrossed(status, level: crossed, folder: projectRoot?.lastPathComponent ?? "Squish")
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

    #if DEBUG
    /// For `DebugSnapshots`: watch a folder without saving the choice.
    func debugSetProjectRoot(_ url: URL) { setProjectRoot(url, persist: false) }

    private var debugNotchIsHeld = false

    /// For `DebugSnapshots`: puts made-up live chats in the island without hooks or the
    /// control center. "off" hands the island back to the real activity.
    func debugPreviewLiveChats(_ mode: String) {
        guard mode != "off" else {
            debugNotchIsHeld = false
            refreshLiveActivity()
            return
        }
        debugNotchIsHeld = true
        let now = Date()
        let real = sessions.filter { !$0.isSubagent }.prefix(3)
        let chats = real.enumerated().map { index, session in
            LiveChat(session: session, status: index == 0 ? .working : .idle)
        }
        guard let first = chats.first else { return }
        let request = PendingRequest(
            id: "preview-\(UUID().uuidString)", sessionId: first.session.id, cwd: first.session.projectPath,
            kind: .permission, toolName: "Bash", inputSummary: "rm -rf build/", options: nil,
            tty: nil, pid: nil, ppid: nil, createdAt: now
        )
        switch mode {
        case "prompt":
            liveChatsNotch.update(chats: chats, pending: [request])
        case "expanded":
            liveChatsNotch.update(chats: chats, pending: [])
            liveChatsNotch.debugExpand()
        default:
            liveChatsNotch.update(chats: chats, pending: [])
        }
    }
    #else
    private let debugNotchIsHeld = false
    #endif

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
        applyHookFeatures()
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
        refreshLiveActivity()
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
