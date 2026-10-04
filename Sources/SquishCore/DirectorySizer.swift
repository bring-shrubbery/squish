import Foundation

/// Measures how much disk a directory tree takes (allocated bytes, as Finder's "on disk").
/// Results are cached per path until the caller's stamp (the worktree's last activity) changes.
public final class DirectorySizer: @unchecked Sendable {
    private struct Entry {
        let stamp: Date?
        let bytes: Int64
    }

    private var cache: [String: Entry] = [:]
    private let lock = NSLock()

    public init() {}

    public func size(of path: String, stamp: Date?) -> Int64? {
        lock.lock()
        let cached = cache[path]
        lock.unlock()
        if let cached, cached.stamp == stamp { return cached.bytes }
        guard let bytes = Self.measure(URL(fileURLWithPath: path)) else { return nil }
        lock.lock()
        cache[path] = Entry(stamp: stamp, bytes: bytes)
        lock.unlock()
        return bytes
    }

    public static func measure(_ url: URL) -> Int64? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return nil }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
