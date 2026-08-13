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
    public let body: String
    public let target: ClickTarget?
    /// With the app's Alert style (persist until dismissed), how long an
    /// unacted-on alert stays up before the app withdraws it. Nil = forever.
    public let expiresAfter: TimeInterval?

    public init(
        id: String, kind: Kind, title: String, body: String, target: ClickTarget? = nil,
        expiresAfter: TimeInterval? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.target = target
        self.expiresAfter = expiresAfter
    }
}

/// What one snapshot ingest asks the deliverer to do: post new alerts and
/// take down ones whose cause has resolved.
public struct NotificationPlan: Equatable, Sendable {
    public var post: [PlannedNotification] = []
    /// Notification ids to withdraw (removes the on-screen alert and the
    /// Notification Center entry).
    public var withdraw: [String] = []

    public var isEmpty: Bool { post.isEmpty && withdraw.isEmpty }

    public init(post: [PlannedNotification] = [], withdraw: [String] = []) {
        self.post = post
        self.withdraw = withdraw
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
public struct NotificationPlanner: Sendable {
    /// How long an unacted-on CI-result alert stays on screen.
    public static let runAlertDuration: TimeInterval = 300
    /// How long an unacted-on waiting-agent alert stays on screen. Short —
    /// while the agent still waits, resolution withdrawal hasn't fired, and
    /// the dashboard tile keeps showing it.
    public static let waitingAlertDuration: TimeInterval = 60

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

    public init(waitingThreshold: TimeInterval = 300, recentCompletionWindow: TimeInterval = 600) {
        self.waitingThreshold = waitingThreshold
        self.recentCompletionWindow = recentCompletionWindow
    }

    /// Drop all tracked state (used when notifications are toggled off, so a
    /// later re-enable re-primes instead of replaying stale transitions).
    public mutating func reset() {
        self = NotificationPlanner(
            waitingThreshold: waitingThreshold,
            recentCompletionWindow: recentCompletionWindow)
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
                notifiedRuns.insert(key)
                plan.post.append(notification(for: run, repo: repo, key: key))
            }
        }
        runStates = newStates
        notifiedRuns.formIntersection(Set(newStates.keys))
        return plan
    }

    private func notification(for run: WorkflowRun, repo: RepoOverview, key: String)
        -> PlannedNotification
    {
        let passed = run.state == .passed
        return PlannedNotification(
            id: "run-\(key)",
            kind: passed ? .actionPassed : .actionFailed,
            title: "\(run.workflowName) \(passed ? "passed" : "failed")",
            body: "\(repo.repo.name) · \(run.branch) — \(run.title)",
            target: run.url.isEmpty ? nil : .url(run.url),
            expiresAfter: Self.runAlertDuration)
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
                    expiresAfter: Self.waitingAlertDuration))
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
