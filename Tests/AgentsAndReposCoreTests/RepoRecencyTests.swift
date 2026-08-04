import XCTest

@testable import AgentsAndReposCore

final class RepoRecencyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    private func repo(
        name: String = "repo", activity: Date?,
        prs: [PullRequest] = [], worktrees: [WorktreeOverview] = []
    ) -> RepoOverview {
        RepoOverview(
            repo: Repo(path: "/p/\(name)", name: name, root: "/p"),
            git: GitState(branch: "main", lastActivity: activity),
            agents: [], prs: prs, worktrees: worktrees, githubRepo: nil)
    }

    private func snap(_ repos: [RepoOverview]) -> Snapshot {
        Snapshot(
            repos: repos, otherAgents: [], ghAvailability: .ok,
            lastFetchAt: nil, config: AppConfig(), generatedAt: now)
    }

    /// n repos named r1…rn, r1 the most recently active.
    private func repos(_ n: Int) -> [RepoOverview] {
        (1...n).map { i in
            repo(name: "r\(i)", activity: now.addingTimeInterval(-Double(i) * 3_600))
        }
    }

    // MARK: - Ordering

    func testRepoTilesSortByRecencyThenName() {
        let s = snap([
            repo(name: "aaa-older", activity: now.addingTimeInterval(-5 * 86_400)),
            repo(name: "zzz-newest", activity: now.addingTimeInterval(-86_400)),
            repo(name: "mmm-unknown", activity: nil),
        ])
        XCTAssertEqual(
            s.repoTiles.map(\.name), ["zzz-newest", "aaa-older", "mmm-unknown"])
    }

    // MARK: - Recent-N sections

    func testRepoSectionTruncatesToSixMostRecent() {
        let s = snap(repos(8))
        let section = s.repoSection
        XCTAssertEqual(section.visible.map(\.name), ["r1", "r2", "r3", "r4", "r5", "r6"])
        XCTAssertEqual(section.totalCount, 8)
        XCTAssertEqual(section.overflowCount, 2)
        XCTAssertFalse(section.isExpanded)
        XCTAssertTrue(section.canToggle)
    }

    func testExpandedRepoSectionShowsAll() {
        var s = snap(repos(8))
        s.config.expandedSections = ["repos"]
        let section = s.repoSection
        XCTAssertEqual(section.visible.count, 8)
        XCTAssertEqual(section.overflowCount, 0)
        XCTAssertTrue(section.isExpanded)
        XCTAssertTrue(section.canToggle)
    }

    func testSectionWithinLimitCannotToggle() {
        let section = snap(repos(6)).repoSection
        XCTAssertEqual(section.visible.count, 6)
        XCTAssertEqual(section.overflowCount, 0)
        XCTAssertFalse(section.canToggle)
    }

    func testExpandingOneSectionDoesNotAffectOthers() {
        var s = snap(repos(8))
        s.config.expandedSections = ["prs"]
        XCTAssertEqual(s.repoSection.visible.count, 6)
        XCTAssertFalse(s.repoSection.isExpanded)
        XCTAssertFalse(s.worktreeSection.isExpanded)
        XCTAssertTrue(s.prSection.isExpanded)
    }

    func testPRSectionTruncatesToSixMostRecentlyUpdated() {
        let prs = (1...8).map { i in
            PullRequest(
                number: i, title: "t", url: "u\(i)", isDraft: false, author: "a",
                headRefName: "b", reviewDecision: nil, ci: .pass,
                updatedAt: now.addingTimeInterval(-Double(i) * 3_600))
        }
        var s = snap([repo(name: "r", activity: now, prs: prs)])
        let section = s.prSection
        XCTAssertEqual(section.visible.map(\.number), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(section.overflowCount, 2)
        XCTAssertTrue(section.canToggle)

        s.config.expandedSections = ["prs"]
        XCTAssertEqual(s.prSection.visible.count, 8)
    }

    func testWorktreeSectionTruncatesToSixMostRecent() {
        let worktrees = (1...8).map { i in
            WorktreeOverview(
                worktree: Worktree(
                    path: "/wt/w\(i)", branch: "b\(i)", detached: false, isClaudeManaged: false),
                git: GitState(
                    branch: "b\(i)", lastActivity: now.addingTimeInterval(-Double(i) * 3_600)),
                agents: [])
        }
        var s = snap([repo(name: "r", activity: now, worktrees: worktrees)])
        let section = s.worktreeSection
        XCTAssertEqual(section.visible.map(\.path), (1...6).map { "/wt/w\($0)" })
        XCTAssertEqual(section.overflowCount, 2)
        XCTAssertTrue(section.canToggle)

        s.config.expandedSections = ["worktrees"]
        XCTAssertEqual(s.worktreeSection.visible.count, 8)
    }

    // MARK: - Activity source

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
