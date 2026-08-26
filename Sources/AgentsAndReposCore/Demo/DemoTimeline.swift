import Foundation

/// Scripted fake data for `--demo` mode: the demo driver plays this sequence
/// of snapshots on a timer while `scripts/record-demo.sh` records the README
/// video. Pure and stateless — `snapshot(tick:now:)` depends only on its
/// arguments, so tests can pin every frame.
///
/// The 40-second loop tells one story: a search for the PR number filters the
/// board to that row → agents working → an agent waits on the human (menubar
/// flips to waiting) → the ⋯ row menu is showcased by the cursor choreography
/// → CI and a deploy break (menubar error) → everything resolves and the
/// workspace goes calm, landing near the opening frame so the GIF loops.
public enum DemoTimeline {
    public static let tickInterval: TimeInterval = 0.5
    public static let totalTicks = 80  // 40s loop

    // Scene boundaries, in ticks.
    public static let searchSceneStart = 2  // cursor types the PR number into search
    public static let attentionStart = 16  // an agent starts waiting on input
    public static let menuSceneStart = 28  // ⋯-menu cursor choreography window
    public static let menuSceneEnd = 52
    public static let breakageStart = 52  // CI + deploy failures land
    public static let resolutionStart = 66  // everything passes, agents idle

    /// The row the ⋯-menu choreography targets. Ranked first for the whole
    /// menu scene (asserted by DemoTimelineTests) so the cursor's target
    /// never moves mid-shot.
    public static let featuredRepoPath = "/Users/casey/Projects/checkout-service"

    /// What the search choreography types: matches PR #482's reference and
    /// URL and nothing else, so the board filters to exactly that row.
    public static let searchQuery = "482"

    public static func snapshot(tick rawTick: Int, now: Date) -> Snapshot {
        let tick = ((rawTick % totalTicks) + totalTicks) % totalTicks
        return Snapshot(
            repos: [
                checkoutService(tick: tick, now: now),
                webDashboard(tick: tick, now: now),
                mlPipeline(tick: tick, now: now),
                infra(now: now),
            ],
            otherAgents: [],
            ghAvailability: .ok,
            // The per-tick millisecond shift is invisible (relative "ago"
            // rendering) but keeps consecutive snapshots unequal even when
            // every agent has gone quiet — Snapshot.== dedupe would otherwise
            // drop publishes and freeze the recording (see SnapshotStore).
            lastFetchAt: now.addingTimeInterval(-75 + Double(tick) * 0.001),
            config: AppConfig(),
            generatedAt: now
        )
    }

    // MARK: - Repos

    private static func checkoutService(tick: Int, now: Date) -> RepoOverview {
        let resolved = tick >= resolutionStart
        let git = GitState(
            branch: "feat/apple-pay",
            ahead: resolved ? 0 : 2,
            dirty: resolved ? 0 : (tick >= attentionStart ? 5 : 2),
            untracked: resolved ? 0 : (tick >= attentionStart ? 2 : 0),
            changedPaths: resolved ? [] : ["Sources/Checkout/ApplePay.swift"],
            lastActivity: now.addingTimeInterval(-240),
            mergeState: resolved ? .mergedRemote : .unmerged
        )
        let status: AgentSession.Status =
            tick < attentionStart
            ? .busy
            : tick < breakageStart ? .waiting("permission to run tests") : .idle
        let agent = AgentSession(
            pid: 84121, sessionId: "demo-refactor-auth",
            cwd: featuredRepoPath, name: "apple-pay", kind: "fg",
            status: status,
            startedAt: now.addingTimeInterval(-2400),
            updatedAt: now.addingTimeInterval(-30),
            task: AgentTask(
                lastUserMessage: "add Apple Pay support to the checkout flow",
                lastAgentMessage:
                    "Token service refactored — ready to run the payment tests.",
                userSpokeLast: false),
            activity: tick < attentionStart
                ? busyLevels(tick: tick, salt: 1)
                : fadedLevels(lastBusyTick: attentionStart - 1, quietTicks: tick - attentionStart, salt: 1)
        )
        return RepoOverview(
            repo: Repo(path: featuredRepoPath, name: "checkout-service", root: "/Users/casey/Projects"),
            git: git, agents: [agent], prs: [], worktrees: [],
            githubRepo: "casey/checkout-service")
    }

