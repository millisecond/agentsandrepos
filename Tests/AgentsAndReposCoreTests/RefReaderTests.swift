import XCTest

@testable import AgentsAndReposCore

/// RefReader must agree with git about where main is, using only file reads —
/// it feeds the merge-state cache key, so a wrong oid means stale badges and
/// a missed one means a `merge-base` spawn per status tick.
final class RefReaderTests: XCTestCase {
    private var tmp: String = ""

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "refreader-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tmp)
    }

    private func write(_ relPath: String, _ contents: String) throws {
        let path = tmp + "/" + relPath
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testLooseMainRef() throws {
        try write("repo/.git/refs/heads/main", "aaa111\n")
        var r = RefReader()
        let refs = r.mainRefs(repoPath: tmp + "/repo")
        XCTAssertEqual(refs.branchName, "main")
        XCTAssertEqual(refs.localOid, "aaa111")
        XCTAssertNil(refs.remoteOid)
    }

    func testPackedRefsAndMasterFallback() throws {
        try write("repo/.git/HEAD", "ref: refs/heads/master\n")
        try write(
            "repo/.git/packed-refs",
            """
            # pack-refs with: peeled fully-peeled sorted
            bbb222 refs/heads/master
            ccc333 refs/remotes/origin/master
            ddd444 refs/tags/v1.0
            ^eee555
            """)
        var r = RefReader()
        let refs = r.mainRefs(repoPath: tmp + "/repo")
        XCTAssertEqual(refs.branchName, "master")
        XCTAssertEqual(refs.localOid, "bbb222")
        XCTAssertEqual(refs.remoteOid, "ccc333")
    }

    func testOriginHEADSymrefPicksMainName() throws {
        // origin/HEAD says the default branch is "trunk" — neither main nor master.
        try write("repo/.git/refs/remotes/origin/HEAD", "ref: refs/remotes/origin/trunk\n")
        try write("repo/.git/refs/remotes/origin/trunk", "fff666\n")
        try write("repo/.git/refs/heads/trunk", "aaa111\n")
        var r = RefReader()
        let refs = r.mainRefs(repoPath: tmp + "/repo")
        XCTAssertEqual(refs.branchName, "trunk")
        XCTAssertEqual(refs.localOid, "aaa111")
        XCTAssertEqual(refs.remoteOid, "fff666")
    }

    func testLooseShadowsPacked() throws {
        try write("repo/.git/packed-refs", "old000 refs/heads/main\n")
        try write("repo/.git/refs/heads/main", "new999\n")
        var r = RefReader()
        XCTAssertEqual(r.mainRefs(repoPath: tmp + "/repo").localOid, "new999")
    }

    func testWorktreeResolvesThroughCommondir() throws {
        try write("repo/.git/refs/heads/main", "aaa111\n")
        try write("repo/.git/worktrees/feat/commondir", "../..\n")
        try write("wt/.git", "gitdir: \(tmp)/repo/.git/worktrees/feat\n")
        var r = RefReader()
        let refs = r.mainRefs(repoPath: tmp + "/wt")
        XCTAssertEqual(refs.branchName, "main")
        XCTAssertEqual(refs.localOid, "aaa111")
    }

    func testNoMainAnywhere() throws {
        try write("repo/.git/refs/heads/feature", "aaa111\n")
        var r = RefReader()
        XCTAssertNil(r.mainRefs(repoPath: tmp + "/repo").branchName)
    }

    func testMissingRepo() {
        var r = RefReader()
        XCTAssertNil(r.mainRefs(repoPath: tmp + "/nope").branchName)
    }
}
