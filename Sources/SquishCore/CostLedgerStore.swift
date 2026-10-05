import CryptoKit
import Foundation

public struct DailyCostBucket: Identifiable, Codable, Equatable, Sendable {
    public let day: Date
    public let cost: CostBreakdown

    public var id: Date { day }

    public init(day: Date, cost: CostBreakdown) {
        self.day = day
        self.cost = cost
    }
}

public struct CostLedgerEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let session: CodingSession
    public let cost: CostBreakdown?
    public let dailyCosts: [DailyCostBucket]
    public let pricingEffectiveDate: Date
    public let recordedAt: Date

    public init(
        session: CodingSession,
        cost: CostBreakdown?,
        dailyCosts: [DailyCostBucket]? = nil,
        pricingEffectiveDate: Date,
        recordedAt: Date = Date()
    ) {
        self.id = session.id
        self.session = session
        self.cost = cost
        self.dailyCosts = dailyCosts ?? cost.map {
            [DailyCostBucket(day: Calendar.current.startOfDay(for: session.updatedAt), cost: $0)]
        } ?? []
        self.pricingEffectiveDate = pricingEffectiveDate
        self.recordedAt = recordedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case session
        case cost
        case dailyCosts
        case pricingEffectiveDate
        case recordedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSession = try container.decode(CodingSession.self, forKey: .session)
        let decodedCost = try container.decodeIfPresent(CostBreakdown.self, forKey: .cost)
        let decodedDailyCosts = try container.decodeIfPresent(
            [DailyCostBucket].self,
            forKey: .dailyCosts
        )

        session = decodedSession
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? decodedSession.id
        cost = decodedCost
        pricingEffectiveDate = try container.decode(Date.self, forKey: .pricingEffectiveDate)
        recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        if let decodedDailyCosts {
            dailyCosts = decodedDailyCosts
        } else if let decodedCost {
            dailyCosts = [
                DailyCostBucket(
                    day: Calendar.current.startOfDay(for: decodedSession.updatedAt),
                    cost: decodedCost
                )
            ]
        } else {
            dailyCosts = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(session, forKey: .session)
        try container.encodeIfPresent(cost, forKey: .cost)
        try container.encode(dailyCosts, forKey: .dailyCosts)
        try container.encode(pricingEffectiveDate, forKey: .pricingEffectiveDate)
        try container.encode(recordedAt, forKey: .recordedAt)
    }
}

