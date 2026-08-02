import Foundation

/// A live Claude Code session, read from `~/.claude/sessions/<pid>.json`.
public struct AgentSession: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        case idle
        case busy
        case waiting(String?)
        case unknown(String)

        public var isBusy: Bool {
            if case .busy = self { return true }
            return false
        }

        public var isWaiting: Bool {
            if case .waiting = self { return true }
            return false
        }

        /// Busy or waiting — an agent actively holding the repo.
        public var isActive: Bool { isBusy || isWaiting }

        public var label: String {
            switch self {
            case .idle: return "idle"
            case .busy: return "busy"
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

    public var id: String { sessionId }
    public var displayName: String { name ?? String(sessionId.prefix(8)) }
    public var isBackground: Bool { kind == "bg" }

    public init(
        pid: Int32, sessionId: String, cwd: String, name: String?, kind: String,
        status: Status, startedAt: Date?, updatedAt: Date?, task: AgentTask = AgentTask()
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
    }
}
