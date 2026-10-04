import Foundation
import XCTest
@testable import SquishCore

final class DirectorySizerTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("squish-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("nested"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ bytes: Int, to name: String) throws {
        try Data(count: bytes).write(to: dir.appendingPathComponent(name))
    }

    func testCountsAllocatedBytesRecursively() throws {
        try write(100_000, to: "a.bin")
        try write(200_000, to: "nested/b.bin")
        let size = try XCTUnwrap(DirectorySizer.measure(dir))
        XCTAssertGreaterThanOrEqual(size, 300_000)
        XCTAssertLessThan(size, 400_000)
    }

    func testMissingDirectoryIsNil() {
        XCTAssertNil(DirectorySizer.measure(dir.appendingPathComponent("gone")))
        XCTAssertNil(DirectorySizer().size(of: dir.appendingPathComponent("gone").path, stamp: nil))
    }

    func testCachesPerStamp() throws {
        let sizer = DirectorySizer()
        let stamp = Date(timeIntervalSince1970: 1)
        try write(100_000, to: "a.bin")
        let first = try XCTUnwrap(sizer.size(of: dir.path, stamp: stamp))
        try write(500_000, to: "b.bin")
        XCTAssertEqual(sizer.size(of: dir.path, stamp: stamp), first)
        let remeasured = try XCTUnwrap(sizer.size(of: dir.path, stamp: Date(timeIntervalSince1970: 2)))
        XCTAssertGreaterThan(remeasured, first)
    }
}
