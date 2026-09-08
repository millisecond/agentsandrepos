import XCTest

@testable import AgentsAndReposCore

final class TileSearchTests: XCTestCase {

    // MARK: - Fixtures

    private func agent(
        _ status: AgentSession.Status = .idle, name: String = "agent",
        sessionId: String = UUID().uuidString, task: AgentTask = AgentTask()
    ) -> AgentSession {
        AgentSession(
            pid: 1, sessionId: sessionId, cwd: "/x", name: name, kind: "interactive",
            status: status, startedAt: nil, updatedAt: nil, task: task)
    }

    private func repo(
        name: String = "repo", git: GitState? = GitState(branch: "main"),
        agents: [AgentSession] = [], prs: [PullRequest] = [], githubRepo: String? = nil
    ) -> RepoOverview {
        RepoOverview(
            repo: Repo(path: "/p/\(name)", name: name, root: "/p"),
            git: git, agents: agents, prs: prs, worktrees: [], githubRepo: githubRepo,
            runs: [])
    }

    private func pr(title: String, author: String = "casey", number: Int = 1) -> PullRequest {
        PullRequest(
            number: number, title: title, url: "https://github.com/o/r/pull/\(number)",
            isDraft: false, author: author, headRefName: "feature", reviewDecision: nil,
            ci: .none)
    }

    // MARK: - Query semantics

    func testWhitespaceOnlyQueryIsEmptyAndMatchesEverything() {
        XCTAssertTrue(SearchQuery("").isEmpty)
        XCTAssertTrue(SearchQuery("   ").isEmpty)
        XCTAssertTrue(SearchQuery("  ").matches(["anything"]))
        XCTAssertTrue(SearchQuery("").matches([]))
    }

    func testMatchIsCaseInsensitiveSubstring() {
        let q = SearchQuery("WIDG")
        XCTAssertTrue(q.matches(["my-widgets-repo"]))
        XCTAssertFalse(q.matches(["gadgets"]))
    }

    func testMultipleTokensANDAcrossDifferentFields() {
        let q = SearchQuery("auth widgets")
        XCTAssertTrue(q.matches(["widgets", "fixing the auth flow"]))
        XCTAssertFalse(q.matches(["widgets", "fixing the search flow"]))
    }

    // MARK: - Tile matching

    func testAgentTileMatchesTranscriptContext() {
        let task = AgentTask(
            lastUserMessage: "fix the onboarding flow", lastAgentMessage: "Done, tests pass")
        let tile = AgentTileState(
            agent: agent(.busy, name: "helper", task: task), location: "widgets",
            path: "/p/widgets")
        XCTAssertTrue(tile.matches(SearchQuery("onboarding")))
        XCTAssertTrue(tile.matches(SearchQuery("tests pass")))
        XCTAssertTrue(tile.matches(SearchQuery("helper")))
        XCTAssertTrue(tile.matches(SearchQuery("widgets")))
        XCTAssertFalse(tile.matches(SearchQuery("billing")))
    }

    func testAgentTileMatchesDeepHistory() {
        let task = AgentTask(
            lastUserMessage: "latest thing", lastAgentMessage: "done",
            history: [
                TranscriptMessage(role: .user, text: "refactor the billing webhooks"),
                TranscriptMessage(role: .agent, text: "moved retries into the queue"),
                TranscriptMessage(role: .user, text: "latest thing"),
                TranscriptMessage(role: .agent, text: "done"),
            ])
        let tile = AgentTileState(
            agent: agent(.idle, task: task), location: "api", path: "/p/api")
        XCTAssertTrue(tile.matches(SearchQuery("webhooks")))
        XCTAssertTrue(tile.matches(SearchQuery("retries queue")))
        XCTAssertFalse(tile.matches(SearchQuery("invoices")))
    }

    func testAgentTileMatchesStatusLabel() {
        let tile = AgentTileState(
            agent: agent(.waiting("permission")), location: "l", path: "/x")
        XCTAssertTrue(tile.matches(SearchQuery("waiting")))
        XCTAssertTrue(tile.matches(SearchQuery("permission")))
    }

    func testRepoTileMatchesBranchPathsAndAgentTasks(  ) {
        let git = GitState(branch: "fix-login", changedPaths: ["Sources/Auth/Login.swift"])
        let worker = agent(.busy, task: AgentTask(lastUserMessage: "rework session cookies"))
        let tile = RepoTileState(repo: repo(name: "widgets", git: git, agents: [worker]))
        XCTAssertTrue(tile.matches(SearchQuery("widgets")))
        XCTAssertTrue(tile.matches(SearchQuery("fix-login")))
        XCTAssertTrue(tile.matches(SearchQuery("Login.swift")))
        XCTAssertTrue(tile.matches(SearchQuery("cookies")))
        XCTAssertFalse(tile.matches(SearchQuery("gadgets")))
    }

    func testPRTileMatchesTitleAuthorAndReference() {
        let tile = PRTileState(pr: pr(title: "Add dark mode", number: 42), repoName: "widgets")
        XCTAssertTrue(tile.matches(SearchQuery("dark mode")))
        XCTAssertTrue(tile.matches(SearchQuery("casey")))
        XCTAssertTrue(tile.matches(SearchQuery("#42")))
        XCTAssertFalse(tile.matches(SearchQuery("light")))
    }

    // MARK: - Snapshot filtering

    func testAgentTilesMatchingFilters() {
        var snap = Snapshot.empty
        snap.repos = [
            repo(name: "a", agents: [agent(name: "deploy-bot")]),
            repo(name: "b", agents: [agent(name: "review-bot")]),
        ]
        XCTAssertEqual(snap.agentTiles(matching: SearchQuery("deploy")).map(\.title), ["deploy-bot"])
        XCTAssertEqual(snap.agentTiles(matching: SearchQuery("")).count, 2)
    }

    func testRankedSectionMatchingShowsAllMatchesUntruncated() {
        var snap = Snapshot.empty
        snap.repos = (1...15).map { repo(name: "match-\($0)") }
        let section = snap.rankedSection(matching: SearchQuery("match"))
        XCTAssertEqual(section.totalCount, 15)
        XCTAssertEqual(section.visible.count, 15, "search shows every hit, no recent-N cut")
        XCTAssertEqual(snap.rankedSection(matching: SearchQuery("nope")).totalCount, 0)
    }

    func testRankedSectionMatchingIncludesQuietUnreachableRepos() {
        var snap = Snapshot.empty
        snap.repos = [repo(name: "offline", git: GitState(branch: "main", fetchError: "auth"))]
        // Sanity: the default feed lumps it away…
        XCTAssertTrue(snap.rankedTiles().isEmpty)
        // …but a search that names it finds it.
        let section = snap.rankedSection(matching: SearchQuery("offline"))
        XCTAssertEqual(section.totalCount, 1)
    }
}
