import AgentsAndReposCore
import SwiftUI

/// Sparkline of recent agent throughput: one slim bar per 10s bucket over the
/// last ~2.5 minutes (oldest left), bar height = transcript bytes the agent
/// appended in that bucket, log-scaled. Drawn in the tile's severity tint so
/// it reads as part of the status line rather than a foreign widget; empty
/// buckets keep a faint stub, and a fully quiet window renders as a flat row
/// of stubs — every tile carries the strip, so nothing pops in and out.
/// A pure function of `levels` — no timers and no animation clock, so a
/// closed popover costs nothing; the bars advance only when a snapshot
/// actually changes them.
struct AgentActivityBars: View {
    /// 0–15 per bucket, oldest first (`AgentActivityMeter.levels`); empty
    /// means the whole window is quiet and draws as all stubs.
    let levels: [Int]
    /// Severity tint of the enclosing tile — matches the status label.
    let color: Color

    private static let columnGap: CGFloat = 1.5
    /// Any nonzero level gets at least this height so a small tool result
    /// still registers.
    private static let minBarHeight: CGFloat = 3
    private static let stubHeight: CGFloat = 1.5

    var body: some View {
        Canvas { context, size in
            let bars =
                levels.isEmpty
                ? [Int](repeating: 0, count: AgentActivityMeter.bucketCount)
                : levels
            let n = bars.count
            let colWidth = (size.width - Self.columnGap * CGFloat(n - 1)) / CGFloat(n)
            for (i, level) in bars.enumerated() {
                let fraction = CGFloat(level) / CGFloat(AgentActivityMeter.maxLevel)
                let height =
                    level == 0
                    ? Self.stubHeight
                    : max(Self.minBarHeight, fraction * size.height)
                let bar = CGRect(
                    x: CGFloat(i) * (colWidth + Self.columnGap),
                    y: size.height - height,
                    width: colWidth,
                    height: height)
                context.fill(
                    Path(roundedRect: bar, cornerRadius: min(colWidth, height) / 2),
                    with: .color(level == 0 ? Color.primary.opacity(0.12) : color.opacity(0.85)))
            }
        }
        .frame(width: 64, height: 12)
        .accessibilityLabel("Agent activity over the last few minutes")
    }
}
