import XCTest

@testable import AgentsAndReposCore

final class AgentActivityMeterTests: XCTestCase {
    /// Aligned to a bucket boundary so tests reason in whole buckets.
    private let t0 = Date(
        timeIntervalSince1970: 1_000_000 - 1_000_000
            .truncatingRemainder(dividingBy: AgentActivityMeter.bucketSeconds))

    private func at(bucket: Int, offset: TimeInterval = 0) -> Date {
        t0.addingTimeInterval(Double(bucket) * AgentActivityMeter.bucketSeconds + offset)
    }

    // MARK: - Quantization

    func testLevelQuantization() {
        XCTAssertEqual(AgentActivityMeter.level(forBytes: 0), 0)
        XCTAssertEqual(AgentActivityMeter.level(forBytes: 1), 1)
        XCTAssertEqual(
            AgentActivityMeter.level(forBytes: UInt64(AgentActivityMeter.fullScaleBytes)),
            AgentActivityMeter.maxLevel)
        // Beyond full scale stays pegged.
        XCTAssertEqual(
            AgentActivityMeter.level(forBytes: UInt64(AgentActivityMeter.fullScaleBytes) * 100),
            AgentActivityMeter.maxLevel)
        // Log scale: half of full scale loses one level, not half the bar.
        XCTAssertEqual(
            AgentActivityMeter.level(forBytes: UInt64(AgentActivityMeter.fullScaleBytes) / 2),
            AgentActivityMeter.maxLevel - 1)
    }

    func testLevelMonotonicallyNonDecreasing() {
        var last = 0
        for bytes in [UInt64(1), 8, 64, 512, 4096, 32768, 262_144, 1 << 30] {
            let level = AgentActivityMeter.level(forBytes: bytes)
            XCTAssertGreaterThanOrEqual(level, last)
            last = level
        }
    }

    // MARK: - Recording

    func testFirstSightingIsBaselineNotBurst() {
        var m = AgentActivityMeter()
        m.record(id: "a", transcriptSize: 5_000_000, at: at(bucket: 0))
        XCTAssertEqual(m.levels(id: "a", at: at(bucket: 0)), [])
    }

    func testGrowthLandsInCurrentBucketAsCappedTip() {
        var m = AgentActivityMeter()
        m.record(id: "a", transcriptSize: 1000, at: at(bucket: 0))
        m.record(id: "a", transcriptSize: 1000 + 4096, at: at(bucket: 0, offset: 3))
        let levels = m.levels(id: "a", at: at(bucket: 0, offset: 3))
        XCTAssertEqual(levels.count, AgentActivityMeter.bucketCount)
        // In progress: only the single-LED tip, full height comes on rotation.
        XCTAssertEqual(levels.last, 1)
        XCTAssertTrue(levels.dropLast().allSatisfy { $0 == 0 })
        XCTAssertEqual(
            m.levels(id: "a", at: at(bucket: 1))[AgentActivityMeter.bucketCount - 2],
            AgentActivityMeter.level(forBytes: 4096))
    }

    func testGrowthAccumulatesWithinABucket() {
        var m = AgentActivityMeter()
        m.record(id: "a", transcriptSize: 0, at: at(bucket: 0))
        m.record(id: "a", transcriptSize: 2048, at: at(bucket: 0, offset: 3))
        m.record(id: "a", transcriptSize: 4096, at: at(bucket: 0, offset: 6))
        // Accumulation shows once the bucket completes.
        XCTAssertEqual(
            m.levels(id: "a", at: at(bucket: 1))[AgentActivityMeter.bucketCount - 2],
            AgentActivityMeter.level(forBytes: 4096))
    }

    func testStreamingGrowthChangesLevelsOncePerBucket() {
        // The reason for the tip cap: a continuously growing transcript must
        // not perturb the levels array (and thus snapshot equality) on every
        // write — only the first sign of activity and each bucket rotation
        // may change it.
        var m = AgentActivityMeter()
        m.record(id: "a", transcriptSize: 0, at: at(bucket: 0))
        var size: UInt64 = 0
        var seen: [[Int]] = []
        for step in 1...14 {
            size += 16_384
            let t = at(bucket: 0, offset: Double(step))
            m.record(id: "a", transcriptSize: size, at: t)
            let levels = m.levels(id: "a", at: t)
            if levels != seen.last { seen.append(levels) }
        }
        XCTAssertEqual(seen.count, 1)
    }

