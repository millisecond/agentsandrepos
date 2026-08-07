import XCTest

@testable import AgentsAndReposCore

final class TileStateTests: XCTestCase {

    // MARK: - Fixtures

    private func agent(
        _ status: AgentSession.Status, name: String = "agent", kind: String = "interactive",
        sessionId: String = UUID().uuidString
    ) -> AgentSession {
        AgentSession(
            pid: 1, sessionId: sessionId, cwd: "/x", name: name, kind: kind,
            status: status, startedAt: nil, updatedAt: nil)
    }

    private func repo(
        name: String = "repo", git: GitState? = GitState(branch: "main"),
        agents: [AgentSession] = [], prs: [PullRequest] = [],
        worktrees: [WorktreeOverview] = [], runs: [WorkflowRun] = []
    ) -> RepoOverview {
        RepoOverview(
            repo: Repo(path: "/p/\(name)", name: name, root: "/p"),
            git: git, agents: agents, prs: prs, worktrees: worktrees, githubRepo: nil,
            runs: runs)
    }

    private func run(_ state: WorkflowRun.State, workflow: String = "Deploy") -> WorkflowRun {
        WorkflowRun(
            id: 1, workflowName: workflow, title: "t", branch: "main", event: "push",
            state: state, url: "u")
    }

    private func pr(_ ci: PullRequest.CIStatus, number: Int = 1) -> PullRequest {
        PullRequest(
            number: number, title: "t", url: "u", isDraft: false, author: "a",
            headRefName: "b", reviewDecision: nil, ci: ci)
    }

    // MARK: - Agent tiles

    func testAgentSeverityMapping() {
        XCTAssertEqual(AgentTileState(agent: agent(.waiting(nil)), location: "l", path: "/x").severity, .attention)
        XCTAssertEqual(AgentTileState(agent: agent(.busy), location: "l", path: "/x").severity, .info)
        XCTAssertEqual(AgentTileState(agent: agent(.idle), location: "l", path: "/x").severity, .muted)
        XCTAssertEqual(AgentTileState(agent: agent(.unknown("x")), location: "l", path: "/x").severity, .muted)
    }

    func testOnlyBusyAgentsPulse() {
        XCTAssertTrue(AgentTileState(agent: agent(.busy), location: "l", path: "/x").isPulsing)
        XCTAssertFalse(AgentTileState(agent: agent(.waiting(nil)), location: "l", path: "/x").isPulsing)
        XCTAssertFalse(AgentTileState(agent: agent(.idle), location: "l", path: "/x").isPulsing)
    }

    func testBackgroundAgentTitleTagged() {
        let tile = AgentTileState(agent: agent(.busy, name: "fix", kind: "bg"), location: "l", path: "/x")
        XCTAssertEqual(tile.title, "fix (bg)")
    }

    func testAgentTilesSortWaitingFirst() {
        var snap = Snapshot.empty
        snap.repos = [
            repo(name: "a", agents: [agent(.idle, name: "zz-idle")]),
            repo(name: "b", agents: [agent(.busy, name: "aa-busy")]),
            repo(name: "c", agents: [agent(.waiting(nil), name: "mm-wait")]),
        ]
        XCTAssertEqual(snap.agentTiles.map(\.title), ["mm-wait", "aa-busy", "zz-idle"])
    }

    func testWorktreeAgentLocationAndOtherAgentsIncluded() {
        let wt = WorktreeOverview(
            worktree: Worktree(path: "/p/r-wt", branch: "f", detached: false, isClaudeManaged: true),
            git: nil, agents: [agent(.busy, name: "wt-agent")])
        var snap = Snapshot.empty
        snap.repos = [repo(name: "r", worktrees: [wt])]
        snap.otherAgents = [agent(.idle, name: "stray")]
        let tiles = snap.agentTiles
        XCTAssertEqual(tiles.count, 2)
        XCTAssertEqual(tiles[0].subtitle, "r ⎇ r-wt")
        XCTAssertEqual(tiles[0].path, "/p/r-wt")
        XCTAssertEqual(tiles[1].title, "stray")
    }

