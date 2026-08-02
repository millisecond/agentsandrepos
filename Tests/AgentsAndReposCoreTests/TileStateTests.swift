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
        worktrees: [WorktreeOverview] = []
    ) -> RepoOverview {
        RepoOverview(
            repo: Repo(path: "/p/\(name)", name: name, root: "/p"),
            git: git, agents: agents, prs: prs, worktrees: worktrees, githubRepo: nil)
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

    // MARK: - Repo tiles

    func testRepoSeverityPrecedence() {
        // CI fail beats everything.
        XCTAssertEqual(
            RepoTileState(repo: repo(git: GitState(branch: "m", dirty: 3), prs: [pr(.fail)])).severity,
            .urgent)
        // Fetch error is urgent.
        XCTAssertEqual(
            RepoTileState(repo: repo(git: GitState(branch: "m", fetchError: "boom"))).severity,
            .urgent)
        // Dirty is attention.
        XCTAssertEqual(
            RepoTileState(repo: repo(git: GitState(branch: "m", dirty: 1))).severity, .attention)
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

    func testRepoTilesSortAttentionFirstThenName() {
        var snap = Snapshot.empty
        snap.repos = [
            repo(name: "zeta"),
            repo(name: "alpha"),
            repo(name: "dirty", git: GitState(branch: "m", dirty: 1)),
            repo(name: "broken", git: GitState(branch: "m", fetchError: "x")),
        ]
        XCTAssertEqual(snap.repoTiles.map(\.name), ["broken", "dirty", "alpha", "zeta"])
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

    func testWorktreeTilesAreFirstClassInRepoTiles() {
        let wt = WorktreeOverview(
            worktree: Worktree(path: "/wt/r-auth", branch: "auth", detached: false, isClaudeManaged: true),
            git: GitState(branch: "auth", dirty: 1), agents: [])
        var snap = Snapshot.empty
        snap.repos = [repo(name: "r", worktrees: [wt])]
        let tiles = snap.repoTiles
        XCTAssertEqual(tiles.count, 2)
        // Dirty worktree (attention) sorts ahead of its clean parent (ok).
        XCTAssertEqual(tiles[0].name, "r ⎇ auth")
        XCTAssertTrue(tiles[0].isWorktree)
        XCTAssertTrue(tiles[0].isClaudeManaged)
        XCTAssertEqual(tiles[0].path, "/wt/r-auth")
        XCTAssertEqual(tiles[0].branch, "auth")
        XCTAssertEqual(tiles[0].severity, .attention)
        XCTAssertEqual(tiles[1].name, "r")
        XCTAssertFalse(tiles[1].isWorktree)
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
        XCTAssertEqual(snap.hiddenRepoEntries.map(\.tile.name), ["r ⎇ b"])
        XCTAssertEqual(snap.hiddenRepoEntries.first?.reason, .ignored)
    }

    func testWorktreesOfIgnoredRepoHideWithItWithoutOwnRows() {
        let wt = WorktreeOverview(
            worktree: Worktree(path: "/wt/r-b", branch: "b", detached: false, isClaudeManaged: false),
            git: GitState(branch: "b"), agents: [])
        var snap = Snapshot.empty
        snap.repos = [repo(name: "hide", worktrees: [wt])]
        snap.config.ignoredRepos = ["/p/hide"]
        XCTAssertTrue(snap.repoTiles.isEmpty)
        XCTAssertEqual(snap.hiddenRepoEntries.map(\.tile.name), ["hide"])
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
