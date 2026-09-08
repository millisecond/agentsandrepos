import Foundation

/// Which verbosity bucket a scored event lands in. The cutoffs are hand-picked
/// guesses (see `RunSurpriseScorer`); once a few weeks of `notify` log lines
/// exist, set them from the observed score distribution instead.
public enum SurpriseTier: String, Sendable, Equatable, Codable {
    /// Expected. Swallowed — the roundup rule lets one quiet line through
    /// every few events so nothing vanishes forever.
    case normal
    /// Something moved a bit. A quiet notification carrying what moved.
    case unusual
    /// The full alert, with a "since last time" clause saying why.
    case extreme

    public static let unusualThreshold = 1.0
    public static let extremeThreshold = 2.5

    public init(score: Double) {
        if score >= Self.extremeThreshold {
            self = .extreme
        } else if score >= Self.unusualThreshold {
            self = .unusual
        } else {
            self = .normal
        }
    }
}

/// What the planner remembers about one workflow (repo + workflow name) after
/// each finished run — the belief the next run is scored against. Persisted
/// by `BeliefStore` so the app doesn't relearn everything at every launch.
public struct RunBelief: Codable, Equatable, Sendable {
    public var lastState: WorkflowRun.State
    public var lastRunId: Int
    public var lastFinishedAt: Date
    public var observations: Int
    /// Consecutive finished runs sharing `lastState`.
    public var streak: Int
    /// Exponential moving average of the failure indicator (0…1).
    public var failRate: Double
    public var durationMean: Double?
    public var durationVariance: Double
    public var durationSamples: Int
    /// Seconds between consecutive finishes — the "traffic" estimate.
    public var gapMean: Double?
    public var gapVariance: Double
    public var gapSamples: Int
    /// Normal-tier results swallowed since the last line let through.
    public var suppressed: Int

    public init(
        lastState: WorkflowRun.State, lastRunId: Int, lastFinishedAt: Date,
        observations: Int = 1, streak: Int = 1, failRate: Double,
        durationMean: Double? = nil, durationVariance: Double = 0, durationSamples: Int = 0,
        gapMean: Double? = nil, gapVariance: Double = 0, gapSamples: Int = 0,
        suppressed: Int = 0
    ) {
        self.lastState = lastState
        self.lastRunId = lastRunId
        self.lastFinishedAt = lastFinishedAt
        self.observations = observations
        self.streak = streak
        self.failRate = failRate
        self.durationMean = durationMean
        self.durationVariance = durationVariance
        self.durationSamples = durationSamples
        self.gapMean = gapMean
        self.gapVariance = gapVariance
        self.gapSamples = gapSamples
        self.suppressed = suppressed
    }
}

/// How surprising one finished run is against its belief, itemised so the
/// notification can say what moved and the log can feed calibration.
public struct RunSurprise: Equatable, Sendable {
    public struct Component: Equatable, Sendable {
        public let name: String
        public let value: Double
        /// Human clause for the notification subtitle; nil when this
        /// component didn't move enough to be worth a word.
        public let note: String?

        public init(name: String, value: Double, note: String? = nil) {
            self.name = name
            self.value = value
            self.note = note
        }
    }

    public let components: [Component]
    public var score: Double { components.reduce(0) { $0 + $1.value } }
    public var tier: SurpriseTier { SurpriseTier(score: score) }
    /// The "since last time" clause: every component that moved, joined.
    public var clause: String? {
        let notes = components.compactMap(\.note)
        return notes.isEmpty ? nil : notes.joined(separator: ", ")
    }

    public init(components: [Component]) { self.components = components }
}

/// Scores a finished run against the belief, and folds it into the belief.
///
/// Each component adds `log(1 + z)` where `z` is how many standard deviations
/// the observation sits from the belief — a small wobble adds almost nothing,
/// a big jump adds a lot, never absurdly much. Outcome flips (passed ↔ failed)
/// get a flat huge score regardless. No belief yet means everything is news:
/// the score maxes out, so nothing gets quieter until the system has seen a
/// workflow at least once.
public enum RunSurpriseScorer {
    /// EMA weight for all running estimates. 0.2 makes a second consecutive
    /// failure "unusual" (score ≈ 1.1) and a third "normal" (≈ 0.85).
    public static let alpha = 0.2
    /// Flat score for a passed ↔ failed flip — always extreme.
    public static let flipScore = 3.0
    /// Score assigned when there is no belief to compare against.
    public static let firstSightScore = 3.0
    /// Duration/gap components need this many samples before they count.
    public static let minSamples = 3
    /// Ceilings so a slow run or a lull can tip a result over a cutoff but
    /// can't reach "extreme" alone — only flips and first sightings do that.
    public static let durationCap = 2.0
    public static let gapCap = 1.5

