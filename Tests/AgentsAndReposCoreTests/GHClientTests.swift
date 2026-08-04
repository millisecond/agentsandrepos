import XCTest

@testable import AgentsAndReposCore

final class GHClientTests: XCTestCase {
    func testParsePRList() throws {
        let json = """
            [
              {"number": 12, "title": "Fix onboarding", "url": "https://github.com/o/r/pull/12",
               "isDraft": false, "author": {"login": "millisecond"}, "headRefName": "fix-onboarding",
               "reviewDecision": "APPROVED", "updatedAt": "2026-08-01T10:00:00Z",
               "statusCheckRollup": [
                 {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"},
                 {"__typename": "StatusContext", "state": "SUCCESS"}
               ]},
              {"number": 13, "title": "WIP", "url": "https://github.com/o/r/pull/13",
               "isDraft": true, "author": {"login": "bot"}, "headRefName": "wip",
               "reviewDecision": null,
               "statusCheckRollup": [
                 {"__typename": "CheckRun", "status": "IN_PROGRESS", "conclusion": null}
               ]},
              {"number": 14, "title": "Broken", "url": "https://github.com/o/r/pull/14",
               "isDraft": false, "author": {"login": "x"}, "headRefName": "b",
               "statusCheckRollup": [
                 {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "FAILURE"}
               ]},
              {"number": 15, "title": "No CI", "url": "https://github.com/o/r/pull/15",
               "isDraft": false, "author": {"login": "x"}, "headRefName": "c",
               "statusCheckRollup": []}
            ]
            """
        let prs = try XCTUnwrap(GHClient.parsePRList(Data(json.utf8)))
        XCTAssertEqual(prs.count, 4)
        XCTAssertEqual(prs[0].ci, .pass)
        XCTAssertEqual(prs[0].author, "millisecond")
        XCTAssertEqual(prs[1].ci, .pending)
        XCTAssertTrue(prs[1].isDraft)
        XCTAssertEqual(prs[2].ci, .fail)
        XCTAssertEqual(prs[3].ci, .none)
        XCTAssertEqual(prs[0].updatedAt, Date(timeIntervalSince1970: 1_785_578_400))
        XCTAssertNil(prs[3].updatedAt)
    }

    func testParseGarbage() {
        XCTAssertNil(GHClient.parsePRList(Data("nope".utf8)))
    }
}
