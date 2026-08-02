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

    func testClaudeManagedHeuristic() {
        XCTAssertTrue(WorktreeListParser.looksClaudeManaged("/Users/x/.claude/worktrees/y"))
        XCTAssertTrue(WorktreeListParser.looksClaudeManaged("/tmp/claude-worktree-abc"))
        XCTAssertTrue(WorktreeListParser.looksClaudeManaged("/repo/worktrees/feature"))
        XCTAssertFalse(WorktreeListParser.looksClaudeManaged("/Users/x/Projects/sidecheckout"))
    }
}
