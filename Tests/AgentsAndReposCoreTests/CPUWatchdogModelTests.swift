import XCTest

@testable import AgentsAndReposCore

final class CPUWatchdogModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// Feeds samples every 30s at a constant CPU fraction, returning the model.
    private func feed(
        _ model: inout CPUWatchdogModel, fraction: Double, seconds: TimeInterval,
        from start: TimeInterval, baseCPU: Double, foreground: Bool = false
    ) -> Double {
        var cpu = baseCPU
        var t = start
        while t <= start + seconds {
            _ = model.record(
                cpuSeconds: cpu, at: t0.addingTimeInterval(t), foreground: foreground)
            t += 30
            cpu += fraction * 30
        }
        return cpu
    }

    /// The caller (PerfMonitor) flags the first sample after the popover
    /// closes as foreground too, since its interval overlapped visible time;
    /// tests mirror that with one extra flagged sample.
    private func closePopover(
        _ model: inout CPUWatchdogModel, at t: TimeInterval, cpu: Double
    ) {
        _ = model.record(
            cpuSeconds: cpu, at: t0.addingTimeInterval(t), foreground: true)
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

    func testForegroundUseNeverTrips() {
        var m = CPUWatchdogModel()
        // Quiet background, then 10 minutes pegged at 100% with the popover
        // open — all of it excluded, so the model never trips.
        var cpu = feed(&m, fraction: 0.01, seconds: 300, from: 0, baseCPU: 0)
        cpu = feed(&m, fraction: 1.0, seconds: 600, from: 330, baseCPU: cpu, foreground: true)
        XCTAssertFalse(m.isHot)
        closePopover(&m, at: 960, cpu: cpu)
        _ = feed(&m, fraction: 0.01, seconds: 300, from: 990, baseCPU: cpu)
        XCTAssertFalse(m.isHot)
        XCTAssertLessThan(m.averageFraction, 0.05)
    }

    func testBackgroundRegressionTripsAcrossForegroundGap() {
        var m = CPUWatchdogModel()
        // Hot in the background before and after a long foreground stretch.
        // Neither background run alone reaches minSpan; excluding the
        // foreground wall time (not just its CPU) stitches them together, so
        // the regression still trips instead of being diluted by the gap.
        var cpu = feed(&m, fraction: 0.35, seconds: 150, from: 0, baseCPU: 0)
        cpu = feed(&m, fraction: 1.0, seconds: 600, from: 180, baseCPU: cpu, foreground: true)
        closePopover(&m, at: 810, cpu: cpu)
        _ = feed(&m, fraction: 0.35, seconds: 180, from: 840, baseCPU: cpu)
        XCTAssertTrue(m.isHot)
        XCTAssertEqual(m.averageFraction, 0.35, accuracy: 0.05)
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
