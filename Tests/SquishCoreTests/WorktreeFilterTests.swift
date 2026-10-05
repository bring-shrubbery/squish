import Foundation
import XCTest
@testable import SquishCore

final class WorktreeFilterTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400

    private func make(
        path: String = "/repo/.claude/worktrees/feature",
        branch: String? = "feature",
        lastActivity: Date? = nil,
        size: Int64? = nil,
        uncommitted: Int = 0,
        unpushed: Int = 0,
        locked: Bool = false,
        prunable: Bool = false
    ) -> Worktree {
        Worktree(
            path: path, repoPath: "/repo", branch: branch, head: "0123456789abcdef",
            isLocked: locked, isPrunable: prunable, lastActivity: lastActivity,
            uncommittedCount: uncommitted, unpushedCount: unpushed, sizeBytes: size
        )
    }

    private func matches(
        _ filter: WorktreeFilter, _ worktree: Worktree, flagged: Bool = false, inUse: Bool = false
    ) -> Bool {
        filter.matches(worktree, flagged: flagged, inUse: inUse, now: now)
    }

    func testDefaultFilterShowsEverything() {
        let filter = WorktreeFilter()
        XCTAssertTrue(filter.isDefault)
        XCTAssertTrue(matches(filter, make()))
        XCTAssertTrue(matches(filter, make(prunable: true), flagged: true, inUse: true))
        XCTAssertTrue(matches(filter, make(branch: nil, uncommitted: 3, locked: true)))
    }

    func testChoiceOnlyAndHide() {
        var filter = WorktreeFilter()
        filter.inUse = .only
        XCTAssertTrue(matches(filter, make(), inUse: true))
        XCTAssertFalse(matches(filter, make(), inUse: false))
        filter.inUse = .exclude
        XCTAssertFalse(matches(filter, make(), inUse: true))
        XCTAssertTrue(matches(filter, make(), inUse: false))
        XCTAssertFalse(filter.isDefault)
    }

    func testFlaggedWorkAgentLockedAndMissing() {
        var filter = WorktreeFilter()
        filter.flagged = .only
        XCTAssertTrue(matches(filter, make(), flagged: true))
        XCTAssertFalse(matches(filter, make(), flagged: false))

        filter = WorktreeFilter()
        filter.withWork = .exclude
        XCTAssertTrue(matches(filter, make()))
        XCTAssertFalse(matches(filter, make(uncommitted: 1)))
        XCTAssertFalse(matches(filter, make(unpushed: 1)))

        filter = WorktreeFilter()
        filter.agentMade = .only
        XCTAssertTrue(matches(filter, make()))
        XCTAssertFalse(matches(filter, make(path: "/repo-feature")))

        filter = WorktreeFilter()
        filter.locked = .exclude
        XCTAssertFalse(matches(filter, make(locked: true)))
        filter.missing = .only
        XCTAssertFalse(matches(filter, make()))
        XCTAssertTrue(matches(filter, make(prunable: true)))
    }

    func testMinimumSizeNeedsAMeasuredWorktree() {
        var filter = WorktreeFilter()
        filter.minSizeBytes = 1_000_000_000
        XCTAssertTrue(matches(filter, make(size: 1_000_000_000)))
        XCTAssertFalse(matches(filter, make(size: 999_999_999)))
        XCTAssertFalse(matches(filter, make(size: nil)))
        filter.minSizeBytes = 0
        XCTAssertTrue(matches(filter, make(size: nil)))
    }

    func testMinimumIdleDaysNeedsKnownActivity() {
        var filter = WorktreeFilter()
        filter.minIdleDays = 7
        XCTAssertTrue(matches(filter, make(lastActivity: now.addingTimeInterval(-7 * day))))
        XCTAssertFalse(matches(filter, make(lastActivity: now.addingTimeInterval(-6 * day))))
        XCTAssertFalse(matches(filter, make(lastActivity: nil)))
    }

    func testQueryMatchesBranchOrPathIgnoringCase() {
        var filter = WorktreeFilter()
        filter.query = "FEAT"
        XCTAssertTrue(matches(filter, make()))
        filter.query = "worktrees/"
        XCTAssertTrue(matches(filter, make()))
        filter.query = "detached 012"
        XCTAssertTrue(matches(filter, make(path: "/x", branch: nil)))
        filter.query = "nope"
        XCTAssertFalse(matches(filter, make()))
        filter.query = "   "
        XCTAssertTrue(matches(filter, make()))
    }

    func testFiltersCombine() {
        var filter = WorktreeFilter()
        filter.inUse = .exclude
        filter.minSizeBytes = 100
        filter.withWork = .exclude
        let candidate = make(size: 200)
        XCTAssertTrue(matches(filter, candidate))
        XCTAssertFalse(matches(filter, candidate, inUse: true))
        XCTAssertFalse(matches(filter, make(size: 50)))
        XCTAssertFalse(matches(filter, make(size: 200, unpushed: 1)))
    }

    func testSortOrders() {
        let big = make(path: "/big", branch: "b", lastActivity: now.addingTimeInterval(-1 * day), size: 300)
        let small = make(path: "/small", branch: "a", lastActivity: now.addingTimeInterval(-10 * day), size: 10)
        let unknown = make(path: "/unknown", branch: "c", lastActivity: nil, size: nil)
        let all = [small, unknown, big]
        XCTAssertEqual(WorktreeFilter.sorted(all, by: .largest).map(\.path), ["/big", "/small", "/unknown"])
        XCTAssertEqual(WorktreeFilter.sorted(all, by: .oldest).map(\.path), ["/small", "/big", "/unknown"])
        XCTAssertEqual(WorktreeFilter.sorted(all, by: .newest).map(\.path), ["/big", "/small", "/unknown"])
        XCTAssertEqual(WorktreeFilter.sorted(all, by: .name).map(\.path), ["/small", "/big", "/unknown"])
        // Unknown values stay last when the direction flips.
        XCTAssertEqual(
            WorktreeFilter.sorted(all, by: WorktreeSort(key: .size, ascending: true)).map(\.path),
            ["/small", "/big", "/unknown"]
        )
        XCTAssertEqual(
            WorktreeFilter.sorted(all, by: WorktreeSort(key: .name, ascending: false)).map(\.path),
            ["/unknown", "/big", "/small"]
        )
    }

    func testIsNarrowedIgnoresSearchAndSort() {
        var filter = WorktreeFilter()
        filter.query = "x"
        filter.sort = .name
        XCTAssertFalse(filter.isNarrowed)
        filter.locked = .exclude
        XCTAssertTrue(filter.isNarrowed)
    }
}
