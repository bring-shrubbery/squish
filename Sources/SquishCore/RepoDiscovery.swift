import Foundation

/// Finds directories that may be git repos (or linked worktrees) under the watched folder.
/// The scanner resolves each candidate to its main repo, so duplicates are harmless.
public enum RepoDiscovery {
    public static let skippedNames: Set<String> = [
        "node_modules", ".build", "DerivedData", "Pods", "vendor", "dist", "build", ".venv", "target",
        // ~/Library and friends: slow to walk and full of privacy-protected folders that prompt.
        "Library"
    ]

    public static func candidates(
        under root: URL,
        maxDepth: Int = 4,
        fileManager: FileManager = .default
    ) -> [String] {
        var found: [String] = []
        var queue: [(url: URL, depth: Int)] = [(root.standardizedFileURL, 0)]
        var head = 0
        while head < queue.count {
            let (directory, depth) = queue[head]
            head += 1
            if fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                found.append(directory.path)
            }
            guard depth < maxDepth,
                  let children = try? fileManager.contentsOfDirectory(
                      at: directory,
                      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
                      options: []
                  ) else { continue }
            for child in children {
                let name = child.lastPathComponent
                if skippedNames.contains(name) { continue }
                if name.hasPrefix("."), name != ".claude" { continue }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
                // Packages (.app, .photoslibrary…) are opaque documents, never repos to scan.
                guard values?.isDirectory == true, values?.isSymbolicLink != true, values?.isPackage != true
                else { continue }
                // contentsOfDirectory resolves symlinks in the parent path (/var -> /private/var);
                // build the child from the parent so every result shares the root's spelling.
                queue.append((directory.appendingPathComponent(name, isDirectory: true), depth + 1))
            }
        }
        return found.sorted()
    }
}
