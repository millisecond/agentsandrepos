import Foundation

/// A live Claude Code session, read from `~/.claude/sessions/<pid>.json`.
public struct AgentSession: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        case idle
        case busy
        /// The session is parked on a running shell command (long-running or
        /// backgrounded Bash) — the agent isn't reasoning, but work is in
        /// flight and it will resume when the command finishes. An
        /// intermediate state between busy and idle.
        case shell
        case waiting(String?)
        case unknown(String)

        public var isBusy: Bool {
            if case .busy = self { return true }
            return false
        }

        public var isShell: Bool {
            if case .shell = self { return true }
            return false
        }

        public var isWaiting: Bool {
            if case .waiting = self { return true }
            return false
        }

        /// Busy, waiting, or parked on a shell command — an agent actively
        /// holding the repo. Gates auto-fast-forward, and stale-status
        /// demotion (an hour-old "shell" is a dead file, not a live command).
        public var isActive: Bool { isBusy || isWaiting || isShell }

        public var label: String {
            switch self {
            case .idle: return "idle"
            case .busy: return "busy"
            case .shell: return "shell"
            case .waiting(let what):
                if let what, !what.isEmpty { return "waiting: \(what)" }
                return "waiting"
            case .unknown(let raw): return raw
            }
        }

        public var glyph: String {
            switch self {
            case .idle: return "·"
            case .busy: return "⚙"
            case .shell: return "❯"
            case .waiting: return "⏸"
            case .unknown: return "?"
            }
        }
    }

    public let pid: Int32
    public let sessionId: String
    public let cwd: String
    public let name: String?
    public let kind: String
    public let status: Status
    public let startedAt: Date?
    public let updatedAt: Date?
    /// What the session is actually working on, from its transcript.
    public let task: AgentTask
    /// Transcript-throughput LED levels (0–15 per bucket, oldest first) from
    /// `AgentActivityMeter`; empty when the recent window is quiet. Attached
    /// by the engine after reading — quantized so it only perturbs snapshot
    /// equality when a bar would visibly change.
    public let activity: [Int]

    public var id: String { sessionId }
    public var displayName: String { name ?? String(sessionId.prefix(8)) }
    public var isBackground: Bool { kind == "bg" }

    public init(
        pid: Int32, sessionId: String, cwd: String, name: String?, kind: String,
        status: Status, startedAt: Date?, updatedAt: Date?, task: AgentTask = AgentTask(),
        activity: [Int] = []
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.name = name
        self.kind = kind
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.task = task
        self.activity = activity
    }
}