public actor CostLedgerStore {
    private let directory: URL?
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var entriesByID: [String: CostLedgerEntry] = [:]
    private var hasLoaded = false

    public init() {
        let fileManager = FileManager.default
        self.fileManager = fileManager
        self.directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Squish", isDirectory: true)
            .appendingPathComponent("cost-ledger-v1", isDirectory: true)
    }

    public init(directory: URL?, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public func entries(projectRoot: URL) -> [CostLedgerEntry] {
        loadIfNeeded()
        return filteredEntries(projectRoot: projectRoot)
    }

    public func merge(
        sessions: [CodingSession],
        projectRoot: URL,
        catalog: PricingCatalog = .current
    ) -> [CostLedgerEntry] {
        loadIfNeeded()

        for session in sessions {
            let existing = entriesByID[session.id]
            let matchingExisting = existing.flatMap {
                $0.session.isSubagent == session.isSubagent ? $0 : nil
            }
            let calculatedCost = session.cost(using: catalog)
            // A newer catalog re-prices the whole session, downward too: the stored cost came
            // from rates that have since been corrected.
            let repriced = existing.map { $0.pricingEffectiveDate < catalog.effectiveDate } ?? false
            let shouldRefresh = existing?.session != session
                || (existing?.cost == nil && calculatedCost != nil)
                || (repriced && calculatedCost != nil)
            guard shouldRefresh else { continue }

            let recordedCost: CostBreakdown?
            let dailyCosts: [DailyCostBucket]
            if repriced, let calculatedCost {
                recordedCost = calculatedCost.nonnegative
                dailyCosts = rescaledDailyCosts(
                    existing: matchingExisting,
                    session: session,
                    cost: calculatedCost.nonnegative
                )
            } else {
                recordedCost = monotonicCost(
                    existing: matchingExisting?.cost,
                    calculated: calculatedCost
                )
                dailyCosts = updatedDailyCosts(
                    existing: matchingExisting,
                    session: session,
                    calculatedCost: recordedCost
                )
            }
            let entry = CostLedgerEntry(
                session: session,
                cost: recordedCost,
                dailyCosts: dailyCosts,
                pricingEffectiveDate: catalog.effectiveDate
            )
            entriesByID[entry.id] = entry
            persist(entry)
        }

        return filteredEntries(projectRoot: projectRoot)
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let directory else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files where file.pathExtension == "json" {
            autoreleasepool {
                guard let data = try? Data(contentsOf: file),
                      let entry = try? decoder.decode(CostLedgerEntry.self, from: data) else { return }
                let normalized = normalized(entry)
                if let existing = entriesByID[normalized.id], existing.recordedAt > normalized.recordedAt { return }
                entriesByID[normalized.id] = normalized
                if normalized != entry { persist(normalized) }
            }
        }
    }

    private func filteredEntries(projectRoot: URL) -> [CostLedgerEntry] {
        entriesByID.values
            .filter { path($0.session.projectPath, isInside: projectRoot.path) }
            .sorted {
                if $0.session.updatedAt == $1.session.updatedAt { return $0.id < $1.id }
                return $0.session.updatedAt > $1.session.updatedAt
            }
    }

    private func updatedDailyCosts(
        existing: CostLedgerEntry?,
        session: CodingSession,
        calculatedCost: CostBreakdown?
    ) -> [DailyCostBucket] {
        guard let calculatedCost else { return existing?.dailyCosts ?? [] }
        guard let existing, let previousCost = existing.cost else {
            return [
                DailyCostBucket(
                    day: Calendar.current.startOfDay(for: session.updatedAt),
                    cost: calculatedCost
                )
            ]
        }

        let delta = calculatedCost - previousCost
        guard delta != .zero else { return existing.dailyCosts }
        let day = Calendar.current.startOfDay(for: session.updatedAt)
        var buckets = existing.dailyCosts
        if let index = buckets.firstIndex(where: { Calendar.current.isDate($0.day, inSameDayAs: day) }) {
            buckets[index] = DailyCostBucket(day: day, cost: buckets[index].cost + delta)
        } else {
            buckets.append(DailyCostBucket(day: day, cost: delta))
        }
        return buckets.sorted { $0.day < $1.day }
    }

    /// The existing daily buckets scaled, component by component, to a re-priced total, so the
    /// spend stays on the days it happened. A component that was zero before lands on the
    /// last day.
    private func rescaledDailyCosts(
        existing: CostLedgerEntry?,
        session: CodingSession,
        cost: CostBreakdown
    ) -> [DailyCostBucket] {
        guard let existing, let previous = existing.cost, !existing.dailyCosts.isEmpty else {
            return [DailyCostBucket(day: Calendar.current.startOfDay(for: session.updatedAt), cost: cost)]
        }
        func scaled(_ value: Double, from old: Double, to new: Double) -> Double {
            old > 0 ? value * new / old : 0
        }
        var buckets = existing.dailyCosts.map { bucket in
            DailyCostBucket(
                day: bucket.day,
                cost: CostBreakdown(
                    input: scaled(bucket.cost.input, from: previous.input, to: cost.input),
                    cacheRead: scaled(bucket.cost.cacheRead, from: previous.cacheRead, to: cost.cacheRead),
                    cacheWrite: scaled(bucket.cost.cacheWrite, from: previous.cacheWrite, to: cost.cacheWrite),
                    output: scaled(bucket.cost.output, from: previous.output, to: cost.output)
                )
            )
        }
        let remainder = (cost - buckets.reduce(.zero) { $0 + $1.cost }).nonnegative
        if remainder != .zero, let last = buckets.indices.last {
            buckets[last] = DailyCostBucket(day: buckets[last].day, cost: buckets[last].cost + remainder)
        }
        return buckets
    }

    private func monotonicCost(
        existing: CostBreakdown?,
        calculated: CostBreakdown?
    ) -> CostBreakdown? {
        guard let calculated else { return existing }
        guard let existing else { return calculated.nonnegative }
        return existing.componentwiseMaximum(with: calculated)
    }

    private func normalized(_ entry: CostLedgerEntry) -> CostLedgerEntry {
        let session = normalizedContextWindow(for: entry.session)
        guard let cost = entry.cost else {
            guard session != entry.session else { return entry }
            return CostLedgerEntry(
                session: session,
                cost: nil,
                dailyCosts: entry.dailyCosts,
                pricingEffectiveDate: entry.pricingEffectiveDate,
                recordedAt: entry.recordedAt
            )
        }

        let normalizedCost = cost.nonnegative
        let bucketTotal = entry.dailyCosts.reduce(.zero) { $0 + $1.cost }
        let hasInvalidBucket = entry.dailyCosts.contains { !$0.cost.isFinite || $0.cost.hasNegativeComponent }
        let totalsDiffer = !bucketTotal.isApproximatelyEqual(to: normalizedCost)
        let needsCostRepair = hasInvalidBucket || totalsDiffer || cost != normalizedCost
        guard needsCostRepair || session != entry.session else { return entry }

        let dailyCosts = needsCostRepair
            ? [
                DailyCostBucket(
                    day: Calendar.current.startOfDay(for: session.updatedAt),
                    cost: normalizedCost
                )
            ]
            : entry.dailyCosts

        return CostLedgerEntry(
            session: session,
            cost: normalizedCost,
            dailyCosts: dailyCosts,
            pricingEffectiveDate: entry.pricingEffectiveDate,
            recordedAt: entry.recordedAt
        )
    }

    private func normalizedContextWindow(for session: CodingSession) -> CodingSession {
        guard session.provider == .claude else { return session }
        let contextWindow = PricingCatalog.current.contextWindow(
            for: session.model,
            provider: session.provider,
            observedTokens: session.contextTokens
        )
        guard contextWindow != session.contextWindow else { return session }

        return CodingSession(
            id: session.id,
            provider: session.provider,
            title: session.title,
            projectPath: session.projectPath,
            model: session.model,
            usage: session.usage,
            contextTokens: session.contextTokens,
            contextWindow: contextWindow,
            startedAt: session.startedAt,
            updatedAt: session.updatedAt,
            logPath: session.logPath,
            lastUserMessageAt: session.lastUserMessageAt,
            isSubagent: session.isSubagent
        )
    }

    private func persist(_ entry: CostLedgerEntry) {
        guard let directory else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(entry) else { return }
        try? data.write(to: fileURL(for: entry.id, in: directory), options: .atomic)
    }

    private func fileURL(for id: String, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(id.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    private func path(_ candidate: String, isInside root: String) -> Bool {
        let candidate = URL(fileURLWithPath: candidate).standardizedFileURL.resolvingSymlinksInPath().path
        let root = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        return candidate == root || candidate.hasPrefix(root + "/")
    }
}

private extension CostBreakdown {
    var hasNegativeComponent: Bool {
        input < 0 || cacheRead < 0 || cacheWrite < 0 || output < 0
    }

    var isFinite: Bool {
        input.isFinite && cacheRead.isFinite && cacheWrite.isFinite && output.isFinite
    }

    var nonnegative: CostBreakdown {
        CostBreakdown(
            input: max(0, input),
            cacheRead: max(0, cacheRead),
            cacheWrite: max(0, cacheWrite),
            output: max(0, output)
        )
    }

    func componentwiseMaximum(with other: CostBreakdown) -> CostBreakdown {
        CostBreakdown(
            input: max(input, other.input),
            cacheRead: max(cacheRead, other.cacheRead),
            cacheWrite: max(cacheWrite, other.cacheWrite),
            output: max(output, other.output)
        )
    }

    func isApproximatelyEqual(to other: CostBreakdown) -> Bool {
        abs(input - other.input) < 0.000_000_1
            && abs(cacheRead - other.cacheRead) < 0.000_000_1
            && abs(cacheWrite - other.cacheWrite) < 0.000_000_1
            && abs(output - other.output) < 0.000_000_1
    }
}
