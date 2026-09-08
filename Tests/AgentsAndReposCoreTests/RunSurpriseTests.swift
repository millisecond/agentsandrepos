import XCTest

@testable import AgentsAndReposCore

final class RunSurpriseTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func run(
        id: Int, state: WorkflowRun.State, finishedAt: Date, duration: TimeInterval? = nil
    ) -> WorkflowRun {
        WorkflowRun(
            id: id, workflowName: "CI", title: "t", branch: "main", event: "push",
            state: state, url: "", updatedAt: finishedAt,
            startedAt: duration.map { finishedAt.addingTimeInterval(-$0) })
    }

    /// Feeds `states` in order, one run per `gap` seconds, returning the
    /// belief after all of them and the surprise of the last one.
    private func play(
        _ states: [WorkflowRun.State], gap: TimeInterval = 3600, duration: TimeInterval? = nil
    ) -> (belief: RunBelief, last: RunSurprise) {
        var belief: RunBelief?
        var last = RunSurprise(components: [])
        for (i, state) in states.enumerated() {
            let r = run(
                id: i, state: state, finishedAt: t0.addingTimeInterval(Double(i) * gap),
                duration: duration)
            last = RunSurpriseScorer.score(run: r, finishedAt: r.updatedAt!, belief: belief)
            belief = RunSurpriseScorer.observe(run: r, finishedAt: r.updatedAt!, into: belief)
        }
        return (belief!, last)
    }

    func testFirstSightIsExtremeNews() {
        let (belief, s) = play([.passed])
        XCTAssertEqual(s.tier, .extreme)
        XCTAssertEqual(s.clause, "first CI run seen")
        XCTAssertEqual(belief.observations, 1)
        XCTAssertEqual(belief.streak, 1)
        XCTAssertEqual(belief.failRate, 0)
    }

    func testSteadyPassesDecayToNormal() {
        let (belief, s) = play([.passed, .passed, .passed, .passed])
        XCTAssertEqual(s.tier, .normal)
        XCTAssertLessThan(s.score, 0.3)
        XCTAssertEqual(s.clause, "4th pass in a row")
        XCTAssertEqual(belief.streak, 4)
    }

    func testFlipToFailureIsExtremeWithSinceClause() {
        let (belief, s) = play([.passed, .passed, .passed, .failed])
        XCTAssertEqual(s.tier, .extreme)
        XCTAssertGreaterThanOrEqual(s.score, RunSurpriseScorer.flipScore)
        XCTAssertEqual(s.clause, "first failure after 3 passes")
        XCTAssertEqual(belief.streak, 1)
        XCTAssertEqual(belief.lastState, .failed)
        XCTAssertEqual(belief.failRate, 0.2, accuracy: 1e-9)
    }

    func testRecoveryIsExtreme() {
        let (_, s) = play([.failed, .passed])
        XCTAssertEqual(s.tier, .extreme)
        XCTAssertEqual(s.clause, "back to green after 1 failure")
    }

    func testRepeatedFailuresFadeFromUnusualToNormal() {
        let (_, second) = play([.passed, .passed, .failed, .failed])
        XCTAssertEqual(second.tier, .unusual)
        XCTAssertEqual(second.clause, "2nd failure in a row")
        let (_, third) = play([.passed, .passed, .failed, .failed, .failed])
        XCTAssertEqual(third.tier, .normal)
    }

    func testDurationOutlierMovesTheScore() {
        // Establish a 4-minute norm, then a 20-minute run.
        var belief: RunBelief?
        for i in 0..<4 {
            let r = run(
                id: i, state: .passed, finishedAt: t0.addingTimeInterval(Double(i) * 3600),
                duration: 240)
            belief = RunSurpriseScorer.observe(run: r, finishedAt: r.updatedAt!, into: belief)
        }
        XCTAssertEqual(belief?.durationSamples, 4)
        XCTAssertEqual(belief?.durationMean ?? 0, 240, accuracy: 1e-9)
        // Next run on the usual hourly cadence, five times slower.
        let slow = run(id: 9, state: .passed, finishedAt: t0.addingTimeInterval(4 * 3600),
                       duration: 1200)
        let s = RunSurpriseScorer.score(run: slow, finishedAt: slow.updatedAt!, belief: belief)
        XCTAssertEqual(s.tier, .unusual, "slow alone can't be extreme: \(s.score)")
        XCTAssertEqual(s.clause, "5th pass in a row, took 20m, usually 4m")
        // Same duration as always: the component is present but says nothing.
        let usual = run(id: 10, state: .passed, finishedAt: t0.addingTimeInterval(4 * 3600),
                        duration: 250)
        let q = RunSurpriseScorer.score(run: usual, finishedAt: usual.updatedAt!, belief: belief)
        XCTAssertEqual(q.tier, .normal)
        XCTAssertEqual(q.clause, "5th pass in a row")
    }

    func testDurationNeedsEnoughSamplesBeforeItCounts() {
        let (belief, _) = play([.passed, .passed], duration: 240)
        let slow = run(id: 9, state: .passed, finishedAt: t0.addingTimeInterval(9000),
                       duration: 5000)
        let s = RunSurpriseScorer.score(run: slow, finishedAt: slow.updatedAt!, belief: belief)
        XCTAssertFalse(s.components.contains { $0.name == "duration" })
    }

    func testLongLullIsNotedTrafficStopped() {
        // Hourly cadence for four runs, then nothing for a week.
        let (belief, _) = play([.passed, .passed, .passed, .passed], gap: 3600)
        XCTAssertEqual(belief.gapSamples, 3)
        let late = run(
            id: 9, state: .passed,
            finishedAt: belief.lastFinishedAt.addingTimeInterval(7 * 86400))
        let s = RunSurpriseScorer.score(run: late, finishedAt: late.updatedAt!, belief: belief)
        XCTAssertEqual(s.tier, .unusual, "a lull alone can't be extreme: \(s.score)")
        XCTAssertEqual(s.clause, "5th pass in a row, first run in 7d")
        // Lull plus a slow run does add up to extreme.
        let lateAndSlow = run(
            id: 11, state: .passed,
            finishedAt: belief.lastFinishedAt.addingTimeInterval(7 * 86400), duration: 1200)
        var slowBelief = belief
        for i in 0..<3 {
            let r = run(id: 20 + i, state: .passed, finishedAt: t0.addingTimeInterval(4 * 3600),
                        duration: 240)
            slowBelief = RunSurpriseScorer.observe(run: r, finishedAt: r.updatedAt!, into: slowBelief)
        }
        let both = RunSurpriseScorer.score(
            run: lateAndSlow, finishedAt: lateAndSlow.updatedAt!, belief: slowBelief)
        XCTAssertEqual(both.tier, .extreme)
        // A burst (shorter gap) is just work, not news.
        let soon = run(
            id: 10, state: .passed, finishedAt: belief.lastFinishedAt.addingTimeInterval(60))
        let b = RunSurpriseScorer.score(run: soon, finishedAt: soon.updatedAt!, belief: belief)
        XCTAssertFalse(b.components.contains { $0.name == "gap" })
    }

    func testTierCutoffs() {
        XCTAssertEqual(SurpriseTier(score: 0.99), .normal)
        XCTAssertEqual(SurpriseTier(score: 1.0), .unusual)
        XCTAssertEqual(SurpriseTier(score: 2.49), .unusual)
        XCTAssertEqual(SurpriseTier(score: 2.5), .extreme)
    }

    func testWording() {
        XCTAssertEqual(RunSurpriseScorer.ordinal(1), "1st")
        XCTAssertEqual(RunSurpriseScorer.ordinal(2), "2nd")
        XCTAssertEqual(RunSurpriseScorer.ordinal(3), "3rd")
        XCTAssertEqual(RunSurpriseScorer.ordinal(11), "11th")
        XCTAssertEqual(RunSurpriseScorer.ordinal(12), "12th")
        XCTAssertEqual(RunSurpriseScorer.ordinal(22), "22nd")
        XCTAssertEqual(RunSurpriseScorer.brief(45), "45s")
        XCTAssertEqual(RunSurpriseScorer.brief(240), "4m")
        XCTAssertEqual(RunSurpriseScorer.brief(3900), "1h 5m")
        XCTAssertEqual(RunSurpriseScorer.brief(7200), "2h")
        XCTAssertEqual(RunSurpriseScorer.brief(3 * 86400), "3d")
    }

    func testBeliefStoreRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("beliefs-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("notification-beliefs.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(BeliefStore.load(from: url), [:])
        let (belief, _) = play([.passed, .failed, .failed], duration: 300)
        BeliefStore.save(["o/r#CI": belief], to: url)
        XCTAssertEqual(BeliefStore.load(from: url), ["o/r#CI": belief])
        // Corrupt file: empty, not a crash.
        try Data("nope".utf8).write(to: url)
        XCTAssertEqual(BeliefStore.load(from: url), [:])
    }
}
