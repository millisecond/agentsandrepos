import XCTest

@testable import AgentsAndReposCore

final class DemoTimelineTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testSnapshotIsDeterministic() {
        for tick in [0, 17, DemoTimeline.menuSceneStart, 63, DemoTimeline.totalTicks - 1] {
            XCTAssertEqual(
                DemoTimeline.snapshot(tick: tick, now: now),
                DemoTimeline.snapshot(tick: tick, now: now),
                "tick \(tick) not reproducible")
        }
    }

    /// Snapshot.== drives SnapshotStore's publish dedupe; two equal
    /// consecutive frames would freeze the recorded animation on that tick.
    /// The wrap pair (last → 0) matters too — the timeline loops.
    func testConsecutiveTicksNeverEqual() {
        for tick in 0..<DemoTimeline.totalTicks {
            let a = DemoTimeline.snapshot(tick: tick, now: now)
            let b = DemoTimeline.snapshot(tick: (tick + 1) % DemoTimeline.totalTicks, now: now)
            XCTAssertNotEqual(a, b, "ticks \(tick) and \(tick + 1) are equal — publish would be dropped")
        }
    }

    func testActivityLevelsStayInLEDRange() {
        for tick in 0..<DemoTimeline.totalTicks {
            let snap = DemoTimeline.snapshot(tick: tick, now: now)
            XCTAssertFalse(snap.repos.isEmpty)
            for agent in snap.allAgents {
                XCTAssertTrue(
                    agent.activity.allSatisfy { (0...15).contains($0) },
                    "tick \(tick): activity out of LED range")
                XCTAssertTrue(
                    agent.activity.isEmpty
                        || agent.activity.count == AgentActivityMeter.bucketCount,
                    "tick \(tick): partial LED strip")
            }
        }
    }

    /// The cursor choreography aims at the featured repo's row; it must sit
    /// at rank 0 for the entire menu scene or the target moves mid-shot.
    /// Checked at render-time drift too — the dashboard ranks with Date(),
    /// which runs up to ~a minute past the frozen snapshot dates.
    func testFeaturedRepoRanksFirstThroughMenuScene() {
        let wantedID = "repo:" + DemoTimeline.featuredRepoPath
        for tick in DemoTimeline.menuSceneStart..<DemoTimeline.menuSceneEnd {
            let snap = DemoTimeline.snapshot(tick: tick, now: now)
            for drift: TimeInterval in [0, 60] {
                let ranked = snap.rankedTiles(now: now.addingTimeInterval(drift))
                XCTAssertEqual(
                    ranked.first?.id, wantedID,
                    "tick \(tick) drift \(drift): featured repo not ranked first")
            }
        }
    }

    /// The menubar badge derives from these counts (waiting > busy > error >
    /// idle); each scene must produce its intended badge.
    func testScenesDriveTheIntendedMenubarState() {
        let opening = DemoTimeline.snapshot(tick: 0, now: now)
        XCTAssertEqual(opening.visibleAgents.filter { $0.status.isBusy }.count, 2)
        XCTAssertFalse(opening.visibleAgents.contains { $0.status.isWaiting })
        XCTAssertTrue(opening.visibleRepos.allSatisfy { !$0.hasError })

        let attention = DemoTimeline.snapshot(tick: DemoTimeline.attentionStart, now: now)
        XCTAssertTrue(attention.visibleAgents.contains { $0.status.isWaiting })

        let breakage = DemoTimeline.snapshot(tick: DemoTimeline.breakageStart, now: now)
        XCTAssertFalse(breakage.visibleAgents.contains { $0.status.isBusy || $0.status.isWaiting })
        XCTAssertFalse(breakage.visibleRepos.filter(\.hasError).isEmpty)

        let calm = DemoTimeline.snapshot(tick: DemoTimeline.totalTicks - 1, now: now)
        XCTAssertFalse(calm.visibleAgents.contains { $0.status.isActive })
        XCTAssertTrue(calm.visibleRepos.allSatisfy { !$0.hasError })
    }
}
