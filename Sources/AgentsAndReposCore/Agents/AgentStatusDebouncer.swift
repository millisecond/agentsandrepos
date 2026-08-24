import Foundation

/// Holds an agent's last active status across raw idle reads while its
/// transcript still shows recent work. Claude Code writes status on
/// transition, not on a heartbeat, and reports "idle" at every turn/step
/// boundary — including mid-task ones (background subagents, `--watch`
/// commands, scheduled wakeups) — so the file can truthfully read idle for
/// 15s+ in the middle of a task.
///
/// A tick-count hold can't cover that: apply() runs from both the 3s poll
/// and every sessions-watcher kick, and the watcher covers the whole
/// directory, so any agent's write consumes every held session's tick — the
/// hold shrinks as the fleet gets busier. Instead the hold is keyed on
/// evidence of work: it releases only once the session's transcript has
/// appended nothing for `quietBuckets` activity-meter buckets. Bucket
/// indices advance once per `AgentActivityMeter.bucketSeconds`, so a held
/// label changes at most once per bucket and snapshot dedupe survives.
public struct AgentStatusDebouncer: Sendable {
    /// Release the hold once the last byte-append is at least this many
    /// buckets behind the current one. Gap 0 is the in-progress bucket, so 3
    /// means 20–30s of measured quiet — comfortably past the mid-task idle
    /// gaps seen in practice, short enough that a finished agent reads idle
    /// within half a minute.
    public static let quietBuckets = 3

    private var lastActive: [String: AgentSession.Status] = [:]

    public init() {}

    /// `bucketsSinceAppend` is `AgentActivityMeter.bucketsSinceLastAppend`
    /// for the session id: nil means no appends in the window (no evidence of
    /// work → the file's idle is trusted immediately).
    public mutating func apply(
        _ sessions: [AgentSession],
        bucketsSinceAppend: (String) -> Int?
    ) -> [AgentSession] {
        var nextActive: [String: AgentSession.Status] = [:]
        let out = sessions.map { session -> AgentSession in
            if session.status.isActive {
                nextActive[session.sessionId] = session.status
                return session
            }
            if case .idle = session.status,
                let held = lastActive[session.sessionId],
                let gap = bucketsSinceAppend(session.sessionId),
                gap < Self.quietBuckets
            {
                // Still evidence of work — keep holding next tick too.
                nextActive[session.sessionId] = held
                return session.withStatus(held)
            }
            return session
        }
        // Rebuilt each tick: released holds and vanished sessions drop.
        lastActive = nextActive
        return AgentSessionReader.sorted(out)
    }
}
