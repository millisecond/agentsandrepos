import XCTest

@testable import AgentsAndReposCore

final class TranscriptTaskReaderTests: XCTestCase {

    // MARK: - Path

    func testTranscriptPathSlug() {
        XCTAssertEqual(
            TranscriptTaskReader.transcriptPath(
                cwd: "/Users/me/Projects/my_app.io", sessionId: "abc-123", home: "/Users/me"),
            "/Users/me/.claude/projects/-Users-me-Projects-my-app-io/abc-123.jsonl")
    }

    // MARK: - Line parsing

    private func userLine(
        _ content: String, origin: String? = "human", sidechain: Bool = false,
        meta: Bool = false
    ) -> Substring {
        var extras = ""
        if let origin { extras += ",\"origin\":{\"kind\":\"\(origin)\"}" }
        if sidechain { extras += ",\"isSidechain\":true" }
        if meta { extras += ",\"isMeta\":true" }
        let escaped = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return Substring(
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"\(escaped)\"}\(extras)}")
    }

    func testTypedPromptExtracted() {
        XCTAssertEqual(
            TranscriptTaskReader.promptText(fromLine: userLine("fix the login bug")),
            "fix the login bug")
    }

    func testOriginMissingStillAccepted() {
        XCTAssertEqual(
            TranscriptTaskReader.promptText(fromLine: userLine("do a thing", origin: nil)),
            "do a thing")
    }