    public static func score(run: WorkflowRun, finishedAt: Date, belief: RunBelief?)
        -> RunSurprise
    {
        guard let belief else {
            return RunSurprise(components: [
                .init(
                    name: "first", value: firstSightScore,
                    note: "first \(run.workflowName) run seen")
            ])
        }
        let failed = run.state == .failed
        var parts: [RunSurprise.Component] = []

        let flipped = belief.lastState != run.state
        if flipped {
            let note =
                failed
                ? "first failure after \(count(belief.streak, "pass", "passes"))"
                : "back to green after \(count(belief.streak, "failure", "failures"))"
            parts.append(.init(name: "flip", value: flipScore, note: note))
        }

        // Outcome against the running failure rate (Bernoulli z-score).
        let p = min(max(belief.failRate, 0.02), 0.98)
        let x = failed ? 1.0 : 0.0
        let z = abs(x - p) / (p * (1 - p)).squareRoot()
        let streakNote =
            flipped
            ? nil
            : "\(ordinal(belief.streak + 1)) \(failed ? "failure" : "pass") in a row"
        parts.append(.init(name: "outcome", value: log1p(z), note: streakNote))

        if let d = run.duration, let mean = belief.durationMean,
            belief.durationSamples >= minSamples
        {
            let sd = max(belief.durationVariance.squareRoot(), 0.25 * mean, 60)
            let z = abs(d - mean) / sd
            parts.append(
                .init(
                    name: "duration", value: min(log1p(z), durationCap),
                    note: z >= 1 ? "took \(brief(d)), usually \(brief(mean))" : nil))
        }

        if let mean = belief.gapMean, belief.gapSamples >= minSamples {
            let gap = finishedAt.timeIntervalSince(belief.lastFinishedAt)
            // Only a lull is news ("traffic stopped"); a burst is just work.
            if gap > mean {
                let sd = max(belief.gapVariance.squareRoot(), 0.5 * mean, 3600)
                let z = (gap - mean) / sd
                parts.append(
                    .init(
                        name: "gap", value: min(log1p(z), gapCap),
                        note: z >= 1 ? "first run in \(brief(gap))" : nil))
            }
        }
        return RunSurprise(components: parts)
    }

    /// The belief after seeing this run. `suppressed` is the planner's to
    /// manage and carries over untouched.
    public static func observe(run: WorkflowRun, finishedAt: Date, into belief: RunBelief?)
        -> RunBelief
    {
        let x = run.state == .failed ? 1.0 : 0.0
        guard var b = belief else {
            var fresh = RunBelief(
                lastState: run.state, lastRunId: run.id, lastFinishedAt: finishedAt,
                failRate: x)
            if let d = run.duration {
                (fresh.durationMean, fresh.durationVariance, fresh.durationSamples) =
                    ema(mean: nil, variance: 0, samples: 0, with: d)
            }
            return fresh
        }
        b.streak = b.lastState == run.state ? b.streak + 1 : 1
        b.failRate += alpha * (x - b.failRate)
        if let d = run.duration {
            (b.durationMean, b.durationVariance, b.durationSamples) = ema(
                mean: b.durationMean, variance: b.durationVariance,
                samples: b.durationSamples, with: d)
        }
        let gap = finishedAt.timeIntervalSince(b.lastFinishedAt)
        if gap > 0 {
            (b.gapMean, b.gapVariance, b.gapSamples) = ema(
                mean: b.gapMean, variance: b.gapVariance, samples: b.gapSamples, with: gap)
        }
        b.lastState = run.state
        b.lastRunId = run.id
        b.lastFinishedAt = finishedAt
        b.observations += 1
        return b
    }

    static func ema(mean: Double?, variance: Double, samples: Int, with x: Double)
        -> (Double?, Double, Int)
    {
        guard let mean else { return (x, 0, 1) }
        let delta = x - mean
        return (
            mean + alpha * delta,
            (1 - alpha) * (variance + alpha * delta * delta),
            samples + 1
        )
    }

    // MARK: - Wording

    public static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n) \(n == 1 ? singular : plural)"
    }

    /// "45s", "4m", "1h 5m", "3d".
    public static func brief(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 {
            let m = (s % 3600) / 60
            return m == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(m)m"
        }
        return "\(s / 86400)d"
    }
}
