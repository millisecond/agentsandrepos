import XCTest

@testable import AgentsAndReposCore

final class AgentSessionReaderTests: XCTestCase {
    func testParseBusySession() throws {
        let json = """
            {"pid":44729,"sessionId":"82fd2423","cwd":"/Users/x/Projects/former",
             "startedAt":1782397228554,"procStart":"Thu Jun 25 14:20:20 2026",
             "version":"2.1.185","kind":"interactive","entrypoint":"cli",
             "status":"busy","updatedAt":1782397857674}
            """
        let session = try XCTUnwrap(AgentSessionReader.parse(Data(json.utf8)))
        XCTAssertEqual(session.pid, 44729)
        XCTAssertEqual(session.cwd, "/Users/x/Projects/former")
        XCTAssertEqual(session.status, .busy)
        XCTAssertFalse(session.isBackground)
        XCTAssertEqual(
            session.startedAt?.timeIntervalSince1970 ?? 0, 1782397228.554, accuracy: 0.01)
    }

    func testParseWaitingSession() throws {
        let json = """
            {"pid":1,"sessionId":"abc","cwd":"/x","status":"waiting",
             "waitingFor":"permission prompt","kind":"bg","name":"Fix the bug"}
            """
        let session = try XCTUnwrap(AgentSessionReader.parse(Data(json.utf8)))
        XCTAssertEqual(session.status, .waiting("permission prompt"))
        XCTAssertTrue(session.status.isWaiting)
        XCTAssertTrue(session.isBackground)
        XCTAssertEqual(session.displayName, "Fix the bug")
    }

    func testUnknownStatusPreserved() throws {
        let json = """
            {"pid":1,"sessionId":"abc","cwd":"/x","status":"compacting"}
            """
        let session = try XCTUnwrap(AgentSessionReader.parse(Data(json.utf8)))
        XCTAssertEqual(session.status, .unknown("compacting"))
    }

    func testMissingRequiredFieldsRejected() {
        XCTAssertNil(AgentSessionReader.parse(Data("{\"pid\":1}".utf8)))
        XCTAssertNil(AgentSessionReader.parse(Data("not json".utf8)))
    }

    func testReadFiltersDeadAndStaleAndDemotesStaleBusy() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let fresh = now.timeIntervalSince1970 * 1000
        let staleBusy = (now.timeIntervalSince1970 - 2 * 3600) * 1000  // 2h — demote
        let ancient = (now.timeIntervalSince1970 - 100 * 3600) * 1000  // 100h — drop

        func write(_ name: String, pid: Int, status: String, updatedAt: Double) throws {
            let json = """
                {"pid":\(pid),"sessionId":"\(name)","cwd":"/x","status":"\(status)","updatedAt":\(updatedAt)}
                """
            try Data(json.utf8).write(to: dir.appendingPathComponent("\(name).json"))
        }
        try write("alive", pid: 100, status: "busy", updatedAt: fresh)
        try write("dead", pid: 200, status: "busy", updatedAt: fresh)
        try write("ancient", pid: 300, status: "idle", updatedAt: ancient)
        try write("stalebusy", pid: 400, status: "busy", updatedAt: staleBusy)

        let sessions = AgentSessionReader.read(
            dir: dir.path,
            isAlive: { pid, _ in pid != 200 },
            now: now)
        XCTAssertEqual(Set(sessions.map(\.sessionId)), ["alive", "stalebusy"])
        XCTAssertEqual(sessions.first { $0.sessionId == "alive" }?.status, .busy)
        // A 2h-old "busy" is a leftover, not a real busy agent.
        XCTAssertEqual(sessions.first { $0.sessionId == "stalebusy" }?.status, .idle)
    }

    func testDefaultIsAliveOwnProcess() {
        // Our own PID is alive; a start time far in the past means "PID reused".
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(AgentSessionReader.defaultIsAlive(pid: pid, startedAt: nil))
        XCTAssertFalse(
            AgentSessionReader.defaultIsAlive(
                pid: pid, startedAt: Date(timeIntervalSince1970: 1000)))
        // Kernel start time should agree with itself within tolerance.
        let actual = AgentSessionReader.processStartTime(pid: pid)
        XCTAssertNotNil(actual)
        XCTAssertTrue(AgentSessionReader.defaultIsAlive(pid: pid, startedAt: actual))
    }
}