    private static func webDashboard(tick: Int, now: Date) -> RepoOverview {
        let path = "/Users/casey/Projects/web-dashboard"
        let resolved = tick >= resolutionStart
        let git = GitState(
            branch: "main",
            dirty: resolved ? 0 : 1,
            changedPaths: resolved ? [] : ["ci/retry.ts"],
            lastActivity: now.addingTimeInterval(-180)
        )
        let ci: PullRequest.CIStatus =
            tick < breakageStart ? .pending : tick < resolutionStart ? .fail : .pass
        let pr = PullRequest(
            number: 482, title: "Retry flaky websocket connections in CI",
            url: "https://github.com/casey/web-dashboard/pull/482",
            isDraft: false, author: "casey", headRefName: "fix/flaky-ws",
            reviewDecision: nil, ci: ci,
            failingChecks: ci == .fail ? ["build (macos-14)"] : [],
            updatedAt: now.addingTimeInterval(-300))
        let agent = AgentSession(
            pid: 84355, sessionId: "demo-flaky-tests",
            cwd: path, name: "flaky-tests", kind: "fg",
            status: tick < breakageStart ? .busy : .idle,
            startedAt: now.addingTimeInterval(-5400),
            updatedAt: now.addingTimeInterval(-10),
            task: AgentTask(
                lastUserMessage: "fix the flaky websocket test in CI",
                lastAgentMessage: "Added exponential backoff to the test harness.",
                userSpokeLast: false),
            activity: tick < breakageStart
                ? busyLevels(tick: tick, salt: 2)
                : fadedLevels(lastBusyTick: breakageStart - 1, quietTicks: tick - breakageStart, salt: 2)
        )
        let worktree = WorktreeOverview(
            worktree: Worktree(
                path: "/Users/casey/Projects/web-dashboard-perf-pass",
                branch: "claude/perf-pass", detached: false, isClaudeManaged: true),
            git: GitState(
                branch: "claude/perf-pass",
                lastActivity: now.addingTimeInterval(-5400),
                mergeState: .mergedLocal),
            agents: [])
        return RepoOverview(
            repo: Repo(path: path, name: "web-dashboard", root: "/Users/casey/Projects"),
            git: git, agents: [agent], prs: [pr], worktrees: [worktree],
            githubRepo: "casey/web-dashboard")
    }

    private static func mlPipeline(tick: Int, now: Date) -> RepoOverview {
        let state: WorkflowRun.State =
            tick < breakageStart ? .running : tick < resolutionStart ? .failed : .passed
        let run = WorkflowRun(
            id: 9001, workflowName: "Deploy", title: "Ship v2.4.1", branch: "main",
            event: "push", state: state,
            url: "https://github.com/casey/ml-pipeline/actions/runs/9001",
            updatedAt: now.addingTimeInterval(-420))
        return RepoOverview(
            repo: Repo(
                path: "/Users/casey/Projects/ml-pipeline", name: "ml-pipeline",
                root: "/Users/casey/Projects"),
            git: GitState(branch: "main", lastActivity: now.addingTimeInterval(-1500)),
            agents: [], prs: [], worktrees: [],
            githubRepo: "casey/ml-pipeline", runs: [run])
    }

    private static func infra(now: Date) -> RepoOverview {
        RepoOverview(
            repo: Repo(
                path: "/Users/casey/Projects/infra", name: "infra",
                root: "/Users/casey/Projects"),
            git: GitState(branch: "main", lastActivity: now.addingTimeInterval(-9000)),
            agents: [], prs: [], worktrees: [],
            githubRepo: "casey/infra")
    }

    // MARK: - Activity LEDs

    /// A busy agent's LED strip, re-rolled every tick so the bars visibly
    /// churn. Values 3–15: lively, never a dead bar mid-burst.
    private static func busyLevels(tick: Int, salt: UInt64) -> [Int] {
        (0..<AgentActivityMeter.bucketCount).map { i in
            3 + Int(splitmix(UInt64(tick) &* 31 &+ salt &* 1009 &+ UInt64(i)) % 13)
        }
    }

    /// A quiet agent's strip: the last busy frame sliding out of the window
    /// one bucket per tick, matching how the real meter drains. Empty once
    /// the whole window has scrolled past.
    private static func fadedLevels(lastBusyTick: Int, quietTicks: Int, salt: UInt64) -> [Int] {
        let count = AgentActivityMeter.bucketCount
        guard quietTicks < count else { return [] }
        let base = busyLevels(tick: lastBusyTick, salt: salt)
        return Array(base.dropFirst(quietTicks)) + Array(repeating: 0, count: quietTicks)
    }

    /// SplitMix64 — deterministic, seedable, and allowed in every context
    /// (unlike SystemRandomNumberGenerator, which would break replay).
    private static func splitmix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