    func testNonHumanToolResultsAndWrappersSkipped() {
        // Tool result: content is an array, not a string.
        XCTAssertNil(TranscriptTaskReader.promptText(fromLine: Substring(
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#)))
        // Assistant and non-user lines.
        XCTAssertNil(TranscriptTaskReader.promptText(fromLine: Substring(
            #"{"type":"assistant","message":{"role":"assistant","content":"hi"}}"#)))
        XCTAssertNil(TranscriptTaskReader.promptText(fromLine: Substring(
            #"{"type":"summary","summary":"topic"}"#)))
        // Sidechain, meta, non-human origins.
        XCTAssertNil(TranscriptTaskReader.promptText(fromLine: userLine("x", sidechain: true)))
        XCTAssertNil(TranscriptTaskReader.promptText(fromLine: userLine("x", meta: true)))
        XCTAssertNil(TranscriptTaskReader.promptText(fromLine: userLine("x", origin: "agent")))
        // System-reminder / command wrappers and interruption markers.
        XCTAssertNil(TranscriptTaskReader.promptText(
            fromLine: userLine("<system-reminder>ctx</system-reminder>")))
        XCTAssertNil(TranscriptTaskReader.promptText(
            fromLine: userLine("[Request interrupted by user]")))
    }

    func testPromptWithPastedImageExtracted() {
        // A typed prompt with a pasted image carries block-array content and
        // an inline "[Image #N]" marker.
        XCTAssertEqual(
            TranscriptTaskReader.promptText(fromLine: Substring(
                #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Image #2] fix the missing user line"},{"type":"image","source":{}}]}}"#)),
            "fix the missing user line")
        // Image-only paste: nothing typed, nothing to show.
        XCTAssertNil(TranscriptTaskReader.promptText(fromLine: Substring(
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Image #1]"},{"type":"image","source":{}}]}}"#)))
        // A tool_result block disqualifies even if a text block rides along.
        XCTAssertNil(TranscriptTaskReader.promptText(fromLine: Substring(
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"},{"type":"text","text":"hi"}]}}"#)))
    }

    func testCleanCollapsesWhitespaceAndTruncates() {
        XCTAssertEqual(TranscriptTaskReader.clean("a  b\n\n c\t d"), "a b c d")
        let long = String(repeating: "x", count: 500)
        let cleaned = TranscriptTaskReader.clean(long)
        XCTAssertEqual(cleaned.count, TranscriptTaskReader.maxPromptChars + 1)
        XCTAssertTrue(cleaned.hasSuffix("…"))
    }

    // MARK: - Assistant lines

    private func assistantLine(_ blocks: String) -> String {
        "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[\(blocks)]}}"
    }

    func testAssistantTextExtractedFromTextBlocks() {
        XCTAssertEqual(
            TranscriptTaskReader.assistantText(fromLine: Substring(
                assistantLine(#"{"type":"text","text":"Done — rebuilt the app."}"#))),
            "Done — rebuilt the app.")
        // Tool-use-only turns have no text to summarize.
        XCTAssertNil(
            TranscriptTaskReader.assistantText(fromLine: Substring(
                assistantLine(#"{"type":"tool_use","name":"Bash","input":{}}"#))))
        // User lines are not assistant lines.
        XCTAssertNil(TranscriptTaskReader.assistantText(fromLine: userLine("hi")))
    }

    func testContinuationSummariesSkipped() {
        // Newer Claude Code flags the synthetic compaction message.
        XCTAssertNil(TranscriptTaskReader.promptText(fromLine: Substring(
            #"{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"summary of the prior conversation"}}"#)))
        // Older versions don't — match the boilerplate it opens with.
        XCTAssertNil(TranscriptTaskReader.promptText(fromLine: userLine(
            "This session is being continued from a previous conversation that ran"
                + " out of context. The conversation is summarized below: ...")))
        XCTAssertNil(TranscriptTaskReader.promptText(
            fromLine: userLine("Continue from previous context")))
    }

    func testScanFallsThroughContinuationToRealPrompt() {
        // After a compaction the synthetic summary is the newest user line;
        // the tile should surface the human's actual command behind it.
        let chunk = Data(
            """
            \(userLine("ship the new dashboard"))
            \(assistantLine(#"{"type":"text","text":"working on it"}"#))
            \(userLine("This session is being continued from a previous conversation that ran out of context."))
            """.utf8)
        let task = TranscriptTaskReader.lastMessages(in: chunk)
        XCTAssertEqual(task.lastUserMessage, "ship the new dashboard")
        XCTAssertEqual(task.lastAgentMessage, "working on it")
        XCTAssertFalse(task.userSpokeLast)
    }

    // MARK: - Chunk scanning

    func testLastMessagesAndOrderUserLast() {
        let chunk = Data(
            """
            {"type":"mode","mode":"normal"}
            \(userLine("first task"))
            \(assistantLine(#"{"type":"text","text":"finished the first task"}"#))
            \(userLine("follow-up ask"))
            """.utf8)
        let task = TranscriptTaskReader.lastMessages(in: chunk)
        XCTAssertEqual(task.lastUserMessage, "follow-up ask")
        XCTAssertEqual(task.lastAgentMessage, "finished the first task")
        XCTAssertTrue(task.userSpokeLast)
    }

    func testLastMessagesAndOrderAgentLast() {
        let chunk = Data(
            """
            \(userLine("do the thing"))
            \(assistantLine(#"{"type":"text","text":"thing is done"}"#))
            """.utf8)
        let task = TranscriptTaskReader.lastMessages(in: chunk)
        XCTAssertEqual(task.lastUserMessage, "do the thing")
        XCTAssertEqual(task.lastAgentMessage, "thing is done")
        XCTAssertFalse(task.userSpokeLast)
    }

    func testPartialLeadingLineSkipped() {
        let chunk = Data(
            """
            role":"user","content":"cut off mid line"}}
            \(userLine("real prompt"))
            """.utf8)
        XCTAssertEqual(TranscriptTaskReader.lastMessages(in: chunk).lastUserMessage, "real prompt")
    }

    func testUserMessageBuriedBeyondFirstChunkFound() throws {
        // One long agentic turn: the user's prompt followed by >256KB of tool
        // results. A fixed tail window loses the prompt; the backward scan
        // must keep walking chunks until it finds it. The sizes are arranged
        // so a tool-result line straddles the first chunk boundary, covering
        // the carry-over of split lines too.
        let home = NSTemporaryDirectory() + "ttr-\(UUID().uuidString)"
        let dir = home + "/.claude/projects/-x"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func toolLine(exactly n: Int) -> String {
            let prefix =
                #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":""#
            let suffix = "\"}]}}"
            return prefix + String(repeating: "x", count: n - prefix.count - suffix.count - 1)
                + suffix + "\n"
        }
        let asst = assistantLine(#"{"type":"text","text":"still churning"}"#) + "\n"
        var body = toolLine(exactly: 2048) + userLine("deep buried ask") + "\n"
        var fillerBytes = TranscriptTaskReader.chunkBytes - 50 - asst.count
        while fillerBytes > 0 {
            let n = fillerBytes > 8192 ? 4096 : fillerBytes
            body += toolLine(exactly: n)
            fillerBytes -= n
        }
        body += asst
        let path = dir + "/sess.jsonl"
        try body.write(toFile: path, atomically: true, encoding: .utf8)

        let task = TranscriptTaskReader.read(cwd: "/x", sessionId: "sess", home: home)
        XCTAssertEqual(task.lastUserMessage, "deep buried ask")
        XCTAssertEqual(task.lastAgentMessage, "still churning")
        XCTAssertFalse(task.userSpokeLast)
    }

    // MARK: - History

    func testHistoryCollectedOldestFirstAndCapped() {
        var body = ""
        for i in 1...(TranscriptTaskReader.historyLimit + 5) {
            body += userLine("ask \(i)") + "\n"
            body += assistantLine("{\"type\":\"text\",\"text\":\"reply \(i)\"}") + "\n"
        }
        let task = TranscriptTaskReader.lastMessages(in: Data(body.utf8))
        XCTAssertEqual(task.history.count, TranscriptTaskReader.historyLimit)
        // Newest at the end, window covering the most recent messages.
        XCTAssertEqual(task.history.last?.text, "reply \(TranscriptTaskReader.historyLimit + 5)")
        XCTAssertEqual(task.history.last?.role, .agent)
        XCTAssertEqual(task.lastUserMessage, "ask \(TranscriptTaskReader.historyLimit + 5)")
    }

    func testHeadlineSlotsOutliveHistoryWindow() {
        // An assistant streak longer than the window must not lose the last
        // human prompt behind it.
        var body = userLine("the buried ask") + "\n"
        for i in 1...(TranscriptTaskReader.historyLimit + 3) {
            body += assistantLine("{\"type\":\"text\",\"text\":\"step \(i)\"}") + "\n"
        }
        let task = TranscriptTaskReader.lastMessages(in: Data(body.utf8))
        XCTAssertEqual(task.lastUserMessage, "the buried ask")
        XCTAssertEqual(task.history.count, TranscriptTaskReader.historyLimit)
        XCTAssertTrue(task.history.allSatisfy { $0.role == .agent })
    }

    func testAppendedMergesAndTrims() {
        let prev = AgentTask(
            lastUserMessage: "old ask", lastAgentMessage: "old reply", userSpokeLast: false,
            history: [
                TranscriptMessage(role: .user, text: "old ask"),
                TranscriptMessage(role: .agent, text: "old reply"),
            ])
        let appended = Data(
            (userLine("new ask") + "\n"
                + assistantLine("{\"type\":\"text\",\"text\":\"new reply\"}") + "\n").utf8)
        let task = TranscriptTaskReader.appended(to: prev, parsing: appended)
        XCTAssertEqual(task.lastUserMessage, "new ask")
        XCTAssertEqual(task.lastAgentMessage, "new reply")
        XCTAssertFalse(task.userSpokeLast)
        XCTAssertEqual(task.history.map(\.text), ["old ask", "old reply", "new ask", "new reply"])

        // Tool-result-only appends change nothing.
        let noise = Data(
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#
                .utf8)
        XCTAssertEqual(TranscriptTaskReader.appended(to: task, parsing: noise), task)
    }

    func testIncrementalReadPicksUpAppendedMessages() throws {
        let home = NSTemporaryDirectory() + "ttr-\(UUID().uuidString)"
        let dir = home + "/.claude/projects/-x"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/sess.jsonl"
        try (userLine("first ask") + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let first = TranscriptTaskReader.read(cwd: "/x", sessionId: "sess", home: home)
        XCTAssertEqual(first.lastUserMessage, "first ask")

        // Append (with a changed mtime) and re-read: history holds both.
        let fh = FileHandle(forWritingAtPath: path)!
        fh.seekToEndOfFile()
        fh.write(Data((assistantLine("{\"type\":\"text\",\"text\":\"on it\"}") + "\n").utf8))
        try fh.close()
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: path)

        let second = TranscriptTaskReader.read(cwd: "/x", sessionId: "sess", home: home)
        XCTAssertEqual(second.lastUserMessage, "first ask")
        XCTAssertEqual(second.lastAgentMessage, "on it")
        XCTAssertEqual(second.history.map(\.text), ["first ask", "on it"])
        XCTAssertFalse(second.userSpokeLast)
    }

    // MARK: - Plan integration

    func testAgentPlansSummarizeEachMessageAlone() {
        let longAsk = "make every summary line terse and drop the boilerplate prefixes everywhere"
        let session = AgentSession(
            pid: 1, sessionId: "s", cwd: "/x", name: "a", kind: "interactive",
            status: .idle, startedAt: nil, updatedAt: nil,
            task: AgentTask(
                lastUserMessage: longAsk, lastAgentMessage: "done, rebuilt",
                userSpokeLast: false))
        let tile = AgentTileState(agent: session, location: "l", path: "/x")
        XCTAssertEqual(SummaryFacts.agentUserPlan(tile), .generate(longAsk))
        XCTAssertEqual(SummaryFacts.agentAgentPlan(tile), .generate("done, rebuilt"))
        XCTAssertEqual(SummaryFacts.agentUserKey(tile), "agent:s:user")
        XCTAssertEqual(SummaryFacts.agentAgentKey(tile), "agent:s:asst")
    }
}
