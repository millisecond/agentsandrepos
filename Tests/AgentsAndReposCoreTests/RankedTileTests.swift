import XCTest

@testable import AgentsAndReposCore

final class RankedTileTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func repo(
        name: String, git: GitState? = GitState(branch: "main"),
        prs: [PullRequest] = [], activityAgo: TimeInterval? = nil
    ) -> RepoOverview {
        var g = git
        if let ago = activityAgo { g?.lastActivity = now.addingTimeInterval(-ago) }
        return RepoOverview(
            repo: Repo(path: "/p/\(name)", name: name, root: "/p"),
            git: g, agents: [], prs: prs, worktrees: [], githubRepo: nil)
    }

    private func pr(
        _ ci: PullRequest.CIStatus, number: Int, updatedAgo: TimeInterval
    ) -> PullRequest {
        PullRequest(
            number: number, title: "t", url: "https://x/pull/\(number)", isDraft: false,
            author: "a", headRefName: "b", reviewDecision: nil, ci: ci,
            updatedAt: now.addingTimeInterval(-updatedAgo))
    }

    func testSeverityBasesAreOrdered() {
        let ordered: [TileSeverity] = [.muted, .ok, .info, .attention, .urgent]
        let bases = ordered.map { AttentionScore.base($0) }
        XCTAssertEqual(bases, bases.sorted())
        XCTAssertEqual(Set(bases).count, bases.count)
    }

    func testRecencyBucketsDecay() {
        let ages: [TimeInterval] = [60, 1800, 7200, 43200, 200_000, 1_000_000]
        let scores = ages.map {
            AttentionScore.recency(now.addingTimeInterval(-$0), now: now)
        }
        XCTAssertEqual(scores, scores.sorted(by: >))
        XCTAssertEqual(AttentionScore.recency(nil, now: now), 0)
        XCTAssertEqual(scores.last, 0)
    }

    func testUrgentStaleOutranksOkRecent() {
        // A CI-failing repo untouched for a day still beats a clean repo
        // touched a minute ago: max recency (50) can't bridge urgent (100).
        var snap = Snapshot.empty
        snap.repos = [
            repo(name: "fresh-clean", activityAgo: 60),
            repo(
                name: "broken", git: GitState(branch: "m", statusError: "boom"),
                activityAgo: 100_000),
        ]
        XCTAssertEqual(
            snap.rankedTiles(now: now).map(\.sortName), ["broken", "fresh-clean"])
    }

    func testRecentActivityLiftsCleanRepoOverStaleDirtyOne() {
        // attention + week-stale (60+4=64) loses to ok + just-touched (10+50=60)?
        // No — 64 > 60: dirty still wins. But ancient (>1w, 60+0) ties recent
        // clean (60) and the recency tiebreak puts the fresh repo first.
        var snap = Snapshot.empty
        snap.repos = [
            repo(name: "ancient-dirty", git: GitState(branch: "m", dirty: 1)),
            repo(name: "fresh-clean", activityAgo: 60),
        ]
        XCTAssertEqual(
            snap.rankedTiles(now: now).map(\.sortName),
            ["fresh-clean", "ancient-dirty"])
    }

    func testPRsInterleaveWithRepos() {
        // Failing PR (urgent 100 + recent 50) > its host repo (urgent via
        // worstCI, no activity date) > dirty repo (info 30 + recent 50) >
        // passing PR (ok 10 + 35).
        var snap = Snapshot.empty
        snap.repos = [
            repo(
                name: "dirty", git: GitState(branch: "m", dirty: 2), activityAgo: 60),
            repo(
                name: "host",
                prs: [pr(.fail, number: 1, updatedAgo: 60), pr(.pass, number: 2, updatedAgo: 1800)]),
        ]
        let names = snap.rankedTiles(now: now).map(\.sortName)
        XCTAssertEqual(names, ["host #1", "host", "dirty", "host #2"])
    }

    func testQuietUnreachableReposLumpOutOfRankedList() {
        var snap = Snapshot.empty
        snap.repos = [
            repo(name: "work-ok", activityAgo: 60),
            repo(name: "cant-auth-1", git: GitState(branch: "m", fetchError: "auth")),
            repo(name: "cant-auth-2", git: GitState(branch: "m", fetchError: "auth")),
            repo(
                name: "cant-auth-dirty",
                git: GitState(branch: "m", dirty: 3, fetchError: "auth"), activityAgo: 60),
        ]
        let ranked = snap.rankedTiles(now: now).map(\.sortName)
        // Quiet unreachable repos leave the list; the dirty one stays on its
        // local merits.
        XCTAssertEqual(Set(ranked), ["work-ok", "cant-auth-dirty"])
        XCTAssertEqual(
            Set(snap.unreachableTiles.map(\.name)), ["cant-auth-1", "cant-auth-2"])
    }

    func testRankedIdsAreNamespaced() {
        var snap = Snapshot.empty
        snap.repos = [repo(name: "r", prs: [pr(.pass, number: 1, updatedAgo: 60)])]
        let ids = snap.rankedTiles(now: now).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.contains { $0.hasPrefix("repo:") })
        XCTAssertTrue(ids.contains { $0.hasPrefix("pr:") })
    }
}
