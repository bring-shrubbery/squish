import Foundation
import XCTest
@testable import SquishCore

final class FileSystemEventMonitorTests: XCTestCase {
    func testMonitorReportsChangedFileWithoutPolling() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let receivedEvent = expectation(description: "filesystem event")
        let monitor = FileSystemEventMonitor(paths: [directory], latency: 0.05) { paths in
            if !paths.isEmpty { receivedEvent.fulfill() }
        }

        XCTAssertTrue(monitor.start())
        let file = directory.appendingPathComponent("session.jsonl")
        try "{}\n".write(to: file, atomically: true, encoding: .utf8)
        await fulfillment(of: [receivedEvent], timeout: 5)
        monitor.stop()
    }
}
