import Foundation

/// One alert the app should post to macOS Notification Center.
public struct PlannedNotification: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case actionPassed
        case actionFailed
        case agentWaiting
    }

    /// Where a click on the notification should land — mirroring what a click
    /// on the corresponding dashboard tile does. Only the bundled app can
    /// honor it (the osascript dev fallback has no click hook).
    public enum ClickTarget: Equatable, Sendable {
        /// Open in the browser (a run's GitHub page).
        case url(String)
        /// Focus the terminal window hosting the agent; reveal cwd in Finder
        /// when no host window is found.
        case agent(pid: Int32, cwd: String)
    }

    /// Stable dedupe key ("run-…", "wait-…") — doubles as the
    /// UNNotificationRequest identifier.
    public let id: String
    public let kind: Kind
    public let title: String
    /// The "since last time" clause — why this one is worth a line.
    public let subtitle: String?
    public let body: String
    public let target: ClickTarget?
    /// With the app's Alert style (persist until dismissed), how long an
    /// unacted-on alert stays up before the app withdraws it. Nil = forever.
    public let expiresAfter: TimeInterval?
    /// How surprising the event was; drives sound and expiry.
    public let tier: SurpriseTier
    public let playsSound: Bool

    public init(
        id: String, kind: Kind, title: String, subtitle: String? = nil, body: String,
        target: ClickTarget? = nil, expiresAfter: TimeInterval? = nil,
        tier: SurpriseTier = .extreme, playsSound: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.target = target
        self.expiresAfter = expiresAfter
        self.tier = tier
        self.playsSound = playsSound
    }
}

/// One finished run's score, surfaced so the coordinator can log it for
/// calibration — the cutoffs are guesses until real scores exist.
public struct RunScore: Equatable, Sendable {
    public let key: String
    public let surprise: RunSurprise

    public init(key: String, surprise: RunSurprise) {
        self.key = key
        self.surprise = surprise
    }
}

/// What one snapshot ingest asks the deliverer to do: post new alerts and
/// take down ones whose cause has resolved.
public struct NotificationPlan: Equatable, Sendable {
    public var post: [PlannedNotification] = []
    /// Notification ids to withdraw (removes the on-screen alert and the
    /// Notification Center entry).
    public var withdraw: [String] = []
    /// Every finished run scored this ingest, posted or not.
    public var scored: [RunScore] = []

    public var isEmpty: Bool { post.isEmpty && withdraw.isEmpty }

    public init(
        post: [PlannedNotification] = [], withdraw: [String] = [], scored: [RunScore] = []
    ) {
        self.post = post
        self.withdraw = withdraw
        self.scored = scored
    }
}

/// Decides which notifications each new snapshot warrants, by diffing against
/// the last one. Pure in-memory state — no I/O, cheap enough to run on every
/// publish (the 3s agent tick is the hot caller).
///
/// Two triggers:
///   - a repo-level GitHub Actions run finishing (running → passed/failed,
///     or a fresh run that appeared already-finished between sweeps)
///   - an agent stuck in `waiting` (permission request, question) past
///     `waitingThreshold`
///
/// The first ingest only records a baseline for runs — a launch with a page
/// of recently-completed runs must not flood the user. Waiting agents are
/// exempt from priming: something already pending at launch is exactly what
/// the user wants to hear about.
///
/// Finished runs are then scored against a per-workflow belief
/// (`RunSurpriseScorer`) so a workflow that passes every push stops shouting:
///   - extreme: the full alert (sound for failures) with a "since last time"
///     subtitle — flips, first sightings, big duration/lull jumps
///   - unusual: a quiet, short-lived notification saying what moved
///   - normal: swallowed; every `roundupEvery`-th swallowed result gets one
///     quiet "still green / still failing" line so nothing vanishes forever
/// Waiting agents need a human decision, so they always keep their own line.
public struct NotificationPlanner: Sendable {
    /// How long an unacted-on CI-result alert stays on screen.
    public static let runAlertDuration: TimeInterval = 300
    /// How long an unacted-on waiting-agent alert stays on screen. Short —
    /// while the agent still waits, resolution withdrawal hasn't fired, and
    /// the dashboard tile keeps showing it.
    public static let waitingAlertDuration: TimeInterval = 60
    /// How long an unusual-tier or roundup run notification stays up.
    public static let quietRunAlertDuration: TimeInterval = 90
    /// Manners rule: a workflow whose results have been swallowed this many
    /// times in a row gets one quiet line through.
    public static let roundupEvery = 3

