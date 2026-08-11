import XCTest

@testable import AgentsAndReposCore

final class PorcelainV2ParserTests: XCTestCase {
    func testFullStatus() {
        let out = """
            # branch.oid 4ae2b3c
            # branch.head main
            # branch.upstream origin/main
            # branch.ab +2 -3
            1 .M N... 100644 100644 100644 aaa bbb file.txt
            1 M. N... 100644 100644 100644 aaa bbb other.txt
            2 R. N... 100644 100644 100644 aaa bbb R100 new.txt\told.txt
            u UU N... 100644 100644 100644 100644 aaa bbb ccc conflicted.txt
            ? untracked.txt
            ? another.txt
            """
        let s = PorcelainV2Parser.parse(out)
        XCTAssertEqual(s.branch, "main")
        XCTAssertFalse(s.detached)
        XCTAssertEqual(s.upstream, "origin/main")
        XCTAssertEqual(s.ahead, 2)
        XCTAssertEqual(s.behind, 3)
        XCTAssertEqual(s.dirty, 4)
        XCTAssertEqual(s.untracked, 2)
        XCTAssertTrue(s.needsAttention)
        // Rename entries keep the new path; tab-separated origPath dropped.
        XCTAssertEqual(
            s.changedPaths,
            ["file.txt", "other.txt", "new.txt", "conflicted.txt", "untracked.txt", "another.txt"])
    }

    func testChangedPathsWithSpacesAndCap() {
        let spacey = "1 .M N... 100644 100644 100644 aaa bbb My File name.txt"
        XCTAssertEqual(
            PorcelainV2Parser.parse(spacey).changedPaths, ["My File name.txt"])

        let many = (0..<30).map { "? file\($0).txt" }.joined(separator: "\n")
        XCTAssertEqual(
            PorcelainV2Parser.parse(many).changedPaths.count,
            PorcelainV2Parser.maxChangedPaths)
    }

    func testCleanNoUpstream() {
        let out = """
            # branch.oid abc
            # branch.head feature/x
            """
        let s = PorcelainV2Parser.parse(out)
        XCTAssertEqual(s.branch, "feature/x")
        XCTAssertNil(s.upstream)
        XCTAssertEqual(s.dirty, 0)
        XCTAssertTrue(s.isClean)
        XCTAssertFalse(s.needsAttention)
    }

    func testDetached() {
        let out = """
            # branch.oid abc
            # branch.head (detached)
            """
        let s = PorcelainV2Parser.parse(out)
        XCTAssertNil(s.branch)
        XCTAssertTrue(s.detached)
    }

    /// Upstream configured but no branch.ab line: git couldn't resolve the
    /// ref, i.e. the remote branch was deleted (typical after a PR merges).
    func testUpstreamGone() {
        let gone = PorcelainV2Parser.parse(
            """
            # branch.oid abc
            # branch.head feature/x
            # branch.upstream origin/feature/x
            """)
        XCTAssertTrue(gone.upstreamGone)

        let tracking = PorcelainV2Parser.parse(
            """
            # branch.oid abc
            # branch.head feature/x
            # branch.upstream origin/feature/x
            # branch.ab +0 -0
            """)
        XCTAssertFalse(tracking.upstreamGone)

        let noUpstream = PorcelainV2Parser.parse(
            """
            # branch.oid abc
            # branch.head feature/x
            """)
        XCTAssertFalse(noUpstream.upstreamGone)
    }
}
