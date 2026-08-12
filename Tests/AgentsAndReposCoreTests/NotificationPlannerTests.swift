import XCTest

@testable import AgentsAndReposCore

final class NotificationPlannerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func run(
        id: Int, state: WorkflowRun.State, updatedAt: Date? = nil, name: String = "CI"
    ) -> WorkflowRun {
        WorkflowRun(
            id: id, workflowName: name, title: "commit subject", branch: "main",
            event: "push", state: state, url: "https://github.com/o/r/actions/runs/\(id)",
            updatedAt: updatedAt)
    }

    private func repoOverview(
        path: String = "/p/app", runs: [WorkflowRun] = [], agents: [AgentSession] = []
    ) -> RepoOverview {
        RepoOverview(
            repo: Repo(path: path, name: (path as NSString).lastPathComponent, root: "/p"),
            git: nil, agents: agents, prs: [], worktrees: [], githubRepo: "o/r", runs: runs)
    }

    private func snapshot(
        repos: [RepoOverview] = [], otherAgents: [AgentSession] = [],
        config: AppConfig = {
            var c = AppConfig()
            c.notificationsEnabled = true
            return c
        }()
    ) -> Snapshot {
        Snapshot(
            repos: repos, otherAgents: otherAgents, ghAvailability: .ok,
            lastFetchAt: nil, config: config, generatedAt: t0)
    }

    private func waitingAgent(
        id: String = "s1", updatedAt: Date?, what: String? = "permission"
    ) -> AgentSession {
        AgentSession(
            pid: 100, sessionId: id, cwd: "/p/app", name: "fixer", kind: "interactive",
            status: .waiting(what), startedAt: nil, updatedAt: updatedAt)
    }

    // MARK: - Workflow runs

    func testFirstIngestIsBaselineOnly() {
        var p = NotificationPlanner()
        let snap = snapshot(repos: [
            repoOverview(runs: [run(id: 1, state: .failed, updatedAt: t0)])
        ])
        XCTAssertEqual(p.ingest(snap, now: t0), [])
        // Same completed run again: still nothing.
        XCTAssertEqual(p.ingest(snap, now: t0.addingTimeInterval(30)), [])
    }

    func testRunningToCompletedNotifiesOnce() {
        var p = NotificationPlanner()
        _ = p.ingest(
            snapshot(repos: [repoOverview(runs: [run(id: 1, state: .running)])]), now: t0)
        let done = snapshot(repos: [
            repoOverview(runs: [run(id: 1, state: .passed, updatedAt: t0)])
        ])
        let notes = p.ingest(done, now: t0.addingTimeInterval(60))
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].kind, .actionPassed)
        XCTAssertTrue(notes[0].title.contains("passed"))
        XCTAssertTrue(notes[0].body.contains("app"))
        XCTAssertEqual(notes[0].target, .url("https://github.com/o/r/actions/runs/1"))
        // Re-ingesting the completed run stays quiet.
        XCTAssertEqual(p.ingest(done, now: t0.addingTimeInterval(120)), [])
    }

    func testRunningToFailedNotifiesAsFailure() {
        var p = NotificationPlanner()
        _ = p.ingest(
            snapshot(repos: [repoOverview(runs: [run(id: 1, state: .running)])]), now: t0)
        let notes = p.ingest(
            snapshot(repos: [repoOverview(runs: [run(id: 1, state: .failed, updatedAt: t0)])]),
            now: t0.addingTimeInterval(60))
        XCTAssertEqual(notes.map(\.kind), [.actionFailed])
    }

    func testUnseenRunThatFinishedRecentlyNotifies() {
        var p = NotificationPlanner()
        _ = p.ingest(snapshot(repos: [repoOverview()]), now: t0)
        // A short run started and finished between sweeps.
        let notes = p.ingest(
            snapshot(repos: [
                repoOverview(runs: [
                    run(id: 2, state: .passed, updatedAt: t0.addingTimeInterval(240))
                ])
            ]),
            now: t0.addingTimeInterval(300))
        XCTAssertEqual(notes.count, 1)
    }

    func testUnseenOldCompletedRunIsHistory() {
        var p = NotificationPlanner()
        _ = p.ingest(snapshot(repos: [repoOverview()]), now: t0)
        let notes = p.ingest(
            snapshot(repos: [
                repoOverview(runs: [
                    run(id: 2, state: .failed, updatedAt: t0.addingTimeInterval(-7200))
                ])
            ]),
            now: t0.addingTimeInterval(300))
        XCTAssertEqual(notes, [])
    }

    func testGitActionsToggleSuppressesButKeepsTracking() {
        var off = {
            var c = AppConfig()
            c.notificationsEnabled = true
            c.notifyGitActions = false
            return c
        }()
        var p = NotificationPlanner()
        _ = p.ingest(
            snapshot(repos: [repoOverview(runs: [run(id: 1, state: .running)])], config: off),
            now: t0)
        // Completes while the toggle is off: no note.
        XCTAssertEqual(
            p.ingest(
                snapshot(
                    repos: [repoOverview(runs: [run(id: 1, state: .passed, updatedAt: t0)])],
                    config: off),
                now: t0.addingTimeInterval(60)),
            [])
        // Toggle back on: the already-completed run must not replay.
        off.notifyGitActions = true
        XCTAssertEqual(
            p.ingest(
                snapshot(
                    repos: [repoOverview(runs: [run(id: 1, state: .passed, updatedAt: t0)])],
                    config: off),
                now: t0.addingTimeInterval(120)),
            [])
    }

    func testIgnoredRepoRunsAreSkipped() {
        var config = AppConfig()
        config.notificationsEnabled = true
        config.ignoredRepos = ["/p/app"]
        var p = NotificationPlanner()
        _ = p.ingest(
            snapshot(repos: [repoOverview(runs: [run(id: 1, state: .running)])], config: config),
            now: t0)
        let notes = p.ingest(
            snapshot(
                repos: [repoOverview(runs: [run(id: 1, state: .passed, updatedAt: t0)])],
                config: config),
            now: t0.addingTimeInterval(60))
        XCTAssertEqual(notes, [])
    }

    // MARK: - Waiting agents

    func testWaitingUnderThresholdStaysQuiet() {
        var p = NotificationPlanner()
        let snap = snapshot(repos: [
            repoOverview(agents: [waitingAgent(updatedAt: t0)])
        ])
        XCTAssertEqual(p.ingest(snap, now: t0.addingTimeInterval(60)), [])
    }

    func testWaitingPastThresholdNotifiesOnce() {
        var p = NotificationPlanner()
        let snap = snapshot(repos: [
            repoOverview(agents: [waitingAgent(updatedAt: t0)])
        ])
        _ = p.ingest(snap, now: t0.addingTimeInterval(60))
        let notes = p.ingest(snap, now: t0.addingTimeInterval(301))
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].kind, .agentWaiting)
        XCTAssertTrue(notes[0].title.contains("fixer"))
        XCTAssertTrue(notes[0].body.contains("permission"))
        XCTAssertEqual(notes[0].target, .agent(pid: 100, cwd: "/p/app"))
        // Still waiting: no repeat.
        XCTAssertEqual(p.ingest(snap, now: t0.addingTimeInterval(600)), [])
    }

    func testAlreadyLongWaitingAtLaunchNotifiesImmediately() {
        var p = NotificationPlanner()
        // updatedAt says it entered waiting 20 minutes before our first look.
        let snap = snapshot(repos: [
            repoOverview(agents: [waitingAgent(updatedAt: t0.addingTimeInterval(-1200))])
        ])
        XCTAssertEqual(p.ingest(snap, now: t0).count, 1)
    }

    func testLeavingWaitingResetsTheCycle() {
        var p = NotificationPlanner()
        let waiting = snapshot(repos: [repoOverview(agents: [waitingAgent(updatedAt: t0)])])
        _ = p.ingest(waiting, now: t0)
        XCTAssertEqual(p.ingest(waiting, now: t0.addingTimeInterval(301)).count, 1)

        // Approved: session goes busy.
        let busy = snapshot(repos: [
            repoOverview(agents: [
                AgentSession(
                    pid: 100, sessionId: "s1", cwd: "/p/app", name: "fixer",
                    kind: "interactive", status: .busy, startedAt: nil,
                    updatedAt: t0.addingTimeInterval(400))
            ])
        ])
        _ = p.ingest(busy, now: t0.addingTimeInterval(400))

        // Waits again: fresh threshold, fresh notification.
        let rewaiting = snapshot(repos: [
            repoOverview(agents: [waitingAgent(updatedAt: t0.addingTimeInterval(500))])
        ])
        XCTAssertEqual(p.ingest(rewaiting, now: t0.addingTimeInterval(550)), [])
        XCTAssertEqual(p.ingest(rewaiting, now: t0.addingTimeInterval(801)).count, 1)
    }

    func testIgnoredAgentsAreSkipped() {
        var config = AppConfig()
        config.notificationsEnabled = true
        config.ignoredAgents = ["s1"]
        var p = NotificationPlanner()
        let snap = snapshot(
            repos: [repoOverview(agents: [waitingAgent(updatedAt: t0.addingTimeInterval(-1200))])],
            config: config)
        XCTAssertEqual(p.ingest(snap, now: t0), [])
    }

    func testWaitingToggleSuppresses() {
        var config = AppConfig()
        config.notificationsEnabled = true
        config.notifyWaitingAgents = false
        var p = NotificationPlanner()
        let snap = snapshot(
            repos: [repoOverview(agents: [waitingAgent(updatedAt: t0.addingTimeInterval(-1200))])],
            config: config)
        XCTAssertEqual(p.ingest(snap, now: t0), [])
    }

    func testOtherAgentsAreCoveredToo() {
        var p = NotificationPlanner()
        let snap = snapshot(otherAgents: [waitingAgent(updatedAt: t0.addingTimeInterval(-1200))])
        XCTAssertEqual(p.ingest(snap, now: t0).count, 1)
    }

    func testResetReprimes() {
        var p = NotificationPlanner()
        _ = p.ingest(
            snapshot(repos: [repoOverview(runs: [run(id: 1, state: .running)])]), now: t0)
        p.reset()
        // After reset, the completed run is baseline, not a transition.
        let notes = p.ingest(
            snapshot(repos: [repoOverview(runs: [run(id: 1, state: .passed, updatedAt: t0)])]),
            now: t0.addingTimeInterval(60))
        XCTAssertEqual(notes, [])
    }
}
