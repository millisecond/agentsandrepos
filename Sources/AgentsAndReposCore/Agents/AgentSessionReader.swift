import Darwin
import Foundation

/// Reads live Claude Code sessions from `~/.claude/sessions/<pid>.json`.
/// Files for dead PIDs linger, so each record is liveness-checked against the
/// actual process table, cross-checking kernel process start time against the
/// file's `startedAt` (epoch ms) to catch PID reuse. The file's `procStart`
/// string is deliberately ignored — it is recorded in whatever timezone was
/// active at write time and can't be compared reliably.
public enum AgentSessionReader {
    public static let defaultDir = NSHomeDirectory() + "/.claude/sessions"

    /// Sessions whose `updatedAt` is older than this are dropped even if the
    /// process is alive (e.g. month-old idle `claude` tabs).
    static let dropAfter: TimeInterval = 24 * 3600

    /// busy/waiting statuses update constantly while real; one this stale is a
    /// leftover, so demote it to idle instead of showing a false "busy".
    static let activeStatusTrustedFor: TimeInterval = 3600

    /// Max allowed gap between the file's startedAt and the kernel's process
    /// start time before the PID is considered reused.
    static let startTimeTolerance: TimeInterval = 600

    public static func read(
        dir: String = defaultDir,
        isAlive: (Int32, Date?) -> Bool = defaultIsAlive,
        taskReader: (String, String) -> AgentTask = {
            TranscriptTaskReader.read(cwd: $0, sessionId: $1)
        },
        now: Date = Date()
    ) -> [AgentSession] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [AgentSession] = []
        for entry in entries where entry.hasSuffix(".json") {
            guard let data = fm.contents(atPath: dir + "/" + entry),
                var session = parse(data)
            else { continue }
            if let updated = session.updatedAt, now.timeIntervalSince(updated) > dropAfter {
                continue
            }
            guard isAlive(session.pid, session.startedAt) else { continue }
            if session.status.isActive,
                let updated = session.updatedAt,
                now.timeIntervalSince(updated) > activeStatusTrustedFor
            {
                session = session.withStatus(.idle)
            }
            session = session.withTask(taskReader(session.cwd, session.sessionId))
            out.append(session)
        }
        return sorted(out)
    }

    /// Waiting first, then busy, then unknown, then idle; newest first within a rank.
    public static func sorted(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.sorted { a, b in
            rank(a.status) == rank(b.status)
                ? (a.startedAt ?? .distantPast) > (b.startedAt ?? .distantPast)
                : rank(a.status) < rank(b.status)
        }
    }

    private static func rank(_ s: AgentSession.Status) -> Int {
        switch s {
        case .waiting: return 0
        case .busy: return 1
        case .unknown: return 2
        case .idle: return 3
        }
    }

    // MARK: - Parsing

    private struct SessionDTO: Decodable {
        var pid: Int32?
        var sessionId: String?
        var cwd: String?
        var name: String?
        var kind: String?
        var status: String?
        var waitingFor: String?
        var startedAt: Double?
        var updatedAt: Double?
    }

    /// Decodes one session file. Lenient: unknown fields ignored, unknown status
    /// strings preserved.
    public static func parse(_ data: Data) -> AgentSession? {
        guard let dto = try? JSONDecoder().decode(SessionDTO.self, from: data),
            let pid = dto.pid, let sessionId = dto.sessionId, let cwd = dto.cwd
        else { return nil }

        let status: AgentSession.Status
        switch dto.status {
        case "idle": status = .idle
        case "busy": status = .busy
        case "waiting": status = .waiting(dto.waitingFor)
        case let other?: status = .unknown(other)
        case nil: status = .unknown("unknown")
        }

        return AgentSession(
            pid: pid,
            sessionId: sessionId,
            cwd: cwd,
            name: dto.name,
            kind: dto.kind ?? "interactive",
            status: status,
            startedAt: dto.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            updatedAt: dto.updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    // MARK: - Liveness

    public static func defaultIsAlive(pid: Int32, startedAt: Date?) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) != 0 && errno != EPERM { return false }
        // PID exists — cross-check start time to catch PID reuse.
        if let expected = startedAt, let actual = processStartTime(pid: pid),
            abs(actual.timeIntervalSince(expected)) > startTimeTolerance
        { return false }
        return true
    }

    static func processStartTime(pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard ret == size else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }
}

extension AgentSession {
    func withStatus(_ new: Status) -> AgentSession {
        AgentSession(
            pid: pid, sessionId: sessionId, cwd: cwd, name: name, kind: kind,
            status: new, startedAt: startedAt, updatedAt: updatedAt, task: task)
    }

    fileprivate func withTask(_ new: AgentTask) -> AgentSession {
        AgentSession(
            pid: pid, sessionId: sessionId, cwd: cwd, name: name, kind: kind,
            status: status, startedAt: startedAt, updatedAt: updatedAt, task: new)
    }
}
