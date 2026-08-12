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

    public init(
        id: String, kind: Kind, title: String, body: String, target: ClickTarget? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.target = target
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
    public var waitingThreshold: TimeInterval
    /// A run first seen already-finished still notifies if it completed this
    /// recently — covers short runs that start and finish between the 5-min
    /// sweeps. Older ones are treated as history.
    public var recentCompletionWindow: TimeInterval

    private var primed = false
    private var runStates: [String: WorkflowRun.State] = [:]
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

    public mutating func ingest(_ snapshot: Snapshot, now: Date) -> [PlannedNotification] {
        var out = ingestRuns(snapshot, now: now)
        out += ingestWaiting(snapshot, now: now)
        primed = true
        return out
    }

    // MARK: - Workflow runs

    private mutating func ingestRuns(_ snapshot: Snapshot, now: Date) -> [PlannedNotification] {
        var out: [PlannedNotification] = []
        var newStates: [String: WorkflowRun.State] = [:]
        let ignored = Set(snapshot.config.ignoredRepos)
        for repo in snapshot.repos where !ignored.contains(repo.repo.path) {
            for run in repo.runs {
                let key = "\(repo.repo.path)#\(run.id)"
                newStates[key] = run.state
                guard primed, snapshot.config.notifyGitActions else { continue }
                guard run.state == .passed || run.state == .failed else { continue }
                let previous = runStates[key]
                let finishedWhileWatched = previous == .running
                let newAndFresh =
                    previous == nil
                    && run.updatedAt.map { now.timeIntervalSince($0) < recentCompletionWindow }
                        == true
                guard finishedWhileWatched || newAndFresh else { continue }
                out.append(notification(for: run, repo: repo, key: key))
            }
        }
        runStates = newStates
        return out
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
            target: run.url.isEmpty ? nil : .url(run.url))
    }

    // MARK: - Waiting agents

    private mutating func ingestWaiting(_ snapshot: Snapshot, now: Date) -> [PlannedNotification] {
        var out: [PlannedNotification] = []
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
            out.append(
                PlannedNotification(
                    id: "wait-\(session.sessionId)",
                    kind: .agentWaiting,
                    title: "\(session.displayName) needs you",
                    body: "\(place) — \(detail) for \(minutes)m",
                    target: .agent(pid: session.pid, cwd: session.cwd)))
        }
        // A session that stops waiting starts a fresh cycle if it waits again.
        waitingSince = waitingSince.filter { stillWaiting.contains($0.key) }
        notifiedWaiting.formIntersection(stillWaiting)
        return out
    }
}
