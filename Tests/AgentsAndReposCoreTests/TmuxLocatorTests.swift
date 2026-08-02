import XCTest

@testable import AgentsAndReposCore

final class TmuxLocatorTests: XCTestCase {

    let paneOutput = """
        %0\t@0\t/dev/ttys004\tmain
        %3\t@1\t/dev/ttys012\twork session
        %4\t@1\t/dev/ttys013\twork session
        """

    func testPaneMatchByTTY() {
        let pane = TmuxLocator.pane(matchingTTY: "/dev/ttys012", inListOutput: paneOutput)
        XCTAssertEqual(
            pane,
            TmuxLocator.Pane(
                paneId: "%3", windowId: "@1", tty: "/dev/ttys012",
                sessionName: "work session"))
    }

    func testPaneNoMatchReturnsNil() {
        XCTAssertNil(TmuxLocator.pane(matchingTTY: "/dev/ttys099", inListOutput: paneOutput))
        XCTAssertNil(TmuxLocator.pane(matchingTTY: "/dev/ttys012", inListOutput: ""))
    }

    func testSessionNameContainingTabSurvives() {
        // Session name is the last field, so an embedded separator stays in it.
        let out = "%1\t@0\t/dev/ttys005\todd\tname"
        let pane = TmuxLocator.pane(matchingTTY: "/dev/ttys005", inListOutput: out)
        XCTAssertEqual(pane?.sessionName, "odd\tname")
    }

    func testClientsParsing() {
        let out = """
            /dev/ttys003\t8121\tmain
            /dev/ttys007\t9040\twork session
            garbage line
            /dev/ttys008\tnotapid\tmain
            """
        let clients = TmuxLocator.clients(fromListOutput: out)
        XCTAssertEqual(
            clients,
            [
                TmuxLocator.Client(tty: "/dev/ttys003", pid: 8121, sessionName: "main"),
                TmuxLocator.Client(tty: "/dev/ttys007", pid: 9040, sessionName: "work session"),
            ])
    }

    func testBestClientPrefersAttachedSession() {
        let clients = [
            TmuxLocator.Client(tty: "/dev/ttys003", pid: 8121, sessionName: "main"),
            TmuxLocator.Client(tty: "/dev/ttys007", pid: 9040, sessionName: "work"),
        ]
        XCTAssertEqual(
            TmuxLocator.bestClient(forSession: "work", in: clients)?.tty, "/dev/ttys007")
        // No client on the target session: any client (caller switches it).
        XCTAssertEqual(
            TmuxLocator.bestClient(forSession: "other", in: clients)?.tty, "/dev/ttys003")
        XCTAssertNil(TmuxLocator.bestClient(forSession: "work", in: []))
    }
}
