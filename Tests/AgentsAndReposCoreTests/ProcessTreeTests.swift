import XCTest

@testable import AgentsAndReposCore

final class ProcessTreeTests: XCTestCase {
    func testParentOfSelfExists() {
        let ppid = ProcessTree.parent(of: getpid())
        XCTAssertNotNil(ppid)
        XCTAssertGreaterThan(ppid ?? 0, 0)
    }

    func testAncestorsTerminateAndStartWithParent() {
        let ancestors = ProcessTree.ancestors(of: getpid())
        XCTAssertFalse(ancestors.isEmpty)
        XCTAssertEqual(ancestors.first, ProcessTree.parent(of: getpid()))
        // No duplicates (cycle guard) and launchd never included.
        XCTAssertEqual(Set(ancestors).count, ancestors.count)
        XCTAssertFalse(ancestors.contains(1))
    }

    func testInvalidPidsReturnNil() {
        XCTAssertNil(ProcessTree.parent(of: 0))
        XCTAssertNil(ProcessTree.parent(of: -5))
        XCTAssertNil(ProcessTree.ttyName(of: 0))
        XCTAssertNil(ProcessTree.ttyName(of: -5))
        // A pid that can't exist (pid_max on macOS is 99999).
        XCTAssertNil(ProcessTree.parent(of: 999_999))
        XCTAssertNil(ProcessTree.ttyName(of: 999_999))
    }

    func testLaunchdHasNoTTY() {
        XCTAssertNil(ProcessTree.ttyName(of: 1))
    }
}
