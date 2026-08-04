import Foundation

/// The tail of a Claude Code session's conversation, pulled from its
/// transcript: the last human-typed message and the last assistant text
/// reply, cleaned and truncated, plus which of the two is more recent.
public struct AgentTask: Sendable, Equatable {
    public var lastUserMessage: String?
    public var lastAgentMessage: String?
    /// True when the user message is the more recent of the two (the agent's
    /// turn is pending or in progress).
    public var userSpokeLast: Bool

    public init(
        lastUserMessage: String? = nil, lastAgentMessage: String? = nil,
        userSpokeLast: Bool = false
    ) {
        self.lastUserMessage = lastUserMessage
        self.lastAgentMessage = lastAgentMessage
        self.userSpokeLast = userSpokeLast
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
        if let c = cache[path], c.mtime == mtime, c.size == size {
            let task = c.task
            cacheLock.unlock()
            return task
        }
        cacheLock.unlock()

        guard let fh = FileHandle(forReadingAtPath: path) else { return AgentTask() }
        defer { try? fh.close() }
        guard let end = try? fh.seekToEnd() else { return AgentTask() }
        let task = scanBackwards(fh: fh, size: end)

        cacheLock.lock()
        cache[path] = CachedTask(mtime: mtime, size: size, task: task)
        cacheLock.unlock()
        return task
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

    /// Accumulates the two slots while lines arrive newest-first: the first
    /// hit per slot wins, and whichever slot fills first spoke last.
    struct Scan {
        var user: String?
        var agent: String?
        private var userLast = false

        var isComplete: Bool { user != nil && agent != nil }

        mutating func take(line: Substring) {
            if user == nil, let p = TranscriptTaskReader.promptText(fromLine: line) {
                user = p
                userLast = agent == nil
            } else if agent == nil,
                let a = TranscriptTaskReader.assistantText(fromLine: line)
            {
                agent = a
            }
        }

        var task: AgentTask {
            AgentTask(
                lastUserMessage: user, lastAgentMessage: agent,
                userSpokeLast: user != nil && userLast)
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
        var message: Msg?
        var origin: Origin?
    }

    /// The cleaned prompt text if this transcript line is a human-typed
    /// message, else nil.
    public static func promptText(fromLine line: Substring) -> String? {
        guard line.contains("\"type\":\"user\"") else { return nil }
        guard let dto = try? JSONDecoder().decode(LineDTO.self, from: Data(line.utf8)),
            dto.type == "user",
            dto.isSidechain != true,
            dto.isMeta != true,
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

    /// Collapses whitespace runs and truncates for use in an LLM facts string.
    static func clean(_ s: String) -> String {
        let collapsed = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if collapsed.count <= maxPromptChars { return collapsed }
        return String(collapsed.prefix(maxPromptChars)) + "…"
    }
}
