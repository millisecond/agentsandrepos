import XCTest

@testable import AgentsAndReposCore

final class SummaryFactsTests: XCTestCase {

    // MARK: - Fixtures

    private func agent(
        _ status: AgentSession.Status, name: String = "agent", sessionId: String = "s1"
    ) -> AgentSession {
        AgentSession(
            pid: 1, sessionId: sessionId, cwd: "/x", name: name, kind: "interactive",
            status: status, startedAt: nil, updatedAt: nil)
    }

    private func repo(
        name: String = "repo", git: GitState? = GitState(branch: "main"),
        agents: [AgentSession] = [], prs: [PullRequest] = []
    ) -> RepoOverview {
        RepoOverview(
            repo: Repo(path: "/p/\(name)", name: name, root: "/p"),
            git: git, agents: agents, prs: prs, worktrees: [], githubRepo: nil)
    }

    private func pr(_ ci: PullRequest.CIStatus) -> PullRequest {
        PullRequest(
            number: 1, title: "t", url: "u", isDraft: false, author: "a",
            headRefName: "b", reviewDecision: nil, ci: ci)
    }

    // MARK: - Keys

    func testKeysAreStableAndNamespaced() {
        let r = RepoTileState(repo: repo(name: "r"))
        let a = AgentTileState(agent: agent(.busy, sessionId: "abc"), location: "l", path: "/x")
        XCTAssertEqual(SummaryFacts.repoKey(r), "repo:/p/r")
        XCTAssertEqual(SummaryFacts.agentUserKey(a), "agent:abc:user")
        XCTAssertEqual(SummaryFacts.agentAgentKey(a), "agent:abc:asst")
        XCTAssertEqual(SummaryFacts.workspaceKey, "workspace")
    }

    // MARK: - Repo plans & facts

    func testCleanAndSyncRepoPlansAreDeterministic() {
        XCTAssertEqual(
            SummaryFacts.repoPlan(RepoTileState(repo: repo())),
            .fixed("Clean and in sync."))
        XCTAssertEqual(
            SummaryFacts.repoPlan(RepoTileState(repo: repo(git: GitState(branch: "m", ahead: 2)))),
            .fixed("Push 2 commits."))
        XCTAssertEqual(
            SummaryFacts.repoPlan(RepoTileState(repo: repo(git: GitState(branch: "m", behind: 1)))),
            .fixed("Pull 1 commit."))
        XCTAssertEqual(
            SummaryFacts.repoPlan(
                RepoTileState(repo: repo(git: GitState(branch: "m", ahead: 2, behind: 3)))),
            .fixed("Push 2, pull 3."))
        XCTAssertEqual(
            SummaryFacts.repoPlan(
                RepoTileState(repo: repo(git: GitState(branch: "m", fetchError: "boom")))),
            .fixed("Can't reach remote."))
        XCTAssertEqual(
            SummaryFacts.repoPlan(
                RepoTileState(repo: repo(git: GitState(branch: "m", statusError: "boom")))),
            .fixed("Git status failing."))
    }

    func testDirtyRepoPlanGeneratesFromNamingSignal() {
        let session = AgentSession(
            pid: 1, sessionId: "s", cwd: "/x", name: "a", kind: "interactive",
            status: .busy, startedAt: nil, updatedAt: nil,
            task: AgentTask(lastUserMessage: "add AI summaries"))
        let tile = RepoTileState(repo: repo(
            git: GitState(
                branch: "main", dirty: 2,
                changedPaths: ["Sources/App/TileView.swift", "README.md"]),
            agents: [session]))
        guard case .generate(let facts) = SummaryFacts.repoPlan(tile) else {
            return XCTFail("expected .generate")
        }
        XCTAssertTrue(facts.contains("Changed files: TileView.swift, README.md"))
        XCTAssertFalse(facts.contains("Sources/App"))
        XCTAssertTrue(facts.contains("Agent task: add AI summaries"))
        // Counts/PR/CI are badge territory — not naming signal.
        XCTAssertFalse(facts.contains("modified"))
    }

    func testDirtyRepoWithoutPathsFallsBackToFixed() {
        XCTAssertEqual(
            SummaryFacts.repoPlan(RepoTileState(repo: repo(git: GitState(branch: "m", dirty: 3)))),
            .fixed("Uncommitted local changes."))
    }

