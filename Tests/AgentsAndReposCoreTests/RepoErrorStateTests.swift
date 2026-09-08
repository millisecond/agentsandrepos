import XCTest

@testable import AgentsAndReposCore

/// `RepoOverview.hasError` drives the status item's dead-eyes error state:
/// broken plumbing (git status failures) and failing PR checks count;
/// ordinary dirt (uncommitted/ahead/behind) does not, and neither do fetch
/// errors — a wrong-account machine has dozens of unreachable repos that the
/// dashboard lumps quietly, and a permanent error badge would undo that.
final class RepoErrorStateTests: XCTestCase {

    private func overview(
        git: GitState? = nil, prs: [PullRequest] = [], worktrees: [WorktreeOverview] = []
    ) -> RepoOverview {
        RepoOverview(
            repo: Repo(path: "/tmp/r", name: "r", root: "/tmp", isRoot: false),
            git: git, agents: [], prs: prs, worktrees: worktrees, githubRepo: nil)
    }

    private func pr(ci: PullRequest.CIStatus) -> PullRequest {
        PullRequest(
            number: 1, title: "t", url: "u", isDraft: false, author: "a",
            headRefName: "b", reviewDecision: nil, ci: ci)
    }

    func testDirtyRepoIsNotAnError() {
        let r = overview(git: GitState(ahead: 2, dirty: 5, untracked: 1))
        XCTAssertTrue(r.needsAttention)
        XCTAssertFalse(r.hasError)
    }

    func testStatusErrorsCountButFetchErrorsDoNot() {
        XCTAssertFalse(overview(git: GitState(fetchError: "boom")).hasError)
        XCTAssertTrue(overview(git: GitState(statusError: "boom")).hasError)
    }

    func testFailingPRCountsButOtherCIStatesDoNot() {
        XCTAssertTrue(overview(prs: [pr(ci: .fail)]).hasError)
        XCTAssertFalse(overview(prs: [pr(ci: .pass), pr(ci: .pending), pr(ci: .none)]).hasError)
    }

    func testWorktreeErrorBubblesUp() {
        let wt = WorktreeOverview(
            worktree: Worktree(path: "/tmp/r-wt", branch: "x", detached: false, isClaudeManaged: false),
            git: GitState(statusError: "boom"), agents: [])
        XCTAssertTrue(overview(worktrees: [wt]).hasError)
    }

    /// A stale record's status error is just "the directory is gone" — the
    /// dashboard shows it as a muted cleanup note, so the menu bar must not
    /// dead-eye over it (the badge would point at nothing visibly red).
    func testPrunableWorktreeErrorDoesNotBubbleUp() {
        let wt = WorktreeOverview(
            worktree: Worktree(
                path: "/tmp/r-wt", branch: "x", detached: false, isClaudeManaged: false,
                prunable: true),
            git: GitState(statusError: "fatal: cannot chdir"), agents: [])
        XCTAssertFalse(overview(worktrees: [wt]).hasError)
    }
}