    // MARK: - PR tiles

    private func pr(
        ci: PullRequest.CIStatus = .none, number: Int = 1, draft: Bool = false,
        review: String? = nil, url: String = "u", updated: Date? = nil
    ) -> PullRequest {
        PullRequest(
            number: number, title: "t", url: url, isDraft: draft, author: "a",
            headRefName: "b", reviewDecision: review, ci: ci, updatedAt: updated)
    }

    func testPRSeverityPrecedence() {
        // CI fail beats everything, even on a draft.
        XCTAssertEqual(PRTileState.severity(pr(ci: .fail, draft: true)), .urgent)
        // Changes requested beats draft and pending CI.
        XCTAssertEqual(
            PRTileState.severity(pr(ci: .pending, draft: true, review: "CHANGES_REQUESTED")),
            .attention)
        // Draft mutes an otherwise-quiet PR.
        XCTAssertEqual(PRTileState.severity(pr(ci: .pass, draft: true)), .muted)
        // Pending CI is info.
        XCTAssertEqual(PRTileState.severity(pr(ci: .pending)), .info)
        // Approved or green CI is ok.
        XCTAssertEqual(PRTileState.severity(pr(review: "APPROVED")), .ok)
        XCTAssertEqual(PRTileState.severity(pr(ci: .pass)), .ok)
        // Nothing known yet: awaiting review.
        XCTAssertEqual(PRTileState.severity(pr()), .info)
    }

    func testPRStatusLabel() {
        XCTAssertEqual(PRTileState.statusLabel(pr(ci: .fail)), "CI failing")
        XCTAssertEqual(
            PRTileState.statusLabel(pr(review: "CHANGES_REQUESTED")), "changes requested")
        XCTAssertEqual(PRTileState.statusLabel(pr(draft: true)), "draft")
        XCTAssertEqual(PRTileState.statusLabel(pr(ci: .pending)), "CI running")
        XCTAssertEqual(
            PRTileState.statusLabel(pr(ci: .pass, review: "APPROVED")), "approved · CI passing")
        XCTAssertEqual(PRTileState.statusLabel(pr(review: "APPROVED")), "approved")
        XCTAssertEqual(PRTileState.statusLabel(pr(ci: .pass)), "CI passing")
        XCTAssertEqual(PRTileState.statusLabel(pr()), "awaiting review")
    }

