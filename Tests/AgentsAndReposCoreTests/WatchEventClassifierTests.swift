import XCTest

@testable import AgentsAndReposCore

final class WatchEventClassifierTests: XCTestCase {
    let roots = ["/Users/x/Projects"]
    let known = [
        "/Users/x/Projects/app",
        "/Users/x/Projects/tool",
        "/Users/x/.claude/worktrees/fix-123",
    ]

    private func classify(_ paths: [String], maxDepth: Int = 3) -> WatchClassification {
        WatchEventClassifier.classify(
            eventPaths: paths, knownPaths: known, roots: roots, maxDepth: maxDepth)
    }

    func testWorkingTreeChangeStatusesOwningRepo() {
        let c = classify(["/Users/x/Projects/app/Sources/Foo.swift"])
        XCTAssertEqual(c.statusPaths, ["/Users/x/Projects/app"])
        XCTAssertFalse(c.rediscover)
        XCTAssertTrue(c.prRepoPaths.isEmpty)
    }

    func testWorktreeOutsideRootsIsOwnedByWorktreePath() {
        let c = classify(["/Users/x/.claude/worktrees/fix-123/main.swift"])
        XCTAssertEqual(c.statusPaths, ["/Users/x/.claude/worktrees/fix-123"])
    }

    func testBuildArtifactsAndDSStoreIgnored() {
        let c = classify([
            "/Users/x/Projects/app/node_modules/lodash/index.js",
            "/Users/x/Projects/app/.build/debug/foo.o",
            "/Users/x/Projects/app/.DS_Store",
        ])
        XCTAssertTrue(c.isEmpty)
    }

    func testGitIndexStatusesButLockAndObjectsIgnored() {
        XCTAssertEqual(
            classify(["/Users/x/Projects/app/.git/index"]).statusPaths,
            ["/Users/x/Projects/app"])
        XCTAssertTrue(classify(["/Users/x/Projects/app/.git/index.lock"]).isEmpty)
        XCTAssertTrue(classify(["/Users/x/Projects/app/.git/objects/ab/cdef"]).isEmpty)
        XCTAssertTrue(classify(["/Users/x/Projects/app/.git/logs/HEAD"]).isEmpty)
    }

    func testRemoteRefChangeTriggersPRNudge() {
        let c = classify(["/Users/x/Projects/app/.git/refs/remotes/origin/main"])
        XCTAssertEqual(c.prRepoPaths, ["/Users/x/Projects/app"])
        XCTAssertEqual(c.statusPaths, ["/Users/x/Projects/app"])
    }

    func testLocalRefChangeNoNudge() {
        let c = classify(["/Users/x/Projects/app/.git/refs/heads/main"])
        XCTAssertTrue(c.prRepoPaths.isEmpty)
        XCTAssertEqual(c.statusPaths, ["/Users/x/Projects/app"])
    }

    func testWorktreeMetadataChangeRediscovers() {
        let c = classify(["/Users/x/Projects/app/.git/worktrees/feature/HEAD"])
        XCTAssertTrue(c.rediscover)
        XCTAssertEqual(c.statusPaths, ["/Users/x/Projects/app"])
    }

    func testNewRepoUnderRootRediscovers() {
        let c = classify(["/Users/x/Projects/newrepo/.git/HEAD"])
        XCTAssertTrue(c.rediscover)
        XCTAssertTrue(c.statusPaths.isEmpty)
    }

    func testDirectoryMovedIntoRootRediscovers() {
        // A wholesale move fires one rename event for the dir itself.
        XCTAssertTrue(classify(["/Users/x/Projects/moved-repo"]).rediscover)
    }

    func testDeepPathWithoutGitBeyondDepthIgnored() {
        let c = classify(["/Users/x/Projects/a/b/c/d/e/file.txt"], maxDepth: 3)
        XCTAssertTrue(c.isEmpty)
    }

    func testHiddenAndSkipDirsUnderRootIgnored() {
        XCTAssertTrue(classify(["/Users/x/Projects/.Trash/old/file"]).isEmpty)
        XCTAssertTrue(classify(["/Users/x/Projects/node_modules/x/y"]).isEmpty)
    }

    func testPathOutsideRootsAndReposIgnored() {
        XCTAssertTrue(classify(["/Users/x/Downloads/foo.zip"]).isEmpty)
    }

    func testEventOnRepoRootItselfStatuses() {
        XCTAssertEqual(
            classify(["/Users/x/Projects/app"]).statusPaths, ["/Users/x/Projects/app"])
    }

    func testTrailingSlashNormalized() {
        XCTAssertEqual(
            classify(["/Users/x/Projects/app/Sources/"]).statusPaths,
            ["/Users/x/Projects/app"])
    }

    func testTildeRootExpansion() {
        let home = NSHomeDirectory()
        let c = WatchEventClassifier.classify(
            eventPaths: ["\(home)/Projects/fresh/.git"],
            knownPaths: [], roots: ["~/Projects"], maxDepth: 3)
        XCTAssertTrue(c.rediscover)
    }
}
