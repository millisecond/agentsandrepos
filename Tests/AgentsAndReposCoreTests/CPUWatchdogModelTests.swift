import XCTest

@testable import AgentsAndReposCore

final class CPUWatchdogModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// Feeds samples every 30s at a constant CPU fraction, returning the model.
    private func feed(
        _ model: inout CPUWatchdogModel, fraction: Double, seconds: TimeInterval,
        from start: TimeInterval, baseCPU: Double
    ) -> Double {
        var cpu = baseCPU
        var t = start
        while t <= start + seconds {
            _ = model.record(cpuSeconds: cpu, at: t0.addingTimeInterval(t))
            t += 30
            cpu += fraction * 30
        }
        return cpu
    }

    func testNoJudgementBeforeMinSpan() {
        var m = CPUWatchdogModel()
        // 100% CPU for 3 minutes — under minSpan, must not trip.
        _ = feed(&m, fraction: 1.0, seconds: 180, from: 0, baseCPU: 0)
        XCTAssertFalse(m.isHot)
        XCTAssertEqual(m.averageFraction, 0)
    }

    func testSustainedHighTripsAndReportsAverage() {
        var m = CPUWatchdogModel()
        _ = feed(&m, fraction: 0.35, seconds: 300, from: 0, baseCPU: 0)
        XCTAssertTrue(m.isHot)
        XCTAssertEqual(m.averageFraction, 0.35, accuracy: 0.02)
    }

    func testQuietProcessNeverTrips() {
        var m = CPUWatchdogModel()
        _ = feed(&m, fraction: 0.01, seconds: 900, from: 0, baseCPU: 0)
        XCTAssertFalse(m.isHot)
    }

    func testLaunchBurstRollsOutOfWindow() {
        var m = CPUWatchdogModel()
        // A hard 1-minute burst at launch, then idle. The burst alone is under
        // the 5m-average threshold, and it ages out entirely.
        var cpu = feed(&m, fraction: 1.0, seconds: 60, from: 0, baseCPU: 0)
        cpu = feed(&m, fraction: 0.01, seconds: 600, from: 90, baseCPU: cpu)
        XCTAssertFalse(m.isHot)
        XCTAssertLessThan(m.averageFraction, 0.05)
    }

    func testHysteresisHoldsUntilClearThreshold() {
        var m = CPUWatchdogModel()
        var cpu = feed(&m, fraction: 0.5, seconds: 300, from: 0, baseCPU: 0)
        XCTAssertTrue(m.isHot)
        // Drop to 10% — between clear (8%) and warn (15%): stays hot while the
        // window average decays, since the average includes the hot stretch.
        cpu = feed(&m, fraction: 0.10, seconds: 120, from: 330, baseCPU: cpu)
        XCTAssertTrue(m.isHot)
        // Long quiet stretch pushes the average below the clear threshold.
        _ = feed(&m, fraction: 0.01, seconds: 600, from: 480, baseCPU: cpu)
        XCTAssertFalse(m.isHot)
    }
}