    func testRepoFactsAreDeterministic() {
        let r = repo(git: GitState(branch: "main", dirty: 2, changedPaths: ["a.swift"]))
        XCTAssertEqual(
            SummaryFacts.repoFacts(RepoTileState(repo: r)),
            SummaryFacts.repoFacts(RepoTileState(repo: r)))
    }

    // MARK: - Agent plans

    func testAgentWithoutMessagesPlansNone() {
        let tile = AgentTileState(agent: agent(.idle), location: "web", path: "/x")
        XCTAssertEqual(SummaryFacts.agentUserPlan(tile), .none)
        XCTAssertEqual(SummaryFacts.agentAgentPlan(tile), .none)
    }

    func testAgentPlansUseOnlyTheirOwnMessage() {
        let long = String(repeating: "fix the login bug ", count: 5)
            .trimmingCharacters(in: .whitespaces)
        let s = AgentSession(
            pid: 1, sessionId: "s", cwd: "/x", name: "fix-ci", kind: "interactive",
            status: .busy, startedAt: nil, updatedAt: nil,
            task: AgentTask(
                lastUserMessage: long, lastAgentMessage: "found the cause",
                userSpokeLast: true))
        let tile = AgentTileState(agent: s, location: "web", path: "/x")
        // Each prompt is the bare message — no status, no name, no location,
        // and no cross-contamination between the two.
        XCTAssertEqual(SummaryFacts.agentUserPlan(tile), .generate(long))
        XCTAssertEqual(SummaryFacts.agentAgentPlan(tile), .generate("found the cause"))
    }

    func testShortUserMessageShownVerbatim() {
        func tile(userMessage: String) -> AgentTileState {
            let s = AgentSession(
                pid: 1, sessionId: "s", cwd: "/x", name: "fix-ci", kind: "interactive",
                status: .busy, startedAt: nil, updatedAt: nil,
                task: AgentTask(lastUserMessage: userMessage, userSpokeLast: true))
            return AgentTileState(agent: s, location: "web", path: "/x")
        }
        XCTAssertEqual(
            SummaryFacts.agentUserPlan(tile(userMessage: "fix the login bug")),
            .fixed("fix the login bug"))
        let atCap = String(repeating: "x", count: SummaryFacts.verbatimUserMessageMaxChars)
        XCTAssertEqual(SummaryFacts.agentUserPlan(tile(userMessage: atCap)), .fixed(atCap))
        XCTAssertEqual(
            SummaryFacts.agentUserPlan(tile(userMessage: atCap + "x")),
            .generate(atCap + "x"))
    }

    // MARK: - Workspace facts

    func testWorkspaceFactsAggregate() {
        var snap = Snapshot.empty
        snap.repos = [
            repo(name: "clean"),
            repo(name: "dirty", git: GitState(branch: "m", dirty: 1),
                 agents: [agent(.busy)], prs: [pr(.fail)]),
            repo(name: "behind", git: GitState(branch: "m", behind: 3),
                 agents: [agent(.waiting(nil), sessionId: "s2")]),
        ]
        let facts = SummaryFacts.workspaceFacts(snap)
        XCTAssertTrue(facts.contains("3 repos."))
        XCTAssertTrue(facts.contains("1 with uncommitted changes."))
        XCTAssertTrue(facts.contains("1 out of sync with upstream."))
        XCTAssertTrue(facts.contains("2 coding agents:"))
        XCTAssertTrue(facts.contains("1 working,"))
        XCTAssertTrue(facts.contains("1 waiting on the user,"))
        XCTAssertTrue(facts.contains("1 open pull request, 1 with failing CI."))
    }

    func testWorkspaceFactsEmpty() {
        let facts = SummaryFacts.workspaceFacts(.empty)
        XCTAssertTrue(facts.contains("0 repos."))
        XCTAssertTrue(facts.contains("No coding agents running."))
    }

    func testWorkspaceFactsExcludeIgnored() {
        var snap = Snapshot.empty
        snap.repos = [
            repo(name: "keep"),
            repo(name: "hide", git: GitState(branch: "m", dirty: 9), prs: [pr(.fail)]),
        ]
        snap.config.ignoredRepos = ["/p/hide"]
        let facts = SummaryFacts.workspaceFacts(snap)
        XCTAssertTrue(facts.contains("1 repo."))
        XCTAssertFalse(facts.contains("uncommitted"))
        XCTAssertFalse(facts.contains("pull request"))
    }
}
