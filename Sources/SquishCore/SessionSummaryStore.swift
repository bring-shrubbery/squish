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
        }
    }

    static func defaultDirectory(fileManager: FileManager) -> URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.squish.sessions", isDirectory: true)
            .appendingPathComponent("session-summaries-v5", isDirectory: true)
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
