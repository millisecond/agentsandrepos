import XCTest

@testable import AgentsAndReposCore

final class ConfigTests: XCTestCase {
    func testDefaults() {
        let c = AppConfig()
        XCTAssertEqual(c.roots, ["~/Projects"])
        XCTAssertEqual(c.prScope, .mine)
        XCTAssertFalse(c.autoFastForward)
        XCTAssertTrue(c.fetchEnabled)
        XCTAssertFalse(c.notificationsEnabled)
        XCTAssertTrue(c.notifyGitActions)
        XCTAssertTrue(c.notifyWaitingAgents)
        XCTAssertFalse(c.notificationsPromptDismissed)
        XCTAssertNil(c.notificationsPromptFirstShownAt)
    }

    func testLenientDecodeEmptyObject() throws {
        let c = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(c, AppConfig())
    }

    func testLenientDecodeBadTypes() throws {
        let json = """
            {"roots": ["~/Code"], "scanDepth": "not-a-number", "prScope": "all"}
            """
        let c = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.roots, ["~/Code"])
        XCTAssertEqual(c.scanDepth, AppConfig().scanDepth)
        XCTAssertEqual(c.prScope, .all)
    }

    func testRoundTrip() throws {
        var c = AppConfig()
        c.roots = ["~/Projects", "~/Work"]
        c.autoFastForward = true
        c.prScope = .all
        c.ignoredRepos = ["/p/hidden"]
        c.ignoredAgents = ["session-1"]
        c.expandedSections = ["repos"]
        c.notificationsEnabled = true
        c.notifyGitActions = false
        c.notificationsPromptDismissed = true
        c.notificationsPromptFirstShownAt = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(back, c)
        XCTAssertTrue(back.isSectionExpanded(.repos))
        XCTAssertFalse(back.isSectionExpanded(.prs))
    }

    /// Keys from the removed stale auto-hide feature must not break decoding.
    func testLegacyStaleKeysIgnored() throws {
        let json = """
            {"autoHideStaleDays": 30, "staleExemptRepos": ["/p/x"]}
            """
        let c = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c, AppConfig())
    }

    func testStoreCreatesDefaultFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-test-\(UUID().uuidString)/config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let c = ConfigStore.load(from: url)
        XCTAssertEqual(c, AppConfig())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
