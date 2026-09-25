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
        _ ci: PullRequest.CIStatus, number: Int, updatedAgo: TimeInterval,
        ciAgo: TimeInterval? = nil, isDraft: Bool = false
    ) -> PullRequest {
        PullRequest(
            number: number, title: "t", url: "https://x/pull/\(number)", isDraft: isDraft,
            author: "a", headRefName: "b", reviewDecision: nil, ci: ci,
            updatedAt: now.addingTimeInterval(-updatedAgo),
            ciUpdatedAt: ciAgo.map { now.addingTimeInterval(-$0) })
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
        // Failing PR (urgent 100 + recent 50) > passing PR (ok 10 + 50 +
        // green 40) > dirty repo (info 30 + recent 50) > host repo (ok 10,
        // no activity) — the failing PR paints only its own row; the clean
        // host repo ranks on its local state.
        var snap = Snapshot.empty
        snap.repos = [
            repo(
                name: "dirty", git: GitState(branch: "m", dirty: 2), activityAgo: 60),
            repo(
                name: "host",
                prs: [pr(.fail, number: 1, updatedAgo: 60), pr(.pass, number: 2, updatedAgo: 1800)]),
        ]
        let names = snap.rankedTiles(now: now).map(\.sortName)
        XCTAssertEqual(names, ["host #1", "host #2", "dirty", "host"])
    }

    func testPRDecayIsSlowerThanRepoDecay() {
        let ages: [TimeInterval] = [60, 1800, 7200, 43200, 200_000, 1_000_000]
        let scores = ages.map {
            AttentionScore.prRecency(now.addingTimeInterval(-$0), now: now)
        }
        XCTAssertEqual(scores, scores.sorted(by: >))
        XCTAssertEqual(AttentionScore.prRecency(nil, now: now), 0)
        XCTAssertEqual(scores.last, 0)
        // At every age a PR keeps at least as much heat as a repo would.
        for age in ages {
            let date = now.addingTimeInterval(-age)
            XCTAssertGreaterThanOrEqual(
                AttentionScore.prRecency(date, now: now),
                AttentionScore.recency(date, now: now))
        }
    }

    func testOvernightPRsStillTopFreshlyTouchedDirtyRepos() {
        // The morning-after scenario this scoring exists for: PRs from last
        // evening (14h ago) must not sink under repos whose files got touched
        // a minute ago. Green: ok 10 + 35 + 40 = 85; running: info 30 + 35 +
        // 50 = 115; dirty-just-touched: info 30 + 50 = 80.
        var snap = Snapshot.empty
        snap.repos = [
            repo(name: "dirty-a", git: GitState(branch: "m", dirty: 2), activityAgo: 60),
            repo(name: "dirty-b", git: GitState(branch: "m", dirty: 9), activityAgo: 300),
            repo(
                name: "host",
                prs: [
                    pr(.pass, number: 3, updatedAgo: 50_400),
                    pr(.pending, number: 4, updatedAgo: 50_400),
                ]),
        ]
        let names = snap.rankedTiles(now: now).map(\.sortName)
        XCTAssertEqual(Array(names.prefix(2)), ["host #4", "host #3"])
    }

    func testRunningCIPROutranksFreshDirtyRepos() {
        // The thing the app is opened for: a PR whose checks are running
        // (info 30 + recent 50 + in-flight 40 = 120) beats every dirty repo
        // touched this minute (info 30 + 50 = 80), and its clean host repo.
        var snap = Snapshot.empty
        snap.repos = [
            repo(name: "dirty-a", git: GitState(branch: "m", dirty: 2), activityAgo: 60),
            repo(name: "dirty-b", git: GitState(branch: "m", dirty: 9), activityAgo: 120),
            repo(name: "host", prs: [pr(.pending, number: 7, updatedAgo: 600)]),
        ]
        XCTAssertEqual(snap.rankedTiles(now: now).map(\.sortName).first, "host #7")
    }

    func testFreshlyGreenPROutranksDirtyRepoDespiteStalePush() {
        // Pushed two hours ago, CI went green five minutes ago. GitHub's
        // updatedAt says 2h; ciUpdatedAt says 5m and wins: ok 10 + recent 50
        // + green 30 = 90 > dirty repo touched now (80). Without the CI
        // timestamp this PR scored 10 + 20 + 30 = 60 and sank.
        var snap = Snapshot.empty
        snap.repos = [
            repo(name: "dirty", git: GitState(branch: "m", dirty: 2), activityAgo: 60),
            repo(name: "host", prs: [pr(.pass, number: 8, updatedAgo: 7200, ciAgo: 300)]),
        ]
        XCTAssertEqual(
            snap.rankedTiles(now: now).map(\.sortName), ["host #8", "dirty", "host"])
    }

    func testDraftPRsGetNoCIBoost() {
        // A draft with checks running is still parked work: muted 0 + 50,
        // under a dirty repo touched an hour ago (30 + 35 = 65).
        var snap = Snapshot.empty
        snap.repos = [
            repo(name: "dirty", git: GitState(branch: "m", dirty: 1), activityAgo: 1800),
            repo(name: "host", prs: [pr(.pending, number: 9, updatedAgo: 60, isDraft: true)]),
        ]
        XCTAssertEqual(snap.rankedTiles(now: now).map(\.sortName).first, "dirty")
    }

    func testFailingPRStillTopsRunningOne() {
        // Boosts never reorder failures below in-flight work of the same age.
        var snap = Snapshot.empty
        snap.repos = [
            repo(name: "host", prs: [
                pr(.pending, number: 1, updatedAgo: 60),
                pr(.fail, number: 2, updatedAgo: 60),
            ])
        ]
        XCTAssertEqual(
            snap.rankedTiles(now: now).map(\.sortName).prefix(2), ["host #2", "host #1"])
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
