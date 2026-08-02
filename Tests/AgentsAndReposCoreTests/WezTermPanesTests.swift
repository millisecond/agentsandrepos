import XCTest

@testable import AgentsAndReposCore

final class WezTermPanesTests: XCTestCase {

    // Trimmed real-shape output of `wezterm cli list --format json`; extra
    // keys must be ignored, tty_name may be absent (e.g. multiplexer panes).
    let json = """
        [
          {"window_id": 0, "tab_id": 0, "pane_id": 0, "workspace": "default",
           "size": {"rows": 24, "cols": 80}, "title": "zsh", "tty_name": "/dev/ttys009"},
          {"window_id": 0, "tab_id": 1, "pane_id": 3, "workspace": "default",
           "title": "claude", "tty_name": "/dev/ttys014"},
          {"window_id": 1, "tab_id": 2, "pane_id": 5, "workspace": "default",
           "title": "remote"}
        ]
        """

    func testPaneMatchByTTY() {
        let pane = WezTermPanes.pane(matchingTTY: "/dev/ttys014", inListJSON: Data(json.utf8))
        XCTAssertEqual(pane, WezTermPanes.Pane(paneId: 3, tabId: 1, windowId: 0, tty: "/dev/ttys014"))
    }

    func testNoMatchAndBadInputReturnNil() {
        XCTAssertNil(WezTermPanes.pane(matchingTTY: "/dev/ttys099", inListJSON: Data(json.utf8)))
        XCTAssertNil(WezTermPanes.pane(matchingTTY: "/dev/ttys014", inListJSON: Data("not json".utf8)))
        XCTAssertNil(WezTermPanes.pane(matchingTTY: "/dev/ttys014", inListJSON: Data()))
    }
}
