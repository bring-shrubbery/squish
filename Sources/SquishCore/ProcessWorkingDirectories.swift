import Darwin
import Foundation

/// The working directories of running processes, so a worktree a shell, editor or agent
/// (wherever it keeps its worktrees) is working in is never flagged or removed.
public enum ProcessWorkingDirectories {
    /// Normalized cwd paths of every process the user can inspect, Squish itself excluded.
    /// Processes that cannot be read (other users', exited meanwhile) are skipped.
    /// - Parameter excludingChildrenOf: also skip direct children of this pid (Squish passes its
    ///   own pid so the git commands it runs inside worktrees do not count as activity).
    public static func current(excludingChildrenOf parent: pid_t? = nil) -> [String] {
        let ownPid = getpid()
        var paths = Set<String>()
        for pid in allPids() where pid > 0 && pid != ownPid {
            if let parent, parentPid(of: pid) == parent { continue }
            if let cwd = workingDirectory(of: pid) {
                paths.insert(WorktreePolicy.normalized(cwd))
            }
        }
        return paths.sorted()
    }

    private static func allPids() -> [pid_t] {
        // A call with no buffer returns the current process count; leave headroom for growth.
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 256)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled)))
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { buffer -> String in
            let bytes = buffer.bindMemory(to: UInt8.self)
            let length = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: UnsafeBufferPointer(rebasing: bytes[..<length]), as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    private static func parentPid(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
