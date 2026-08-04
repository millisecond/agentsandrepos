import XCTest

@testable import AgentsAndReposCore

/// The UI's "skip no-op publishes" dedupe rests entirely on Snapshot equality.
/// `generatedAt` is stamped fresh on every publish, so if it ever participates
/// in `==` again, every 3s tick re-renders the whole dashboard and idle CPU
/// silently climbs back to ~35% — exactly the regression this guards against.
final class SnapshotEqualityTests: XCTestCase {

    private func snapshot(generatedAt: Date) -> Snapshot {
        Snapshot(
            repos: [], otherAgents: [], ghAvailability: .ok,
            lastFetchAt: Date(timeIntervalSince1970: 100), config: AppConfig(),
            generatedAt: generatedAt)
    }

    func testGeneratedAtDoesNotAffectEquality() {
        let a = snapshot(generatedAt: Date(timeIntervalSince1970: 1))
        let b = snapshot(generatedAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(a, b)
    }

    func testRealChangesStillDiffer() {
        let a = snapshot(generatedAt: Date(timeIntervalSince1970: 1))
        var b = a
        b.lastFetchAt = Date(timeIntervalSince1970: 200)
        XCTAssertNotEqual(a, b)

        var c = a
        c.ghAvailability = .notInstalled
        XCTAssertNotEqual(a, c)

        // Expanding a section must re-publish, or the dashboard won't react.
        var d = a
        d.config.expandedSections = ["repos"]
        XCTAssertNotEqual(a, d)
    }
}
