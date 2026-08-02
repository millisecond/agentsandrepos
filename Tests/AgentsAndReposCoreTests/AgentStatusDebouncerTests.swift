import XCTest

@testable import AgentsAndReposCore

final class AgentStatusDebouncerTests: XCTestCase {
    private func session(_ id: String, _ status: AgentSession.Status) -> AgentSession {
        AgentSession(
            pid: 1, sessionId: id, cwd: "/x", name: nil, kind: "interactive",
            status: status, startedAt: nil, updatedAt: nil)
    }

    func testBusyToIdleHeldForOneTickOnly() {
        var d = AgentStatusDebouncer()
        _ = d.apply([session("a", .busy)])
        // First idle right after busy: still shown busy.
        XCTAssertEqual(d.apply([session("a", .idle)]).first?.status, .busy)
        // Second consecutive idle goes through.
        XCTAssertEqual(d.apply([session("a", .idle)]).first?.status, .idle)
    }

    func testWaitingToIdleHeldWithPayload() {
        var d = AgentStatusDebouncer()
        _ = d.apply([session("a", .waiting("permission"))])
        XCTAssertEqual(d.apply([session("a", .idle)]).first?.status, .waiting("permission"))
        XCTAssertEqual(d.apply([session("a", .idle)]).first?.status, .idle)
    }

    func testIdleWithoutPriorActivePassesThrough() {
        var d = AgentStatusDebouncer()
        XCTAssertEqual(d.apply([session("a", .idle)]).first?.status, .idle)
    }

    func testBusyBetweenIdlesRearmsTheHold() {
        var d = AgentStatusDebouncer()
        _ = d.apply([session("a", .busy)])
        _ = d.apply([session("a", .idle)])  // consumed
        _ = d.apply([session("a", .busy)])  // re-armed
        XCTAssertEqual(d.apply([session("a", .idle)]).first?.status, .busy)
    }

    func testUnknownStatusNotHeldAndClearsNothing() {
        var d = AgentStatusDebouncer()
        _ = d.apply([session("a", .busy)])
        // A non-idle, non-active status passes through untouched.
        XCTAssertEqual(
            d.apply([session("a", .unknown("compacting"))]).first?.status,
            .unknown("compacting"))
        // The busy hold was rebuilt away by that tick, so idle now goes through.
        XCTAssertEqual(d.apply([session("a", .idle)]).first?.status, .idle)
    }

    func testVanishedSessionsPruned() {
        var d = AgentStatusDebouncer()
        _ = d.apply([session("a", .busy)])
        _ = d.apply([])
        // "a" reappearing idle is not held — its state was pruned.
        XCTAssertEqual(d.apply([session("a", .idle)]).first?.status, .idle)
    }

    func testOutputResorted() {
        var d = AgentStatusDebouncer()
        _ = d.apply([session("a", .busy), session("b", .busy)])
        // "a" flips idle but is held busy; both stay in the busy rank.
        let out = d.apply([session("a", .idle), session("b", .waiting(nil))])
        XCTAssertEqual(out.map(\.sessionId), ["b", "a"])
        XCTAssertEqual(out.first?.status, .waiting(nil))
        XCTAssertEqual(out.last?.status, .busy)
    }
}