    public var waitingThreshold: TimeInterval
    /// A run first seen already-finished still notifies if it completed this
    /// recently — covers short runs that start and finish between the 5-min
    /// sweeps. Older ones are treated as history.
    public var recentCompletionWindow: TimeInterval

    private var primed = false
    private var runStates: [String: WorkflowRun.State] = [:]
    /// Run keys with a live notification, so a re-run (failed → running on
    /// the same run id) withdraws the stale result alert.
    private var notifiedRuns: Set<String> = []
    private var waitingSince: [String: Date] = [:]
    private var notifiedWaiting: Set<String> = []
    /// Per-workflow beliefs, keyed by `beliefKey`. Survive `reset()` and,
    /// via `BeliefStore`, relaunches.
    public private(set) var beliefs: [String: RunBelief]
    private var beliefsDirty = false

    public init(
        waitingThreshold: TimeInterval = 300, recentCompletionWindow: TimeInterval = 600,
        beliefs: [String: RunBelief] = [:]
    ) {
        self.waitingThreshold = waitingThreshold
        self.recentCompletionWindow = recentCompletionWindow
        self.beliefs = beliefs
    }

    /// Drop all transition-tracking state (used when notifications are
    /// toggled off, so a later re-enable re-primes instead of replaying stale
    /// transitions). Beliefs are knowledge, not transitions — they stay.
    public mutating func reset() {
        self = NotificationPlanner(
            waitingThreshold: waitingThreshold,
            recentCompletionWindow: recentCompletionWindow,
            beliefs: beliefs)
    }

    /// Beliefs if any changed since the last call; the caller persists them.
    public mutating func takeDirtyBeliefs() -> [String: RunBelief]? {
        guard beliefsDirty else { return nil }
        beliefsDirty = false
        return beliefs
    }

    /// Beliefs follow the GitHub repo when known, so a moved clone keeps
    /// its history; the path otherwise.
    public static func beliefKey(repo: RepoOverview, workflow: String) -> String {
        "\(repo.githubRepo ?? repo.repo.path)#\(workflow)"
    }

    public mutating func ingest(_ snapshot: Snapshot, now: Date) -> NotificationPlan {
        var plan = ingestRuns(snapshot, now: now)
        let waiting = ingestWaiting(snapshot, now: now)
        plan.post += waiting.post
        plan.withdraw += waiting.withdraw
        primed = true
        return plan
    }

    // MARK: - Workflow runs

    private mutating func ingestRuns(_ snapshot: Snapshot, now: Date) -> NotificationPlan {
        var plan = NotificationPlan()
        var newStates: [String: WorkflowRun.State] = [:]
        let ignored = Set(snapshot.config.ignoredRepos)
        for repo in snapshot.repos where !ignored.contains(repo.repo.path) {
            for run in repo.runs {
                let key = "\(repo.repo.path)#\(run.id)"
                newStates[key] = run.state
                // A re-run reuses the run id: failed → running again means the
                // old result alert is stale — take it down.
                if run.state == .running, notifiedRuns.contains(key) {
                    notifiedRuns.remove(key)
                    plan.withdraw.append("run-\(key)")
                }
                guard primed, snapshot.config.notifyGitActions else { continue }
                guard run.state == .passed || run.state == .failed else { continue }
                let previous = runStates[key]
                let finishedWhileWatched = previous == .running
                let newAndFresh =
                    previous == nil
                    && run.updatedAt.map { now.timeIntervalSince($0) < recentCompletionWindow }
                        == true
                guard finishedWhileWatched || newAndFresh else { continue }
                if let note = scoreAndPlan(run: run, repo: repo, key: key, now: now, plan: &plan) {
                    notifiedRuns.insert(key)
                    plan.post.append(note)
                }
            }
        }
        runStates = newStates
        notifiedRuns.formIntersection(Set(newStates.keys))
        return plan
    }

