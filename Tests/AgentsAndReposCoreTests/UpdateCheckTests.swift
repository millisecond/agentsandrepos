import XCTest

@testable import AgentsAndReposCore

final class UpdateCheckTests: XCTestCase {
    func testVersionFromTag() {
        XCTAssertEqual(UpdateCheck.version(fromTag: "v0.2.0"), "0.2.0")
        XCTAssertEqual(UpdateCheck.version(fromTag: "V1.0"), "1.0")
        XCTAssertEqual(UpdateCheck.version(fromTag: "0.2.0"), "0.2.0")
        XCTAssertEqual(UpdateCheck.version(fromTag: " v0.2.0 "), "0.2.0")
        XCTAssertNil(UpdateCheck.version(fromTag: "latest"))
        XCTAssertNil(UpdateCheck.version(fromTag: ""))
    }

    func testIsNewer() {
        XCTAssertTrue(UpdateCheck.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0.0", than: "0.9.9"))
        XCTAssertTrue(UpdateCheck.isNewer("0.1.10", than: "0.1.9"))
        XCTAssertTrue(UpdateCheck.isNewer("0.1.0.1", than: "0.1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.0", than: "0.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1", than: "0.1.0"))
        // Pre-release suffixes compare equal to their base.
        XCTAssertFalse(UpdateCheck.isNewer("0.1.0-beta1", than: "0.1.0"))
        XCTAssertTrue(UpdateCheck.isNewer("0.2.0-beta1", than: "0.1.0"))
    }

    func testLatestReleaseURLCarriesInstallID() {
        let url = UpdateCheck.latestReleaseURL(installID: "ABC-123")
        XCTAssertEqual(
            url.absoluteString,
            "https://api.agentsandrepos.com/v1/releases/latest?install_id=ABC-123")
    }

    func testAvailableUpdateFromJSON() {
        let newer = Data(#"{"tag_name": "v0.2.0", "name": "0.2.0"}"#.utf8)
        XCTAssertEqual(
            UpdateCheck.availableUpdate(fromReleaseJSON: newer, current: "0.1.0"), "0.2.0")

        let same = Data(#"{"tag_name": "v0.1.0"}"#.utf8)
        XCTAssertNil(UpdateCheck.availableUpdate(fromReleaseJSON: same, current: "0.1.0"))

        let notFound = Data(#"{"message": "Not Found"}"#.utf8)
        XCTAssertNil(UpdateCheck.availableUpdate(fromReleaseJSON: notFound, current: "0.1.0"))

        XCTAssertNil(UpdateCheck.availableUpdate(fromReleaseJSON: Data(), current: "0.1.0"))
    }
}
