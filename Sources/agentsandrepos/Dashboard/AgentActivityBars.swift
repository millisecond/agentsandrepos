import AgentsAndReposCore
import SwiftUI

/// WinAmp-style LED meter: one column per 15s bucket over the last ~4 minutes
/// (oldest left), column height = transcript bytes the agent appended in that
/// bucket, log-scaled. A pure function of `levels` — no timers and no
/// animation clock, so a closed popover costs nothing; the bars advance only
/// when a snapshot actually changes them.
struct AgentActivityBars: View {
    /// 0–15 per bucket, oldest first (`AgentActivityMeter.levels`).
    let levels: [Int]

    private static let rows = 6
    private static let rowGap: CGFloat = 1
    private static let columnGap: CGFloat = 2

    /// Row colors bottom-up: green body, amber shoulder, red peak. Height
    /// already carries the value; the ramp is redundant decoration, kept
    /// identical in light and dark mode by the fixed dark backdrop.
    private static func litColor(row: Int) -> Color {
        switch row {
        case 0...3: return Color(red: 0.20, green: 0.85, blue: 0.30)
        case 4: return Color(red: 1.00, green: 0.75, blue: 0.10)
        default: return Color(red: 1.00, green: 0.30, blue: 0.25)
        }
    }
    private static let unlit = Color.white.opacity(0.08)

    var body: some View {
        Canvas { context, size in
            let n = levels.count
            guard n > 0 else { return }
            let colWidth = (size.width - Self.columnGap * CGFloat(n - 1)) / CGFloat(n)
            let rowHeight =
                (size.height - Self.rowGap * CGFloat(Self.rows - 1)) / CGFloat(Self.rows)
            for (i, level) in levels.enumerated() {
                // Any nonzero level lights at least the bottom LED.
                let lit =
                    level == 0
                    ? 0
                    : max(
                        1,
                        Int(
                            (CGFloat(level) / CGFloat(AgentActivityMeter.maxLevel)
                                * CGFloat(Self.rows)).rounded(.up)))
                let x = CGFloat(i) * (colWidth + Self.columnGap)
                for row in 0..<Self.rows {
                    let y = size.height - CGFloat(row + 1) * rowHeight - CGFloat(row) * Self.rowGap
                    let cell = CGRect(x: x, y: y, width: colWidth, height: rowHeight)
                    context.fill(
                        Path(roundedRect: cell, cornerRadius: 0.5),
                        with: .color(row < lit ? Self.litColor(row: row) : Self.unlit))
                }
            }
        }
        .frame(width: 112, height: 16)
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.55)))
        .accessibilityLabel("Agent activity over the last four minutes")
    }
}
