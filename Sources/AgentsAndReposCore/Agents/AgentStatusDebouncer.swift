import Foundation

/// One-tick debounce for active→idle flips. Claude Code writes "idle" at every
/// turn end, including mid-task gaps (background subagents, scheduled wakeups),
/// so a single poll seeing idle right after busy/waiting is usually a
/// between-steps blip. Hold the previous active status for exactly one apply();
/// if the next poll still reads idle, it goes through.
public struct AgentStatusDebouncer: Sendable {
    private var lastActive: [String: AgentSession.Status] = [:]

    public init() {}

    public mutating func apply(_ sessions: [AgentSession]) -> [AgentSession] {
        var nextActive: [String: AgentSession.Status] = [:]
        let out = sessions.map { session -> AgentSession in
            if session.status.isActive {
                nextActive[session.sessionId] = session.status
                return session
            }
            if case .idle = session.status, let held = lastActive[session.sessionId] {
                return session.withStatus(held)
            }
            return session
        }
        // Rebuilt each tick: a consumed hold isn't re-added, vanished sessions drop.
        lastActive = nextActive
        return AgentSessionReader.sorted(out)
    }
}
