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
            let calculatedCost = session.cost(using: catalog)
            let shouldRefresh = existing?.session != session
                || (existing?.cost == nil && calculatedCost != nil)
            guard shouldRefresh else { continue }

            let dailyCosts = updatedDailyCosts(
                existing: existing,
                session: session,
                calculatedCost: calculatedCost
            )
            let entry = CostLedgerEntry(
                session: session,
                cost: calculatedCost,
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
                if let existing = entriesByID[entry.id], existing.recordedAt > entry.recordedAt { return }
                entriesByID[entry.id] = entry
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