    func testBucketsSeparateAndSlide() {
        var m = AgentActivityMeter()
        m.record(id: "a", transcriptSize: 0, at: at(bucket: 0))
        m.record(id: "a", transcriptSize: 100, at: at(bucket: 0, offset: 3))
        m.record(id: "a", transcriptSize: 200, at: at(bucket: 1, offset: 3))
        let levels = m.levels(id: "a", at: at(bucket: 1, offset: 3))
        let n = AgentActivityMeter.bucketCount
        XCTAssertEqual(levels[n - 2], AgentActivityMeter.level(forBytes: 100))
        // Current bucket shows the capped tip until it completes.
        XCTAssertEqual(levels[n - 1], 1)
        // Two buckets later the same bursts sit two columns further left.
        let later = m.levels(id: "a", at: at(bucket: 3))
        XCTAssertEqual(later[n - 4], AgentActivityMeter.level(forBytes: 100))
        XCTAssertEqual(later[n - 3], AgentActivityMeter.level(forBytes: 100))
        XCTAssertEqual(later[n - 1], 0)
    }

    func testOldBurstsRollOffTheWindow() {
        var m = AgentActivityMeter()
        m.record(id: "a", transcriptSize: 0, at: at(bucket: 0))
        m.record(id: "a", transcriptSize: 100, at: at(bucket: 0, offset: 3))
        // Once the burst's bucket is outside the window, the strip goes empty.
        XCTAssertEqual(m.levels(id: "a", at: at(bucket: AgentActivityMeter.bucketCount)), [])
    }

    func testShrinkResetsBaselineWithoutNegativeGrowth() {
        var m = AgentActivityMeter()
        m.record(id: "a", transcriptSize: 10_000, at: at(bucket: 0))
        // Compaction rewrote the file smaller.
        m.record(id: "a", transcriptSize: 2_000, at: at(bucket: 0, offset: 3))
        XCTAssertEqual(m.levels(id: "a", at: at(bucket: 0, offset: 3)), [])
        // Growth from the new baseline counts normally (capped tip while the
        // bucket is in progress, full height once it completes).
        m.record(id: "a", transcriptSize: 2_500, at: at(bucket: 0, offset: 6))
        XCTAssertEqual(m.levels(id: "a", at: at(bucket: 0, offset: 6)).last, 1)
        XCTAssertEqual(
            m.levels(id: "a", at: at(bucket: 1))[AgentActivityMeter.bucketCount - 2],
            AgentActivityMeter.level(forBytes: 500))
    }

    func testSessionsAreIndependent() {
        var m = AgentActivityMeter()
        m.record(id: "a", transcriptSize: 0, at: at(bucket: 0))
        m.record(id: "b", transcriptSize: 0, at: at(bucket: 0))
        m.record(id: "a", transcriptSize: 100, at: at(bucket: 0, offset: 3))
        XCTAssertFalse(m.levels(id: "a", at: at(bucket: 0, offset: 3)).isEmpty)
        XCTAssertEqual(m.levels(id: "b", at: at(bucket: 0, offset: 3)), [])
    }

    func testPruneDropsDeadSessions() {
        var m = AgentActivityMeter()
        m.record(id: "a", transcriptSize: 0, at: at(bucket: 0))
        m.record(id: "a", transcriptSize: 100, at: at(bucket: 0, offset: 3))
        m.prune(keeping: ["b"])
        XCTAssertEqual(m.levels(id: "a", at: at(bucket: 0, offset: 3)), [])
        // A re-appearing id starts from a fresh baseline.
        m.record(id: "a", transcriptSize: 9_999, at: at(bucket: 0, offset: 6))
        XCTAssertEqual(m.levels(id: "a", at: at(bucket: 0, offset: 6)), [])
    }

    func testUnknownSessionHasNoLevels() {
        let m = AgentActivityMeter()
        XCTAssertEqual(m.levels(id: "nope", at: at(bucket: 0)), [])
    }
}
