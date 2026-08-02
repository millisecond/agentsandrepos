import XCTest

@testable import AgentsAndReposCore

final class FSEventsWatcherTests: XCTestCase {
    func testDeliversEventsForFileCreation() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fseventstest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let exp = expectation(description: "fs event delivered")
        exp.assertForOverFulfill = false
        let watcher = FSEventsWatcher(paths: [dir.path], latency: 0.05) { paths in
            if paths.contains(where: { $0.contains("fseventstest-") }) { exp.fulfill() }
        }
        XCTAssertNotNil(watcher)

        try Data("hello".utf8).write(to: dir.appendingPathComponent("file.txt"))
        wait(for: [exp], timeout: 5.0)
        _ = watcher  // keep alive until events arrive
    }

    func testNilWhenNoPathsExist() {
        XCTAssertNil(FSEventsWatcher(paths: ["/nonexistent-\(UUID().uuidString)"]) { _ in })
    }
}
