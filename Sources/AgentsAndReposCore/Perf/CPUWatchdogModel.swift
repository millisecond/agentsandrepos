import Foundation

/// Pure hot/not-hot decision over cumulative CPU-time samples, so the app can
/// warn when it is burning CPU in the background (the 35%-for-a-day failure
/// mode). The caller feeds process-lifetime CPU seconds at a fixed cadence;
/// the model averages over a rolling window with hysteresis so momentary
/// spikes (launch discovery, summary generation) never trip it and a tripped
/// warning doesn't flicker at the boundary.
///
/// Samples flagged `foreground` (the user has the dashboard open, so rendering
/// and summary work are expected) are excluded entirely: both the CPU and the
/// wall time of the interval they cover are dropped from the series, so the
/// average judges background behavior only rather than being diluted or
/// inflated by interactive use.
public struct CPUWatchdogModel: Sendable, Equatable {
    public struct Sample: Sendable, Equatable {
        public var time: Date
        public var cpuSeconds: Double
        public init(time: Date, cpuSeconds: Double) {
            self.time = time
            self.cpuSeconds = cpuSeconds
        }
    }

    /// Sustained window averages at or above this fraction of a core trip
    /// the warning (0.15 = 15%).
    public var warnFraction: Double
    /// Averages below this clear it.
    public var clearFraction: Double
    /// Rolling window the average is taken over.
    public var window: TimeInterval
    /// No judgement until this much history exists — a busy first few minutes
    /// after launch is not "sustained".
    public var minSpan: TimeInterval

    private var samples: [Sample] = []
    /// Last raw reading, kept even for excluded samples so the next interval's
    /// exclusion is measured from the true previous point.
    private var lastRaw: Sample?
    /// Cumulative wall time / CPU dropped from the series by foreground
    /// intervals; subtracted to map raw readings into the virtual
    /// background-only timeline the window logic runs on.
    private var excludedTime: TimeInterval = 0
    private var excludedCPU: Double = 0
    public private(set) var isHot = false
    /// Average CPU fraction over the current window (0.35 = 35% of one core).
    public private(set) var averageFraction: Double = 0

    public init(
        warnFraction: Double = 0.15, clearFraction: Double = 0.08,
        window: TimeInterval = 300, minSpan: TimeInterval = 240
    ) {
        self.warnFraction = warnFraction
        self.clearFraction = clearFraction
        self.window = window
        self.minSpan = minSpan
    }

    /// Feed one cumulative CPU-seconds reading; returns the updated hot state.
    /// `foreground` marks a reading whose interval (since the previous reading)
    /// overlapped interactive use — that interval is excluded from judgement.
    @discardableResult
    public mutating func record(
        cpuSeconds: Double, at now: Date, foreground: Bool = false
    ) -> Bool {
        let prev = lastRaw
        lastRaw = Sample(time: now, cpuSeconds: cpuSeconds)
        if foreground {
            if let prev {
                excludedTime += max(0, now.timeIntervalSince(prev.time))
                excludedCPU += max(0, cpuSeconds - prev.cpuSeconds)
            }
            return isHot
        }
        let virtualNow = now.addingTimeInterval(-excludedTime)
        samples.append(Sample(time: virtualNow, cpuSeconds: cpuSeconds - excludedCPU))
        // Keep the newest sample at or beyond the window edge as the baseline,
        // so the measured span always covers the full window.
        let cutoff = virtualNow.addingTimeInterval(-window)
        while samples.count > 2, samples[1].time <= cutoff {
            samples.removeFirst()
        }
        guard let first = samples.first, let last = samples.last,
            last.time.timeIntervalSince(first.time) >= minSpan
        else {
            averageFraction = 0
            return isHot
        }
        let span = last.time.timeIntervalSince(first.time)
        averageFraction = max(0, (last.cpuSeconds - first.cpuSeconds) / span)
        if isHot {
            if averageFraction < clearFraction { isHot = false }
        } else if averageFraction >= warnFraction {
            isHot = true
        }
        return isHot
    }
}
