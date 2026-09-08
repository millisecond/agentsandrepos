import Foundation

/// One human or assistant message from a session transcript. Search-only —
/// never rendered — so its text keeps far more of the original than the
/// headline fields (capped at `TranscriptTaskReader.maxHistoryChars`, not
/// `maxPromptChars`).
public struct TranscriptMessage: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        case user, agent
    }

    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// The tail of a Claude Code session's conversation, pulled from its
/// transcript: the last human-typed message and the last assistant text
/// reply, cleaned and truncated, plus which of the two is more recent —
/// and a deeper capped history so search can reach past what the tile shows.
public struct AgentTask: Sendable, Equatable {
    public var lastUserMessage: String?
    public var lastAgentMessage: String?
    /// True when the user message is the more recent of the two (the agent's
    /// turn is pending or in progress).
    public var userSpokeLast: Bool
    /// The most recent messages of both roles, oldest first, capped at
    /// `TranscriptTaskReader.historyLimit`. The headline fields can predate
    /// this window (a long assistant streak pushes the last human prompt
    /// out), so they are stored separately, not derived.
    public var history: [TranscriptMessage]

    public init(
        lastUserMessage: String? = nil, lastAgentMessage: String? = nil,
        userSpokeLast: Bool = false, history: [TranscriptMessage] = []
    ) {
        self.lastUserMessage = lastUserMessage
        self.lastAgentMessage = lastAgentMessage
        self.userSpokeLast = userSpokeLast
        self.history = history
    }
}

/// Reads `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl` transcripts.
/// The file is scanned backwards in chunks from the end — one long agentic
/// turn can bury the user's prompt under hundreds of KB of tool results, so a
/// fixed tail window loses it. The scan stops at the first (latest) hit for
/// each slot, capped so a transcript with no human message ever stays cheap.
/// Human-typed prompts and assistant text replies count — tool results/uses,
/// sidechains, meta lines, and system/command wrappers are skipped.
public enum TranscriptTaskReader {
    static let chunkBytes = 256 * 1024
    /// Most transcripts resolve within the first chunk; this bounds the
    /// pathological ones (e.g. autonomous sessions with no human message at
    /// all, which would otherwise scan the whole file every poll).
    static let maxScanBytes = 4 * 1024 * 1024
    static let maxPromptChars = 200
    /// Cap for `AgentTask.history` text. History exists only to be searched,
    /// so it isn't squeezed to the one-line tile size — but it still needs a
    /// bound so a pathological paste can't bloat every snapshot publish.
    static let maxHistoryChars = 4000
    /// How many messages (both roles combined) `AgentTask.history` keeps —
    /// the dashboard search's reach back into a session. The deep backward
    /// scan to fill it runs once per session (still `maxScanBytes`-capped);
    /// after that, appends are parsed incrementally.
    public static let historyLimit = 20

    public static func transcriptPath(
        cwd: String, sessionId: String, home: String = NSHomeDirectory()
    ) -> String {
        let slug = cwd.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return home + "/.claude/projects/" + slug + "/" + sessionId + ".jsonl"
    }

    /// Re-parsing a 256KB tail on every 3s poll adds up; a stat per call
    /// decides whether the transcript actually changed since last time.
    private struct CachedTask {
        var mtime: Date
        var size: UInt64
        var task: AgentTask
    }
    nonisolated(unsafe) private static var cache: [String: CachedTask] = [:]
    private static let cacheLock = NSLock()

    public static func read(
        cwd: String, sessionId: String, home: String = NSHomeDirectory()
    ) -> AgentTask {
        let path = transcriptPath(cwd: cwd, sessionId: sessionId, home: home)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let size = (attrs[.size] as? NSNumber)?.uint64Value,
            let mtime = attrs[.modificationDate] as? Date
        else { return AgentTask() }

        cacheLock.lock()
        let prev = cache[path]
        cacheLock.unlock()
        if let prev, prev.mtime == mtime, prev.size == size {
            return prev.task
        }

        guard let fh = FileHandle(forReadingAtPath: path) else { return AgentTask() }
        defer { try? fh.close() }
        guard let end = try? fh.seekToEnd() else { return AgentTask() }

        // Transcripts are append-only JSONL, so a grown file only needs its
        // new bytes parsed — O(appended), not O(tail). Anything unusual (file
        // shrank, huge gap, previous read ended mid-line because a write was
        // in flight) falls back to the full backward scan.
        let task: AgentTask
        if let prev, end > prev.size, end - prev.size <= UInt64(maxScanBytes),
            endsOnLineBoundary(fh: fh, at: prev.size)
        {
            try? fh.seek(toOffset: prev.size)
            let data = (try? fh.read(upToCount: Int(end - prev.size))) ?? Data()
            task = appended(to: prev.task, parsing: data)
        } else {
            task = scanBackwards(fh: fh, size: end)
        }

        cacheLock.lock()
        cache[path] = CachedTask(mtime: mtime, size: size, task: task)
        cacheLock.unlock()
        return task
    }

