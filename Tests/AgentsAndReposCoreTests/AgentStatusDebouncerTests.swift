import XCTest

@testable import AgentsAndReposCore

final class AgentStatusDebouncerTests: XCTestCase {
    private func session(_ id: String, _ status: AgentSession.Status) -> AgentSession {
        AgentSession(
            pid: 1, sessionId: id, cwd: "/x", name: nil, kind: "interactive",
            status: status, startedAt: nil, updatedAt: nil)
    }

    /// Evidence closure: every session's transcript appended bytes `gap`
    /// buckets ago (nil = never).
    private func evidence(_ gap: Int?) -> (String) -> Int? { { _ in gap } }

    func testIdleHeldWhileTranscriptRecentlyActive() {
        var d = AgentStatusDebouncer()
        _ = d.apply([session("a", .busy)], bucketsSinceAppend: evidence(0))
        // Bytes still landing: the raw idle is a mid-task blip, keep busy —
        // across any number of applies (watcher kicks must not consume it).
        for gap in [0, 1, 2] {
            XCTAssertEqual(
                d.apply([session("a", .idle)], bucketsSinceAppend: evidence(gap))
                    .first?.status,
                .busy)
        }
        // Quiet for quietBuckets: the idle is real.
        XCTAssertEqual(
            d.apply(
                [session("a", .idle)],
                bucketsSinceAppend: evidence(AgentStatusDebouncer.quietBuckets)
            ).first?.status,
            .idle)
    }

    func testIdleWithNoTranscriptEvidencePassesThrough() {
        var d = AgentStatusDebouncer()
        _ = d.apply([session("a", .busy)], bucketsSinceAppend: evidence(nil))
        // No appended bytes on record: no evidence of work, trust the file.
        XCTAssertEqual(
            d.apply([session("a", .idle)], bucketsSinceAppend: evidence(nil)).first?.status,
            .idle)
    }

    func testWaitingHeldWithPayload() {
        var d = AgentStatusDebouncer()
        _ = d.apply([session("a", .waiting("permission"))], bucketsSinceAppend: evidence(0))
        XCTAssertEqual(
            d.apply([session("a", .idle)], bucketsSinceAppend: evidence(1)).first?.status,
            .waiting("permission"))
        XCTAssertEqual(
            d.apply([session("a", .idle)], bucketsSinceAppend: evidence(9)).first?.status,
            .idle)
    }

    func testIdleWithoutPriorActivePassesThrough() {
        var d = AgentStatusDebouncer()
        // Active transcript alone (e.g. a background task appending) never
        // invents an active status the file didn't report.
        XCTAssertEqual(
            d.apply([session("a", .idle)], bucketsSinceAppend: evidence(0)).first?.status,
            .idle)
    }

    func testReleasedHoldDoesNotRearmOnLaterActivity() {
        var d = AgentStatusDebouncer()
        _ = d.apply([session("a", .busy)], bucketsSinceAppend: evidence(0))
        // Quiet long enough: released.
        _ = d.apply([session("a", .idle)], bucketsSinceAppend: evidence(5))
        // Transcript bytes resume while the file still says idle — stays
        // idle until the file itself reports active again.
        XCTAssertEqual(
            d.apply([session("a", .idle)], bucketsSinceAppend: evidence(0)).first?.status,
            .idle)
        _ = d.apply([session("a", .busy)], bucketsSinceAppend: evidence(0))
        XCTAssertEqual(
            d.apply([session("a", .idle)], bucketsSinceAppend: evidence(0)).first?.status,
            .busy)
    }

    func testUnknownStatusNotHeldAndClearsTheHold() {
        var d = AgentStatusDebouncer()
        _ = d.apply([session("a", .busy)], bucketsSinceAppend: evidence(0))
        // A non-idle, non-active status passes through untouched.
        XCTAssertEqual(
            d.apply([session("a", .unknown("compacting"))], bucketsSinceAppend: evidence(0))
                .first?.status,
            .unknown("compacting"))
        // The busy hold was rebuilt away by that tick, so idle now goes through.
        XCTAssertEqual(
            d.apply([session("a", .idle)], bucketsSinceAppend: evidence(0)).first?.status,
            .idle)
    }

    func testVanishedSessionsPruned() {
        var d = AgentStatusDebouncer()
        _ = d.apply([session("a", .busy)], bucketsSinceAppend: evidence(0))
        _ = d.apply([], bucketsSinceAppend: evidence(0))
        // "a" reappearing idle is not held — its state was pruned.
        XCTAssertEqual(
            d.apply([session("a", .idle)], bucketsSinceAppend: evidence(0)).first?.status,
            .idle)
    }

    func testOutputResorted() {
        var d = AgentStatusDebouncer()
        _ = d.apply([session("a", .busy), session("b", .busy)], bucketsSinceAppend: evidence(0))
        // "a" flips idle but is held busy; both stay in the busy rank.
        let out = d.apply(
            [session("a", .idle), session("b", .waiting(nil))], bucketsSinceAppend: evidence(0))
        XCTAssertEqual(out.map(\.sessionId), ["b", "a"])
        XCTAssertEqual(out.first?.status, .waiting(nil))
        XCTAssertEqual(out.last?.status, .busy)
    }

    func testEvidenceIsPerSession() {
        var d = AgentStatusDebouncer()
        _ = d.apply(
            [session("a", .busy), session("b", .busy)], bucketsSinceAppend: evidence(0))
        let out = d.apply([session("a", .idle), session("b", .idle)]) { id in
            id == "a" ? 0 : 9
        }
        XCTAssertEqual(out.first { $0.sessionId == "a" }?.status, .busy)
        XCTAssertEqual(out.first { $0.sessionId == "b" }?.status, .idle)
    }
}