    /// Scores the finished run against its belief, updates the belief, and
    /// returns the notification its tier warrants (nil when swallowed).
    private mutating func scoreAndPlan(
        run: WorkflowRun, repo: RepoOverview, key: String, now: Date,
        plan: inout NotificationPlan
    ) -> PlannedNotification? {
        let beliefKey = Self.beliefKey(repo: repo, workflow: run.workflowName)
        let finishedAt = run.updatedAt ?? now
        let prior = beliefs[beliefKey]
        let surprise = RunSurpriseScorer.score(run: run, finishedAt: finishedAt, belief: prior)
        var belief = RunSurpriseScorer.observe(run: run, finishedAt: finishedAt, into: prior)
        plan.scored.append(RunScore(key: beliefKey, surprise: surprise))
        defer {
            beliefs[beliefKey] = belief
            beliefsDirty = true
        }
        switch surprise.tier {
        case .extreme, .unusual:
            belief.suppressed = 0
            return notification(
                for: run, repo: repo, key: key, tier: surprise.tier, subtitle: surprise.clause)
        case .normal:
            belief.suppressed += 1
            guard belief.suppressed >= Self.roundupEvery else { return nil }
            belief.suppressed = 0
            let failed = run.state == .failed
            let subtitle =
                "\(failed ? "still failing" : "still green"), "
                + "\(RunSurpriseScorer.ordinal(belief.streak)) \(failed ? "failure" : "pass") in a row"
            return notification(for: run, repo: repo, key: key, tier: .normal, subtitle: subtitle)
        }
    }

    private func notification(
        for run: WorkflowRun, repo: RepoOverview, key: String, tier: SurpriseTier,
        subtitle: String?
    ) -> PlannedNotification {
        let passed = run.state == .passed
        return PlannedNotification(
            id: "run-\(key)",
            kind: passed ? .actionPassed : .actionFailed,
            title: "\(run.workflowName) \(passed ? "passed" : "failed")",
            subtitle: subtitle,
            body: "\(repo.repo.name) · \(run.branch) — \(run.title)",
            target: run.url.isEmpty ? nil : .url(run.url),
            expiresAfter: tier == .extreme ? Self.runAlertDuration : Self.quietRunAlertDuration,
            tier: tier,
            playsSound: !passed && tier == .extreme)
    }

    // MARK: - Waiting agents

    private mutating func ingestWaiting(_ snapshot: Snapshot, now: Date) -> NotificationPlan {
        var plan = NotificationPlan()
        let ignored = Set(snapshot.config.ignoredAgents)
        var stillWaiting: Set<String> = []
        for session in snapshot.allAgents where !ignored.contains(session.sessionId) {
            guard case .waiting(let what) = session.status else { continue }
            stillWaiting.insert(session.sessionId)
            // The session file rewrites on status change, so updatedAt is a
            // good proxy for when the wait began — it credits time already
            // spent waiting before we launched.
            let since = waitingSince[session.sessionId] ?? session.updatedAt ?? now
            waitingSince[session.sessionId] = since
            guard snapshot.config.notifyWaitingAgents else { continue }
            guard now.timeIntervalSince(since) >= waitingThreshold else { continue }
            guard !notifiedWaiting.contains(session.sessionId) else { continue }
            notifiedWaiting.insert(session.sessionId)
            let minutes = max(1, Int(now.timeIntervalSince(since) / 60))
            let place = (session.cwd as NSString).lastPathComponent
            let detail = (what?.isEmpty == false) ? what! : "waiting for your input"
            plan.post.append(
                PlannedNotification(
                    id: "wait-\(session.sessionId)",
                    kind: .agentWaiting,
                    title: "\(session.displayName) needs you",
                    body: "\(place) — \(detail) for \(minutes)m",
                    target: .agent(pid: session.pid, cwd: session.cwd),
                    expiresAfter: Self.waitingAlertDuration,
                    // Needs a human decision: always its own line, never scored.
                    tier: .extreme,
                    playsSound: true))
        }
        // Approved/answered (or the session ended): the alert's cause is gone,
        // so take the alert down with it.
        plan.withdraw += notifiedWaiting.subtracting(stillWaiting)
            .map { "wait-\($0)" }.sorted()
        // A session that stops waiting starts a fresh cycle if it waits again.
        waitingSince = waitingSince.filter { stillWaiting.contains($0.key) }
        notifiedWaiting.formIntersection(stillWaiting)
        return plan
    }
}
