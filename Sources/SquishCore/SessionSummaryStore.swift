import CryptoKit
import Foundation

final class SessionSummaryStore {
    private struct Record: Codable {
        let sourcePath: String
        let fileSize: Int
        let modifiedAt: Date
        let session: CodingSession
    }

    private let directory: URL?
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var memoryCache: [String: Record] = [:]
    private var knownMisses = Set<String>()

    init(directory: URL?, fileManager: FileManager) {
        self.directory = directory
        self.fileManager = fileManager
        if let directory {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            Self.removeSupersededCaches(next: directory, fileManager: fileManager)
        }
    }

    /// Bump the version whenever parsing changes in a way that should re-read unchanged logs.
    static let cacheVersion = 6

    static func defaultDirectory(fileManager: FileManager) -> URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.squish.sessions", isDirectory: true)
            .appendingPathComponent("session-summaries-v\(cacheVersion)", isDirectory: true)
    }

    /// Earlier versions' caches are never read again; drop them so they stop taking space.
    private static func removeSupersededCaches(next directory: URL, fileManager: FileManager) {
        let parent = directory.deletingLastPathComponent()
        guard let siblings = try? fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) else { return }
        for sibling in siblings
        where sibling.lastPathComponent.hasPrefix("session-summaries-v")
            && sibling.lastPathComponent != directory.lastPathComponent {
            try? fileManager.removeItem(at: sibling)
        }
    }

    func session(
        for sourcePath: String,
        fileSize: Int,
        modifiedAt: Date
    ) -> CodingSession? {
        if let record = memoryCache[sourcePath] {
            return matches(record, fileSize: fileSize, modifiedAt: modifiedAt) ? record.session : nil
        }
        guard !knownMisses.contains(sourcePath), let fileURL = fileURL(for: sourcePath) else { return nil }
        guard let data = try? Data(contentsOf: fileURL),
              let record = try? decoder.decode(Record.self, from: data),
              record.sourcePath == sourcePath else {
            knownMisses.insert(sourcePath)
            return nil
        }
        memoryCache[sourcePath] = record
        return matches(record, fileSize: fileSize, modifiedAt: modifiedAt) ? record.session : nil
    }

    func save(
        _ session: CodingSession,
        sourcePath: String,
        fileSize: Int,
        modifiedAt: Date
    ) {
        let record = Record(
            sourcePath: sourcePath,
            fileSize: fileSize,
            modifiedAt: modifiedAt,
            session: session
        )
        memoryCache[sourcePath] = record
        knownMisses.remove(sourcePath)
        guard let fileURL = fileURL(for: sourcePath),
              let data = try? encoder.encode(record) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func remove(sourcePath: String) {
        memoryCache.removeValue(forKey: sourcePath)
        knownMisses.insert(sourcePath)
        if let fileURL = fileURL(for: sourcePath) {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func matches(_ record: Record, fileSize: Int, modifiedAt: Date) -> Bool {
        record.fileSize == fileSize
            && abs(record.modifiedAt.timeIntervalSince(modifiedAt)) < 0.001
    }

    private func fileURL(for sourcePath: String) -> URL? {
        guard let directory else { return nil }
        let digest = SHA256.hash(data: Data(sourcePath.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }
}
