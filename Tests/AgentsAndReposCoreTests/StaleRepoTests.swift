import XCTest

@testable import AgentsAndReposCore

final class StaleRepoTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private var old: Date { now.addingTimeInterval(-45 * 86_400) }
    private var recent: Date { now.addingTimeInterval(-5 * 86_400) }

    private func repo(
        name: String = "repo", activity: Date?,
        agents: [AgentSession] = [], prs: [PullRequest] = [],
        worktrees: [WorktreeOverview] = []
    ) -> RepoOverview {
        RepoOverview(
            repo: Repo(path: "/p/\(name)", name: name, root: "/p"),
            git: GitState(branch: "main", lastActivity: activity),
            agents: agents, prs: prs, worktrees: worktrees, githubRepo: nil)
    }

    private func snap(_ repos: [RepoOverview], staleDays: Int = 30) -> Snapshot {
        var config = AppConfig()
        config.autoHideStaleDays = staleDays
        return Snapshot(
            repos: repos, otherAgents: [], ghAvailability: .ok,
            lastFetchAt: nil, config: config, generatedAt: now)
    }

    func testOldRepoHiddenRecentShown() {
        let s = snap([repo(name: "old", activity: old), repo(name: "new", activity: recent)])
        XCTAssertEqual(s.visibleRepos.map(\.repo.name), ["new"])
        XCTAssertEqual(s.staleRepoCount, 1)
    }

    func testUnknownActivityStaysVisible() {
        let s = snap([repo(name: "mystery", activity: nil)])
        XCTAssertEqual(s.visibleRepos.count, 1)
        XCTAssertEqual(s.staleRepoCount, 0)
    }

    func testLiveAgentKeepsStaleRepoVisible() {
        let a = AgentSession(
            pid: 1, sessionId: "s1", cwd: "/p/old", name: "agent", kind: "interactive",
            status: .busy, startedAt: nil, updatedAt: nil)
        let s = snap([repo(name: "old", activity: old, agents: [a])])
        XCTAssertEqual(s.visibleRepos.count, 1)
    }

    func testOpenPRKeepsStaleRepoVisible() {
        let pr = PullRequest(
            number: 1, title: "t", url: "u", isDraft: false, author: "a",
            headRefName: "b", reviewDecision: nil, ci: .none)
        let s = snap([repo(name: "old", activity: old, prs: [pr])])
        XCTAssertEqual(s.visibleRepos.count, 1)
    }

    func testRecentWorktreeActivityKeepsRepoVisible() {
        let wt = WorktreeOverview(
            worktree: Worktree(path: "/p/old-wt", branch: "f", detached: false, isClaudeManaged: false),
            git: GitState(branch: "f", lastActivity: recent), agents: [])
        let s = snap([repo(name: "old", activity: old, worktrees: [wt])])
        XCTAssertEqual(s.visibleRepos.count, 1)
    }

    func testZeroDaysDisables() {
        let s = snap([repo(name: "old", activity: old)], staleDays: 0)
        XCTAssertEqual(s.visibleRepos.count, 1)
        XCTAssertEqual(s.staleRepoCount, 0)
    }

    func testIgnoredWinsOverStale() {
        var s = snap([repo(name: "old", activity: old)])
        s.config.ignoredRepos = ["/p/old"]
        XCTAssertEqual(s.staleRepoCount, 0)
        XCTAssertEqual(s.ignoredRepoTiles.map(\.name), ["old"])
        XCTAssertTrue(s.visibleRepos.isEmpty)
    }

    func testStaleReposListedAndExemptionUnhides() {
        var s = snap([repo(name: "old", activity: old)])
        XCTAssertEqual(s.staleRepoTiles.map(\.name), ["old"])
        XCTAssertTrue(s.visibleRepos.isEmpty)

        s.config.staleExemptRepos = ["/p/old"]
        XCTAssertTrue(s.staleRepoTiles.isEmpty)
        XCTAssertEqual(s.visibleRepos.map(\.repo.name), ["old"])
    }

    func testRepoTilesSortByRecencyThenName() {
        let s = snap([
            repo(name: "aaa-older", activity: now.addingTimeInterval(-5 * 86_400)),
            repo(name: "zzz-newest", activity: now.addingTimeInterval(-86_400)),
            repo(name: "mmm-unknown", activity: nil),
        ])
        XCTAssertEqual(
            s.repoTiles.map(\.name), ["zzz-newest", "aaa-older", "mmm-unknown"])
    }

    func testDirectlyAddedRootRepoNeverStale() {
        let direct = RepoOverview(
            repo: Repo(path: "/p/old", name: "old", root: "/p/old", isRoot: true),
            git: GitState(branch: "main", lastActivity: old),
            agents: [], prs: [], worktrees: [], githubRepo: nil)
        let s = snap([direct])
        XCTAssertEqual(s.visibleRepos.count, 1)
        XCTAssertEqual(s.staleRepoCount, 0)
    }

    func testHiddenEntriesMergeIgnoredAndStaleAlphabetically() {
        var s = snap([
            repo(name: "zulu-stale", activity: old),
            repo(name: "alpha-stale", activity: old),
            repo(name: "mike-ignored", activity: recent),
        ])
        s.config.ignoredRepos = ["/p/mike-ignored"]
        let entries = s.hiddenRepoEntries
        XCTAssertEqual(entries.map(\.tile.name), ["alpha-stale", "mike-ignored", "zulu-stale"])
        XCTAssertEqual(entries.map(\.reason), [.stale, .ignored, .stale])
    }

    func testExactBoundaryNotStale() {
        let s = snap([repo(name: "edge", activity: now.addingTimeInterval(-30 * 86_400))])
        XCTAssertEqual(s.visibleRepos.count, 1)
    }

    func testActivityPicksNewestOfCommitAndFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("activitytest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.txt")
        try Data("x".utf8).write(to: file)
        let mtime = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)

        let commit = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            RepoActivity.lastActivity(repoPath: dir.path, commitDate: commit, changedPaths: ["f.txt"]),
            mtime)
        XCTAssertEqual(
            RepoActivity.lastActivity(repoPath: dir.path, commitDate: nil, changedPaths: ["f.txt"]),
            mtime)
        XCTAssertEqual(
            RepoActivity.lastActivity(repoPath: dir.path, commitDate: commit, changedPaths: ["gone.txt"]),
            commit)
        XCTAssertNil(RepoActivity.lastActivity(repoPath: dir.path, commitDate: nil, changedPaths: []))
    }
}