    func testPRTilesSortByRecencyThenRepoThenNumber() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        var snap = Snapshot.empty
        snap.repos = [
            // Newest activity wins regardless of repo name or CI state.
            repo(name: "zeta", prs: [pr(ci: .pass, number: 9, url: "z9", updated: now)]),
            repo(
                name: "alpha",
                prs: [
                    pr(ci: .fail, number: 3, url: "a3", updated: now.addingTimeInterval(-3_600)),
                    // No date sorts last; equal-date ties break by number.
                    pr(ci: .pass, number: 7, url: "a7"),
                    pr(ci: .pass, number: 2, url: "a2", updated: now.addingTimeInterval(-3_600)),
                ]),
        ]
        XCTAssertEqual(snap.prTiles.map(\.id), ["z9", "a2", "a3", "a7"])
        XCTAssertEqual(snap.prTiles.first?.reference, "zeta #9")
    }

    func testPRTilesExcludeIgnoredRepos() {
        var snap = Snapshot.empty
        snap.repos = [
            repo(name: "shown", prs: [pr(url: "s1")]),
            repo(name: "hidden", prs: [pr(url: "h1")]),
        ]
        snap.config.ignoredRepos = ["/p/hidden"]
        XCTAssertEqual(snap.prTiles.map(\.id), ["s1"])
    }

    // MARK: - Repo tiles

    func testRepoSeverityPrecedence() {
        // CI fail beats everything.
        XCTAssertEqual(
            RepoTileState(repo: repo(git: GitState(branch: "m", dirty: 3), prs: [pr(.fail)])).severity,
            .urgent)
        // Status error (local git breakage) is urgent.
        XCTAssertEqual(
            RepoTileState(repo: repo(git: GitState(branch: "m", statusError: "boom"))).severity,
            .urgent)
        // Fetch error alone is NOT urgent — an unreachable clean repo reads
        // muted (unknown), or work machines drown in wrong-account repos.
        XCTAssertEqual(
            RepoTileState(repo: repo(git: GitState(branch: "m", fetchError: "auth"))).severity,
            .muted)
        // But local work on an unreachable repo still ranks on its merits.
        XCTAssertEqual(
            RepoTileState(
                repo: repo(git: GitState(branch: "m", dirty: 1, fetchError: "auth"))).severity,
            .info)
        // Dirty is info, not attention — uncommitted work is the normal
        // state of an active repo, not something to warn about.
        XCTAssertEqual(
            RepoTileState(repo: repo(git: GitState(branch: "m", dirty: 1))).severity, .info)
        // Waiting agent raises to attention even when clean.
        XCTAssertEqual(
            RepoTileState(repo: repo(agents: [agent(.waiting(nil))])).severity, .attention)
        // Ahead/behind only is info.
        XCTAssertEqual(
            RepoTileState(repo: repo(git: GitState(branch: "m", ahead: 2))).severity, .info)
        // Busy agent on a clean repo is info.
        XCTAssertEqual(
            RepoTileState(repo: repo(agents: [agent(.busy)])).severity, .info)
        // Clean is ok.
        XCTAssertEqual(RepoTileState(repo: repo()).severity, .ok)
        // No git state yet is muted.
        XCTAssertEqual(RepoTileState(repo: repo(git: nil)).severity, .muted)
    }

    func testProblemsAreFailuresOnlyWithActionURLs() {
        let tile = RepoTileState(
            repo: repo(
                git: GitState(branch: "m", ahead: 3, dirty: 10, untracked: 2),
                runs: [run(.failed)]))
        // Counts are state, not problems; the failed run links to itself.
        XCTAssertEqual(tile.problems.map(\.label), ["Deploy failed"])
        XCTAssertEqual(tile.problems[0].url, "u")
        XCTAssertEqual(tile.stateInfo, ["10 modified", "2 new", "3 to push"])
    }

    func testCleanRepoHasNoProblemsOrState() {
        XCTAssertTrue(RepoTileState(repo: repo()).problems.isEmpty)
        XCTAssertTrue(RepoTileState(repo: repo()).stateInfo.isEmpty)
        XCTAssertTrue(RepoTileState(repo: repo(runs: [run(.running)])).problems.isEmpty)
    }

    func testWaitingAgentAndFailingPRAreProblems() {
        let tile = RepoTileState(
            repo: repo(agents: [agent(.waiting(nil))], prs: [pr(.fail)]))
        XCTAssertEqual(
            tile.problems.map(\.label), ["PR checks failing", "agent waiting on input"])
        // The failing-PR problem deep-links to the PR itself.
        XCTAssertEqual(tile.problems[0].url, "u")
        XCTAssertEqual(tile.problems[0].severity, .urgent)
        XCTAssertEqual(tile.problems[1].severity, .attention)
        XCTAssertNil(tile.problems[1].url)
    }

    func testQuietUnreachableDetection() {
        XCTAssertTrue(
            RepoTileState(repo: repo(git: GitState(branch: "m", fetchError: "auth")))
                .isQuietUnreachable)
        XCTAssertFalse(
            RepoTileState(repo: repo(git: GitState(branch: "m", dirty: 1, fetchError: "auth")))
                .isQuietUnreachable)
        XCTAssertFalse(RepoTileState(repo: repo()).isQuietUnreachable)
    }

    func testUnreachableAppearsLastInStateInfo() {
        let tile = RepoTileState(
            repo: repo(git: GitState(branch: "m", dirty: 2, fetchError: "auth")))
        XCTAssertEqual(tile.stateInfo, ["2 modified", "can't connect"])
        XCTAssertTrue(tile.problems.isEmpty)
    }

    func testPRTilesDedupeAcrossClonesOfSameRemote() {
        // Two local clones of the same GitHub repo fetch identical PRs; the
        // grid must not render the same PR (same URL id) twice.
        let shared = PullRequest(
            number: 7, title: "t", url: "https://github.com/o/r/pull/7", isDraft: false,
            author: "a", headRefName: "b", reviewDecision: nil, ci: .pass)
        var snap = Snapshot.empty
        snap.repos = [
            repo(name: "clone-a", prs: [shared]),
            repo(name: "clone-b", prs: [shared]),
        ]
        XCTAssertEqual(snap.prTiles.count, 1)
        XCTAssertEqual(snap.prTiles[0].repoName, "clone-a")
    }

    func testWorkflowRunSeverity() {
        // Failed run beats everything, like CI fail.
        XCTAssertEqual(
            RepoTileState(repo: repo(git: GitState(branch: "m", dirty: 3), runs: [run(.failed)]))
                .severity,
            .urgent)
        // Running action on a clean repo is info.
        XCTAssertEqual(
            RepoTileState(repo: repo(runs: [run(.running)])).severity, .info)
        // Passed run doesn't change a clean repo's ok.
        XCTAssertEqual(
            RepoTileState(repo: repo(runs: [run(.passed)])).severity, .ok)
        // Worst-run rollup lands on the tile.
        let tile = RepoTileState(
            repo: repo(runs: [run(.passed), run(.running, workflow: "Nightly")]))
        XCTAssertEqual(tile.worstRun, .running)
        XCTAssertEqual(tile.runs.count, 2)
    }

    func testWorktreeTileCarriesNoRuns() {
        let wt = WorktreeOverview(
            worktree: Worktree(path: "/p/r-b", branch: "b", detached: false, isClaudeManaged: false),
            git: GitState(branch: "b"), agents: [])
        let overview = repo(worktrees: [wt], runs: [run(.failed)])
        let tile = RepoTileState(worktree: wt, parent: overview)
        XCTAssertTrue(tile.runs.isEmpty)
        XCTAssertNil(tile.worstRun)
        XCTAssertNotEqual(tile.severity, .urgent)
    }

    func testWorstCIOrdering() {
        XCTAssertEqual(RepoTileState.worstCI(of: [pr(.pass), pr(.fail), pr(.pending)]), .fail)
        XCTAssertEqual(RepoTileState.worstCI(of: [pr(.pass), pr(.pending)]), .pending)
        XCTAssertEqual(RepoTileState.worstCI(of: [pr(.pass), pr(.none)]), .pass)
        XCTAssertEqual(RepoTileState.worstCI(of: []), PullRequest.CIStatus.none)
    }

    func testRepoDotsExcludeWorktreeAgents() {
        // Worktree agents dot their own first-class tile, not the parent's.
        let wtDirty = WorktreeOverview(
            worktree: Worktree(path: "/p/r-b", branch: "b", detached: false, isClaudeManaged: true),
            git: GitState(branch: "b", dirty: 2), agents: [agent(.busy)])
        let overview = repo(agents: [agent(.waiting(nil))], worktrees: [wtDirty])
        XCTAssertEqual(RepoTileState(repo: overview).agentDots, [.attention])
        XCTAssertEqual(
            RepoTileState(worktree: wtDirty, parent: overview).agentDots, [.info])
    }

    func testRepoTilesWithoutActivitySortAlphabeticallyRegardlessOfSeverity() {
        var snap = Snapshot.empty
        snap.repos = [
            repo(name: "zeta"),
            repo(name: "alpha"),
            repo(name: "dirty", git: GitState(branch: "m", dirty: 1)),
            repo(name: "broken", git: GitState(branch: "m", fetchError: "x")),
        ]
        XCTAssertEqual(snap.repoTiles.map(\.name), ["alpha", "broken", "dirty", "zeta"])
    }

    func testDetachedBranchLabel() {
        XCTAssertEqual(
            RepoTileState(repo: repo(git: GitState(branch: nil, detached: true))).branch,
            "detached")
        XCTAssertEqual(RepoTileState(repo: repo(git: nil)).branch, "…")
    }

    // MARK: - Ignoring

    func testIgnoredAgentsSplitOutOfTiles() {
        var snap = Snapshot.empty
        snap.repos = [
            repo(name: "a", agents: [agent(.busy, name: "keep", sessionId: "s-keep")]),
            repo(name: "b", agents: [agent(.waiting(nil), name: "hide", sessionId: "s-hide")]),
        ]
        snap.config.ignoredAgents = ["s-hide"]
        XCTAssertEqual(snap.agentTiles.map(\.title), ["keep"])
        XCTAssertEqual(snap.ignoredAgentTiles.map(\.title), ["hide"])
        XCTAssertEqual(snap.visibleAgents.map(\.sessionId), ["s-keep"])
    }

    func testIgnoredReposSplitOutOfTilesAndPRs() {
        var snap = Snapshot.empty
        snap.repos = [
            repo(name: "keep", prs: [pr(.pass, number: 1)]),
            repo(name: "hide", git: GitState(branch: "m", dirty: 5), prs: [pr(.fail, number: 2)]),
        ]
        snap.config.ignoredRepos = ["/p/hide"]
        XCTAssertEqual(snap.repoTiles.map(\.name), ["keep"])
        XCTAssertEqual(snap.ignoredRepoTiles.map(\.name), ["hide"])
        XCTAssertEqual(snap.visibleRepos.map(\.repo.name), ["keep"])
        XCTAssertEqual(snap.visiblePRs.map(\.pr.number), [1])
    }

    func testIgnoringRepoDoesNotHideItsAgents() {
        var snap = Snapshot.empty
        snap.repos = [repo(name: "hide", agents: [agent(.busy, name: "worker")])]
        snap.config.ignoredRepos = ["/p/hide"]
        XCTAssertEqual(snap.agentTiles.map(\.title), ["worker"])
    }

    func testNothingIgnoredByDefault() {
        var snap = Snapshot.empty
        snap.repos = [repo(name: "r", agents: [agent(.busy)])]
        XCTAssertTrue(snap.ignoredAgentTiles.isEmpty)
        XCTAssertTrue(snap.ignoredRepoTiles.isEmpty)
        XCTAssertEqual(snap.repoTiles.count, 1)
        XCTAssertEqual(snap.agentTiles.count, 1)
    }

    // MARK: - Worktree tiles

    func testWorktreeTitleStripsRedundantRepoPrefix() {
        XCTAssertEqual(
            RepoTileState.worktreeTitle(repoName: "former", worktreeName: "former-auth"),
            "former ⎇ auth")
        XCTAssertEqual(
            RepoTileState.worktreeTitle(repoName: "former", worktreeName: "auth-fix"),
            "former ⎇ auth-fix")
        // A name that IS just the prefix stays whole rather than going empty.
        XCTAssertEqual(
            RepoTileState.worktreeTitle(repoName: "former", worktreeName: "former-"),
            "former ⎇ former-")
    }

    func testWorktreeTilesAreSeparateFromRepoTiles() {
        let wt = WorktreeOverview(
            worktree: Worktree(path: "/wt/r-auth", branch: "auth", detached: false, isClaudeManaged: true),
            git: GitState(branch: "auth", dirty: 1), agents: [])
        var snap = Snapshot.empty
        snap.repos = [repo(name: "r", worktrees: [wt])]
        XCTAssertEqual(snap.repoTiles.map(\.name), ["r"])
        XCTAssertFalse(snap.repoTiles[0].isWorktree)
        let tiles = snap.worktreeTiles
        XCTAssertEqual(tiles.count, 1)
        XCTAssertEqual(tiles[0].name, "r ⎇ auth")
        XCTAssertTrue(tiles[0].isWorktree)
        XCTAssertTrue(tiles[0].isClaudeManaged)
        XCTAssertEqual(tiles[0].path, "/wt/r-auth")
        XCTAssertEqual(tiles[0].branch, "auth")
        // Dirty worktree is info, same as dirty repos — normal work.
        XCTAssertEqual(tiles[0].severity, .info)
    }

    func testWorktreeBranchPRMovesToWorktreeTile() {
        let wt = WorktreeOverview(
            worktree: Worktree(path: "/wt/r-b", branch: "b", detached: false, isClaudeManaged: false),
            git: GitState(branch: "b"), agents: [])
        let overview = RepoOverview(
            repo: Repo(path: "/p/r", name: "r", root: "/p"),
            git: GitState(branch: "main"),
            agents: [],
            prs: [
                PullRequest(
                    number: 1, title: "main pr", url: "u1", isDraft: false, author: "a",
                    headRefName: "main", reviewDecision: nil, ci: .pass),
                PullRequest(
                    number: 2, title: "wt pr", url: "u2", isDraft: false, author: "a",
                    headRefName: "b", reviewDecision: nil, ci: .fail),
            ],
            worktrees: [wt], githubRepo: nil)
        let repoTile = RepoTileState(repo: overview)
        XCTAssertEqual(repoTile.prCount, 1)
        XCTAssertEqual(repoTile.worstCI, .pass)
        let wtTile = RepoTileState(worktree: wt, parent: overview)
        XCTAssertEqual(wtTile.prCount, 1)
        XCTAssertEqual(wtTile.worstCI, .fail)
        XCTAssertEqual(wtTile.severity, .urgent)
    }

    func testIgnoredWorktreeHidesAndJoinsHiddenList() {
        let wt = WorktreeOverview(
            worktree: Worktree(path: "/wt/r-b", branch: "b", detached: false, isClaudeManaged: false),
            git: GitState(branch: "b"), agents: [])
        var snap = Snapshot.empty
        snap.repos = [repo(name: "r", worktrees: [wt])]
        snap.config.ignoredRepos = ["/wt/r-b"]
        XCTAssertEqual(snap.repoTiles.map(\.name), ["r"])
        XCTAssertTrue(snap.worktreeTiles.isEmpty)
        XCTAssertEqual(snap.ignoredRepoTiles.map(\.name), ["r ⎇ b"])
    }

    func testWorktreesOfIgnoredRepoHideWithItWithoutOwnRows() {
        let wt = WorktreeOverview(
            worktree: Worktree(path: "/wt/r-b", branch: "b", detached: false, isClaudeManaged: false),
            git: GitState(branch: "b"), agents: [])
        var snap = Snapshot.empty
        snap.repos = [repo(name: "hide", worktrees: [wt])]
        snap.config.ignoredRepos = ["/p/hide"]
        XCTAssertTrue(snap.repoTiles.isEmpty)
        XCTAssertTrue(snap.worktreeTiles.isEmpty)
        XCTAssertEqual(snap.ignoredRepoTiles.map(\.name), ["hide"])
    }

    func testWorktreeTileSeverity() {
        let broken = WorktreeOverview(
            worktree: Worktree(path: "/p/w", branch: "b", detached: false, isClaudeManaged: false),
            git: GitState(branch: "b", statusError: "x"), agents: [])
        XCTAssertEqual(WorktreeTileState(worktree: broken, repoName: "r").severity, .urgent)

        let dirty = WorktreeOverview(
            worktree: Worktree(path: "/p/w", branch: "b", detached: false, isClaudeManaged: false),
            git: GitState(branch: "b", untracked: 1), agents: [])
        XCTAssertEqual(WorktreeTileState(worktree: dirty, repoName: "r").severity, .attention)

        let working = WorktreeOverview(
            worktree: Worktree(path: "/p/w", branch: "b", detached: false, isClaudeManaged: true),
            git: GitState(branch: "b"), agents: [agent(.busy)])
        XCTAssertEqual(WorktreeTileState(worktree: working, repoName: "r").severity, .info)

        let idle = WorktreeOverview(
            worktree: Worktree(path: "/p/w", branch: "b", detached: false, isClaudeManaged: false),
            git: GitState(branch: "b"), agents: [])
        XCTAssertEqual(WorktreeTileState(worktree: idle, repoName: "r").severity, .ok)
    }
}
