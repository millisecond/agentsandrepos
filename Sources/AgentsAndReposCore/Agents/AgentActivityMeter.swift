import Foundation

/// Transcript-throughput history for live agent sessions: bytes appended per
/// fixed time bucket, quantized to LED levels for the tile activity bars.
///
/// The signal is free: the agents tick already stats every session's
/// transcript (`TranscriptTaskReader`'s cache), so `record` only diffs the
/// size it is handed against the last one seen and adds the growth to the
/// current bucket. Buckets are keyed by absolute time (epoch/bucketSeconds),
/// so rotation needs no timer — old buckets simply fall out of the window on
/// the next record or read.
public struct AgentActivityMeter: Sendable {
    /// Buckets per session — the number of bars a tile renders.
    public static let bucketCount = 16
    public static let bucketSeconds: TimeInterval = 15
    /// Levels run 0 (dark) through maxLevel (full column).
    public static let maxLevel = 15
    /// Bytes appended within one bucket that peg the column. Log scale below:
    /// a small tool result still registers, a huge one doesn't flatten
    /// everything else.
    public static let fullScaleBytes: Double = 256 * 1024

    private struct Track {
        var lastSize: UInt64
        /// Bytes appended, keyed by absolute bucket index.
        var buckets: [Int64: UInt64] = [:]
    }

    private var tracks: [String: Track] = [:]

    public init() {}

    /// Folds the session's current transcript size into its history. The
    /// first sighting only sets the baseline — an existing multi-MB
    /// transcript is not a burst. A shrink (the file was compacted/rewritten)
    /// resets the baseline without counting negative growth.
    public mutating func record(id: String, transcriptSize: UInt64, at now: Date) {
        let bucket = Self.bucket(at: now)
        var track = tracks[id] ?? Track(lastSize: transcriptSize)
        let delta = transcriptSize > track.lastSize ? transcriptSize - track.lastSize : 0
        track.lastSize = transcriptSize
        if delta > 0 { track.buckets[bucket, default: 0] += delta }
        track.buckets = track.buckets.filter { $0.key > bucket - Int64(Self.bucketCount) }
        tracks[id] = track
    }

    /// Drops history for sessions that no longer exist.
    public mutating func prune(keeping ids: Set<String>) {
        tracks = tracks.filter { ids.contains($0.key) }
    }

    /// Quantized levels for the window ending at `now`, oldest bucket first —
    /// `bucketCount` entries, or `[]` when the whole window is quiet so an
    /// idle agent's tile stays bar-free (and equality-stable as empty buckets
    /// keep rotating).
    ///
    /// The in-progress bucket is capped at a single LED. Its byte count grows
    /// on every transcript write, and each log-scale threshold it crosses
    /// would otherwise change this array — and with it snapshot equality —
    /// several times per bucket, re-rendering the whole dashboard about once
    /// a second per streaming agent. Capped, the array changes once when
    /// activity starts (the tip lights) and once per rotation (the completed
    /// column takes its full height).
    public func levels(id: String, at now: Date) -> [Int] {
        guard let track = tracks[id], !track.buckets.isEmpty else { return [] }
        let newest = Self.bucket(at: now)
        let out = (0..<Self.bucketCount).map { i in
            let bucket = newest - Int64(Self.bucketCount - 1 - i)
            let level = Self.level(forBytes: track.buckets[bucket] ?? 0)
            return bucket == newest ? min(level, 1) : level
        }
        return out.allSatisfy { $0 == 0 } ? [] : out
    }

    /// Log-scale quantization: any growth lights level 1; `fullScaleBytes` in
    /// one bucket (or more) pegs the column at `maxLevel`.
    public static func level(forBytes bytes: UInt64) -> Int {
        guard bytes > 0 else { return 0 }
        let x = log2(Double(bytes)) / log2(fullScaleBytes)
        return min(maxLevel, 1 + Int(x * Double(maxLevel - 1)))
    }

    private static func bucket(at date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / bucketSeconds).rounded(.down))
    }
}
