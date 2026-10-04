import Foundation
import XCTest
@testable import SquishCore

final class ProcessWorkingDirectoriesTests: XCTestCase {
    func testIncludesAChildProcessWorkingDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squish-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        child.currentDirectoryURL = dir
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }
        XCTAssertTrue(ProcessWorkingDirectories.current().contains(WorktreePolicy.normalized(dir.path)))
    }

    func testCanExcludeChildrenOfAProcess() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squish-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        child.currentDirectoryURL = dir
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }
        let paths = ProcessWorkingDirectories.current(excludingChildrenOf: getpid())
        XCTAssertFalse(paths.contains(WorktreePolicy.normalized(dir.path)))
    }
}
