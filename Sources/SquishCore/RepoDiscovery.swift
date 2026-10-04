import Foundation

/// Finds directories that may be git repos (or linked worktrees) under the watched folder.
/// The scanner resolves each candidate to its main repo, so duplicates are harmless.
public enum RepoDiscovery {
    public static let skippedNames: Set<String> = [
        "node_modules", ".build", "DerivedData", "Pods", "vendor", "dist", "build", ".venv", "target"
    ]

    public static func candidates(
        under root: URL,
        maxDepth: Int = 4,
        fileManager: FileManager = .default
    ) -> [String] {
        var found: [String] = []
        var queue: [(url: URL, depth: Int)] = [(root.standardizedFileURL, 0)]
        while !queue.isEmpty {
            let (directory, depth) = queue.removeFirst()
            if fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                found.append(directory.path)
            }
            guard depth < maxDepth,
                  let children = try? fileManager.contentsOfDirectory(
                      at: directory,
                      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                      options: []
                  ) else { continue }
            for child in children {
                let name = child.lastPathComponent
                if skippedNames.contains(name) { continue }
                if name.hasPrefix("."), name != ".claude" { continue }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                // contentsOfDirectory resolves symlinks in the parent path (/var -> /private/var);
                // build the child from the parent so every result shares the root's spelling.
                queue.append((directory.appendingPathComponent(name, isDirectory: true), depth + 1))
            }
        }
        return found.sorted()
    }
}
