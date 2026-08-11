import XCTest

@testable import AgentsAndReposCore

final class WorktreeListParserTests: XCTestCase {
    func testParseSkipsMainAndFindsLinked() {
        let out = """
            worktree /Users/x/Projects/app
            HEAD aaaa
            branch refs/heads/main

            worktree /Users/x/Projects/app-wt/feature
            HEAD bbbb
            branch refs/heads/feature/thing

            worktree /Users/x/.claude/worktrees/fix-123
            HEAD cccc
            detached
            """
        let wts = WorktreeListParser.parse(out, mainPath: "/Users/x/Projects/app")
        XCTAssertEqual(wts.count, 2)
        XCTAssertEqual(wts[0].branch, "feature/thing")
        XCTAssertFalse(wts[0].detached)
        XCTAssertTrue(wts[1].detached)
        XCTAssertNil(wts[1].branch)
        XCTAssertTrue(wts[1].isClaudeManaged)
    }

    /// Invoked from a linked worktree, git still lists the main repo first;
    /// the main repo must not come back as a "linked worktree" of the checkout.
    func testParseFromLinkedWorktreeExcludesMainRepo() {
        let out = """
            worktree /Users/x/Projects/app
            HEAD aaaa
            branch refs/heads/main

            worktree /Users/x/Projects/app-demo
            HEAD aaaa
            branch refs/heads/demo
            """
        let wts = WorktreeListParser.parse(out, mainPath: "/Users/x/Projects/app-demo")
        XCTAssertTrue(wts.isEmpty)
    }

    /// `locked`/`prunable` appear bare or with a reason; either form sets the
    /// flag, and flags don't leak into the next entry.
    func testLockedAndPrunableFlags() {
        let out = """
            worktree /Users/x/Projects/app
            HEAD aaaa
            branch refs/heads/main

            worktree /Users/x/Projects/app-wt/pinned
            HEAD bbbb
            branch refs/heads/pinned
            locked keep for the demo machine

            worktree /Users/x/Projects/app-wt/gone
            HEAD cccc
            branch refs/heads/gone
            prunable gitdir file points to non-existent location

            worktree /Users/x/Projects/app-wt/plain
            HEAD dddd
            branch refs/heads/plain
            """
        let wts = WorktreeListParser.parse(out, mainPath: "/Users/x/Projects/app")
        XCTAssertEqual(wts.count, 3)
        XCTAssertTrue(wts[0].locked)
        XCTAssertFalse(wts[0].prunable)
        XCTAssertTrue(wts[1].prunable)
        XCTAssertFalse(wts[1].locked)
        XCTAssertFalse(wts[2].locked)
        XCTAssertFalse(wts[2].prunable)

        let bare = WorktreeListParser.parse(
            """
            worktree /Users/x/Projects/app
            HEAD aaaa
            branch refs/heads/main

            worktree /Users/x/Projects/app-wt/pinned
            HEAD bbbb
            branch refs/heads/pinned
            locked
            """, mainPath: "/Users/x/Projects/app")
        XCTAssertTrue(bare[0].locked)
    }

    func testClaudeManagedHeuristic() {
        XCTAssertTrue(WorktreeListParser.looksClaudeManaged("/Users/x/.claude/worktrees/y"))
        XCTAssertTrue(WorktreeListParser.looksClaudeManaged("/tmp/claude-worktree-abc"))
        XCTAssertTrue(WorktreeListParser.looksClaudeManaged("/repo/worktrees/feature"))
        XCTAssertFalse(WorktreeListParser.looksClaudeManaged("/Users/x/Projects/sidecheckout"))
    }
}