    /// True when the byte before `offset` is a newline — i.e. the previous
    /// read stopped at a whole line and the appended region starts on one.
    private static func endsOnLineBoundary(fh: FileHandle, at offset: UInt64) -> Bool {
        guard offset > 0 else { return true }
        try? fh.seek(toOffset: offset - 1)
        guard let byte = try? fh.read(upToCount: 1), byte.count == 1 else { return false }
        return byte[byte.startIndex] == UInt8(ascii: "\n")
    }

    /// Merges messages parsed from an appended region (oldest first) into a
    /// cached task. A trailing partial line fails to parse and is skipped
    /// here; the boundary check above catches it on the next read and
    /// triggers a full rescan, so nothing is lost for good.
    static func appended(to prev: AgentTask, parsing data: Data) -> AgentTask {
        let new = messages(in: data)
        guard !new.isEmpty else { return prev }
        var history = prev.history + new
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
        return AgentTask(
            lastUserMessage: (new.last { $0.role == .user }?.text).map(headline)
                ?? prev.lastUserMessage,
            lastAgentMessage: (new.last { $0.role == .agent }?.text).map(headline)
                ?? prev.lastAgentMessage,
            userSpokeLast: new.last?.role == .user,
            history: history)
    }

    /// All prompt/assistant messages in a chunk, oldest first.
    static func messages(in data: Data) -> [TranscriptMessage] {
        let text = String(decoding: data, as: UTF8.self)
        var out: [TranscriptMessage] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let p = promptText(fromLine: line) {
                out.append(TranscriptMessage(role: .user, text: p))
            } else if let a = assistantText(fromLine: line) {
                out.append(TranscriptMessage(role: .agent, text: a))
            }
        }
        return out
    }

    /// Transcript size as of the last `read` for this session, straight from
    /// the stat cache — no filesystem access. The agents tick calls `read`
    /// for every live session before asking, so the cache is warm; nil only
    /// before the first successful read (e.g. transcript missing).
    public static func cachedTranscriptSize(
        cwd: String, sessionId: String, home: String = NSHomeDirectory()
    ) -> UInt64? {
        let path = transcriptPath(cwd: cwd, sessionId: sessionId, home: home)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[path]?.size
    }

    /// Walks the file end-to-start one chunk at a time, stopping as soon as
    /// both slots are filled (or the scan cap is hit).
    private static func scanBackwards(fh: FileHandle, size: UInt64) -> AgentTask {
        var scan = Scan()
        // The lowest-offset line of a chunk is usually a fragment whose start
        // lives in the next (earlier) chunk; carry it over to be completed.
        var carry = Data()
        var end = size
        var budget = maxScanBytes
        while end > 0, budget > 0, !scan.isComplete {
            let len = Int(min(end, UInt64(min(chunkBytes, budget))))
            let start = end - UInt64(len)
            try? fh.seek(toOffset: start)
            guard var data = try? fh.read(upToCount: len), !data.isEmpty else { break }
            data.append(carry)
            var pieces = data.split(
                separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            if start > 0, let fragment = pieces.first {
                carry = Data(fragment)
                pieces.removeFirst()
            } else {
                carry = Data()
            }
            for piece in pieces.reversed() {
                scan.take(line: Substring(String(decoding: piece, as: UTF8.self)))
                if scan.isComplete { break }
            }
            end = start
            budget -= len
        }
        return scan.task
    }

    /// Accumulates the two headline slots plus the history window while lines
    /// arrive newest-first: the first hit per slot wins, whichever slot fills
    /// first spoke last, and every message feeds history until it's full.
    /// The scan runs until both slots AND history are filled (or the byte
    /// budget runs out) — the slots can outlive the window when one role
    /// streaks past `historyLimit`.
    struct Scan {
        var user: String?
        var agent: String?
        private var userLast = false
        /// Newest-first while scanning; reversed into the task.
        private var history: [TranscriptMessage] = []

        var isComplete: Bool {
            user != nil && agent != nil
                && history.count >= TranscriptTaskReader.historyLimit
        }

        mutating func take(line: Substring) {
            let message: TranscriptMessage?
            if let p = TranscriptTaskReader.promptText(fromLine: line) {
                message = TranscriptMessage(role: .user, text: p)
                if user == nil {
                    user = TranscriptTaskReader.headline(p)
                    userLast = agent == nil
                }
            } else if let a = TranscriptTaskReader.assistantText(fromLine: line) {
                message = TranscriptMessage(role: .agent, text: a)
                if agent == nil { agent = TranscriptTaskReader.headline(a) }
            } else {
                message = nil
            }
            if let message, history.count < TranscriptTaskReader.historyLimit {
                history.append(message)
            }
        }

        var task: AgentTask {
            AgentTask(
                lastUserMessage: user, lastAgentMessage: agent,
                userSpokeLast: user != nil && userLast,
                history: history.reversed())
        }
    }

    /// Last user prompt and last assistant reply in a chunk of transcript,
    /// with their relative order. The chunk may start mid-line; that fragment
    /// simply fails to parse and is skipped.
    static func lastMessages(in data: Data) -> AgentTask {
        let text = String(decoding: data, as: UTF8.self)
        var scan = Scan()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            scan.take(line: line)
            if scan.isComplete { break }
        }
        return scan.task
    }

    private struct LineDTO: Decodable {
        struct Msg: Decodable {
            var role: String?
            var content: Content?
        }
        struct Block: Decodable {
            var type: String?
            var text: String?
        }
        /// Typed prompts have string content; assistant replies (and user
        /// tool results) carry block arrays.
        enum Content: Decodable {
            case text(String)
            case blocks([Block])
            case other
            init(from decoder: Decoder) throws {
                if let s = try? decoder.singleValueContainer().decode(String.self) {
                    self = .text(s)
                } else if let b = try? decoder.singleValueContainer().decode([Block].self) {
                    self = .blocks(b)
                } else {
                    self = .other
                }
            }
        }
        struct Origin: Decodable { var kind: String? }
        var type: String?
        var isSidechain: Bool?
        var isMeta: Bool?
        var isCompactSummary: Bool?
        var message: Msg?
        var origin: Origin?
    }

    /// Compaction/resume inserts a synthetic user message carrying the prior
    /// conversation's summary. Older Claude Code versions don't flag it, so
    /// also match the boilerplate it always opens with.
    private static let continuationPrefixes = [
        "This session is being continued from a previous conversation",
        "Continue from previous context",
    ]

    /// The cleaned prompt text if this transcript line is a human-typed
    /// message, else nil.
    public static func promptText(fromLine line: Substring) -> String? {
        guard line.contains("\"type\":\"user\"") else { return nil }
        guard let dto = try? JSONDecoder().decode(LineDTO.self, from: Data(line.utf8)),
            dto.type == "user",
            dto.isSidechain != true,
            dto.isMeta != true,
            dto.isCompactSummary != true,
            dto.message?.role == "user"
        else { return nil }
        if let kind = dto.origin?.kind, kind != "human" { return nil }
        let content: String
        switch dto.message?.content {
        case .text(let s):
            content = s
        case .blocks(let blocks):
            // A typed prompt with a pasted image is a block array too (text +
            // image) — only tool results disqualify a user line.
            guard !blocks.contains(where: { $0.type == "tool_result" }) else { return nil }
            content = blocks.filter { $0.type == "text" }.compactMap(\.text)
                .joined(separator: " ")
        default:
            return nil
        }
        // Pasted images leave "[Image #3]" markers in the typed text; drop
        // them before the "["-prefix check below rejects the whole message.
        let trimmed = content
            .replacingOccurrences(
                of: #"\[Image #\d+\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // "<" catches system-reminder / command wrappers; "[" catches
        // interruption markers like "[Request interrupted by user]".
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("[") else {
            return nil
        }
        // Skipping the continuation boilerplate lets the backward scan fall
        // through to the user's actual last prompt in the replayed history —
        // far more useful on a tile than "Continue from previous context".
        guard !Self.continuationPrefixes.contains(where: trimmed.hasPrefix) else {
            return nil
        }
        return clean(trimmed)
    }

    /// The cleaned text of an assistant reply, concatenating its text blocks;
    /// nil for tool-use-only turns and sidechains.
    public static func assistantText(fromLine line: Substring) -> String? {
        guard line.contains("\"type\":\"assistant\"") else { return nil }
        guard let dto = try? JSONDecoder().decode(LineDTO.self, from: Data(line.utf8)),
            dto.type == "assistant",
            dto.isSidechain != true,
            case .blocks(let blocks)? = dto.message?.content
        else { return nil }
        let text = blocks.filter { $0.type == "text" }
            .compactMap(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return clean(text)
    }

    /// Collapses whitespace runs, keeping the text near-full length: this is
    /// the history/search form. The headline fields tighten it further via
    /// `headline` at assignment.
    static func clean(_ s: String) -> String {
        truncated(
            s.split(whereSeparator: \.isWhitespace).joined(separator: " "),
            at: maxHistoryChars)
    }

    /// The display/LLM-facts form: tiles render one line and the facts string
    /// needs bounding, so the headline slots stay short.
    static func headline(_ s: String) -> String {
        truncated(s, at: maxPromptChars)
    }

    private static func truncated(_ s: String, at limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "…"
    }
}
