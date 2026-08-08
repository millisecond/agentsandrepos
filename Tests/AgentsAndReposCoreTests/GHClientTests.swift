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
                 {"__typename": "CheckRun", "name": "PR Check", "status": "COMPLETED", "conclusion": "FAILURE"},
                 {"__typename": "StatusContext", "context": "ci/lint", "state": "FAILURE"},
                 {"__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS"}
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
        XCTAssertEqual(prs[2].failingChecks, ["PR Check", "ci/lint"])
        XCTAssertEqual(prs[0].failingChecks, [])
        XCTAssertEqual(prs[3].ci, .none)
        XCTAssertEqual(prs[0].updatedAt, Date(timeIntervalSince1970: 1_785_578_400))
        XCTAssertNil(prs[3].updatedAt)
    }

    func testParseGarbage() {
        XCTAssertNil(GHClient.parsePRList(Data("nope".utf8)))
    }

    func testParseRunList() throws {
        let now = try XCTUnwrap(try? Date("2026-08-07T12:00:00Z", strategy: .iso8601))
        let json = """
            [
              {"databaseId": 1, "workflowName": "Deploy", "displayTitle": "ship it",
               "status": "in_progress", "conclusion": null, "headBranch": "main",
               "event": "push", "url": "https://github.com/o/r/actions/runs/1",
               "updatedAt": "2026-08-07T11:59:00Z"},
              {"databaseId": 2, "workflowName": "Deploy", "displayTitle": "older",
               "status": "completed", "conclusion": "success", "headBranch": "main",
               "event": "push", "url": "https://github.com/o/r/actions/runs/2",
               "updatedAt": "2026-08-07T11:30:00Z"},
              {"databaseId": 3, "workflowName": "PR Check", "displayTitle": "pr",
               "status": "in_progress", "conclusion": null, "headBranch": "feature",
               "event": "pull_request", "url": "https://github.com/o/r/actions/runs/3",
               "updatedAt": "2026-08-07T11:59:00Z"},
              {"databaseId": 6, "workflowName": "Labeler", "displayTitle": "label",
               "status": "completed", "conclusion": "success", "headBranch": "feature",
               "event": "pull_request_target", "url": "https://github.com/o/r/actions/runs/6",
               "updatedAt": "2026-08-07T11:59:00Z"},
              {"databaseId": 4, "workflowName": "Nightly", "displayTitle": "cron",
               "status": "completed", "conclusion": "failure", "headBranch": "main",
               "event": "schedule", "url": "https://github.com/o/r/actions/runs/4",
               "updatedAt": "2026-08-07T11:45:00Z"},
              {"databaseId": 5, "workflowName": "Stale", "displayTitle": "old",
               "status": "completed", "conclusion": "success", "headBranch": "main",
               "event": "push", "url": "https://github.com/o/r/actions/runs/5",
               "updatedAt": "2026-08-07T09:00:00Z"}
            ]
            """
        let runs = try XCTUnwrap(GHClient.parseRunList(Data(json.utf8), now: now))
        // Run 2 deduped (same workflow as 1), run 3 is a PR event, run 5 aged out.
        XCTAssertEqual(runs.map(\.id), [1, 4])
        XCTAssertEqual(runs[0].state, .running)
        XCTAssertEqual(runs[0].workflowName, "Deploy")
        XCTAssertEqual(runs[1].state, .failed)
    }

    func testParseRunListGarbage() {
        XCTAssertNil(GHClient.parseRunList(Data("nope".utf8), now: Date()))
    }

    func testReduceRun() {
        XCTAssertEqual(GHClient.reduceRun(status: "queued", conclusion: nil), .running)
        XCTAssertEqual(GHClient.reduceRun(status: "in_progress", conclusion: nil), .running)
        XCTAssertEqual(GHClient.reduceRun(status: "completed", conclusion: "success"), .passed)
        XCTAssertEqual(GHClient.reduceRun(status: "completed", conclusion: "failure"), .failed)
        XCTAssertEqual(GHClient.reduceRun(status: "completed", conclusion: "timed_out"), .failed)
        XCTAssertEqual(GHClient.reduceRun(status: "completed", conclusion: "cancelled"), .other)
        XCTAssertEqual(GHClient.reduceRun(status: "completed", conclusion: "skipped"), .other)
    }

    func testWorstRunState() {
        func run(_ state: WorkflowRun.State, id: Int = 1) -> WorkflowRun {
            WorkflowRun(
                id: id, workflowName: "w", title: "t", branch: "main", event: "push",
                state: state, url: "u")
        }
        XCTAssertNil(WorkflowRun.worstState(of: []))
        XCTAssertEqual(WorkflowRun.worstState(of: [run(.passed), run(.failed)]), .failed)
        XCTAssertEqual(WorkflowRun.worstState(of: [run(.passed), run(.running)]), .running)
        XCTAssertEqual(WorkflowRun.worstState(of: [run(.other), run(.passed)]), .passed)
        XCTAssertEqual(WorkflowRun.worstState(of: [run(.other)]), .other)
    }
}
