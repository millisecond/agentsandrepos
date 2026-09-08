import XCTest

@testable import AgentsAndReposCore

final class NotificationPromptTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testShowsByDefault() {
        XCTAssertTrue(NotificationPrompt.shouldShow(config: AppConfig(), now: t0))
    }

    func testHiddenOnceEnabled() {
        var c = AppConfig()
        c.notificationsEnabled = true
        XCTAssertFalse(NotificationPrompt.shouldShow(config: c, now: t0))
    }

    func testHiddenOnceDismissed() {
        var c = AppConfig()
        c.notificationsPromptDismissed = true
        XCTAssertFalse(NotificationPrompt.shouldShow(config: c, now: t0))
    }

    func testStaysVisibleWithinADayOfFirstShown() {
        var c = AppConfig()
        c.notificationsPromptFirstShownAt = t0
        XCTAssertTrue(
            NotificationPrompt.shouldShow(config: c, now: t0.addingTimeInterval(23 * 3600)))
    }

    func testAgesOutAfterADay() {
        var c = AppConfig()
        c.notificationsPromptFirstShownAt = t0
        XCTAssertFalse(
            NotificationPrompt.shouldShow(config: c, now: t0.addingTimeInterval(25 * 3600)))
    }
}
