import AgentsAndReposCore
import SwiftUI

extension Color {
    init(severity: TileSeverity) {
        switch severity {
        case .muted: self = .secondary
        case .ok: self = .green
        case .info: self = .blue
        case .attention: self = .orange
        case .urgent: self = .red
        }
    }
}

/// Square card container: rounded rect with a severity-tinted border and a
/// faint severity wash so state reads at a glance. Height is fixed (not a
/// minimum) so grid rows stay deterministic; tiles that need more room pass
/// a larger value.
struct Tile<Content: View>: View {
    let severity: TileSeverity
    var height: CGFloat = 112
    /// Overrides the severity-derived chrome color (e.g. the shell phase's
    /// teal, which has no TileSeverity of its own).
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        let color = tint ?? Color(severity: severity)
        let muted = tint == nil && severity == .muted
        content
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(muted ? 0.04 : 0.09))
            )
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        color.opacity(muted ? 0.25 : 0.55),
                        lineWidth: 1.5)
            )
    }
}

/// Small pill like "● 3 modified" in a semantic color. `compact` drops the
/// word (the fallback when a full badge row wouldn't fit the tile).
struct CountBadge: View {
    let symbol: String
    let count: Int
    let label: String
    let color: Color
    var compact = false

    var body: some View {
        Text(compact ? "\(symbol)\(count)" : "\(symbol) \(count) \(label)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
            .help("\(count) \(label)")
    }
}

/// Tiny pill next to a branch name: where the branch stands vs main.
/// Green = merged (safe to clean up); unmerged stays muted — every feature
/// branch in progress is unmerged, so it's a fact, not an alert.
struct MergeStateBadge: View {
    let state: BranchMergeState

    var body: some View {
        Text(state.label)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 3)
            .padding(.vertical, 0.5)
            .background(Capsule().fill(color.opacity(0.14)))
            .help(state.help)
    }

    private var color: Color {
        switch state {
        case .mergedRemote: return .green
        case .mergedLocal: return .mint
        case .unmerged: return .secondary
        }
    }
}

/// Replaces MergeStateBadge when the worktree is actually done: merged (or
/// upstream deleted) AND clean AND agent-free. "Merged" states a fact;
/// "pruneable" states the conclusion, so only one shows at a time.
struct PruneableBadge: View {
    /// Which signals fired — shown on hover.
    let help: String

    var body: some View {
        Text("pruneable")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 3)
            .padding(.vertical, 0.5)
            .background(Capsule().fill(Color.green.opacity(0.14)))
            .help(help)
    }
}

/// Corner indicator on repo tiles: CI dot (worst status) + PR count.
struct PRIndicator: View {
    let ci: PullRequest.CIStatus
    let prCount: Int

    var body: some View {
        if prCount > 0 {
            HStack(spacing: 3) {
                if ci != .none {
                    Circle().fill(ciColor).frame(width: 7, height: 7)
                }
                Text("\(prCount)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .help(helpText)
        }
    }

    private var helpText: String {
        let base = "\(prCount) open pull request\(prCount == 1 ? "" : "s")"
        switch ci {
        case .pass: return "\(base) — CI passing"
        case .fail: return "\(base) — CI failing"
        case .pending: return "\(base) — CI running"
        case .none: return base
        }
    }

    private var ciColor: Color {
        switch ci {
        case .pass: return .green
        case .fail: return .red
        // Teal = "in flight, will resolve" — same concept as an agent's
        // shell state, so they share a color.
        case .pending: return .teal
        case .none: return .clear
        }
    }
}

/// One full line per repo-level workflow run (deploys, dispatches — not PR
/// checks): "⟳ Deploy running — ship pricing tiles · main · 2 min. ago".
/// Clicking opens the run on GitHub.
struct ActionsRunRow: View {
    let run: WorkflowRun
    let open: () -> Void

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(runState: run.state))
            Text("\(run.workflowName) \(run.state.rawValue)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color(runState: run.state))
                .lineLimit(1)
                .layoutPriority(1)
            Text("— \(run.title) · \(run.branch)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let date = run.updatedAt {
                Text(Self.relative.localizedString(for: date, relativeTo: Date()))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .help("\(run.workflowName): \(run.title) — \(run.branch) (\(run.event)), click to open")
    }

    private var symbol: String {
        switch run.state {
        case .running: return "arrow.triangle.2.circlepath"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .other: return "minus.circle"
        }
    }
}

extension Color {
    init(runState: WorkflowRun.State) {
        switch runState {
        // Teal for in-flight, matching CI-pending and agent shell state.
        case .running: self = .teal
        case .passed: self = .green
        case .failed: self = .red
        case .other: self = .secondary
        }
    }
}

/// Row of tiny state dots — circles for agents, squares for worktrees.
struct MiniDotRow: View {
    enum DotShape { case circle, square }

    let dots: [TileSeverity]
    var shape: DotShape = .circle
    private let maxDots = 5

    var body: some View {
        if !dots.isEmpty {
            HStack(spacing: 3) {
                ForEach(Array(dots.prefix(maxDots).enumerated()), id: \.offset) { _, sev in
                    dot(Color(severity: sev))
                }
                if dots.count > maxDots {
                    Text("+\(dots.count - maxDots)")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func dot(_ color: Color) -> some View {
        switch shape {
        case .circle:
            Circle().fill(color).frame(width: 5, height: 5)
        case .square:
            RoundedRectangle(cornerRadius: 1.2).fill(color).frame(width: 5, height: 5)
        }
    }
}

/// Whether the dashboard is on screen. Continuous animations must not run
/// while false: the popover's window outlives close, and an offscreen
/// repeat-forever animation keeps the display cycle (and CPU) busy forever.
private struct DashboardLiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var dashboardLive: Bool {
        get { self[DashboardLiveKey.self] }
        set { self[DashboardLiveKey.self] = newValue }
    }
}

/// One of the AgentIcon template images, tinted — the tiles' counterpart of
/// the menu-bar glyph so agent iconography matches everywhere.
struct AgentIconImage: View {
    let image: NSImage
    let color: Color

    var body: some View {
        Image(nsImage: image)
            .renderingMode(.template)
            .foregroundStyle(color)
    }
}

/// Agent glyph for busy agents — "working": the robot's eye bars seesaw
/// between short and tall, echoing the activity bars. Renders static while
/// the dashboard is hidden; the animated leaf is only in the hierarchy while
/// live, so closing the popover tears the animation down and reopening
/// starts it fresh.
struct BusyAgentIcon: View {
    let color: Color
    @Environment(\.dashboardLive) private var live
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if live, !reduceMotion {
            SeesawEyesAgentIcon(color: color)
        } else {
            AgentIconImage(image: AgentIcon.busy, color: color)
        }
    }
}

/// State lives in this leaf so snapshot re-renders don't restart the
/// eye phase. Draws the eyeless head image and overlays two capsules at the
/// exact eye positions (AgentIcon geometry, flipped to SwiftUI's top-left
/// origin), animating their heights in alternation with bottoms pinned.
private struct SeesawEyesAgentIcon: View {
    let color: Color
    @State private var swapped = false

    var body: some View {
        AgentIconImage(image: AgentIcon.eyeless, color: color)
            .overlay {
                eye(centerX: AgentIcon.eyeCentersX[0], tall: swapped)
                eye(centerX: AgentIcon.eyeCentersX[1], tall: !swapped)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    swapped = true
                }
            }
    }

    private func eye(centerX: CGFloat, tall: Bool) -> some View {
        let height = tall ? AgentIcon.eyeTallHeight : AgentIcon.eyeShortHeight
        let bottom = AgentIcon.canvasHeight - AgentIcon.eyeBottomY
        return Capsule()
            .fill(color)
            .frame(width: AgentIcon.eyeWidth, height: height)
            .position(x: centerX, y: bottom - height / 2)
    }
}

/// Small round icon button revealed in a tile's corner on hover.
struct TileHoverButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(4)
                .background(Circle().fill(.thickMaterial))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Eye-slash hover button — one click moves the tile to the Ignored list.
struct TileIgnoreButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        TileHoverButton(symbol: "eye.slash", help: help, action: action)
    }
}

/// Text with a hover-revealed copy icon trailing it. The text itself renders
/// (and clicks) like any other text — no link styling, the row's own click
/// stays in charge — and only the little icon copies. The icon appearing
/// shifts its neighbors slightly; that's confined to the hovered text.
struct CopyHoverText: View {
    let text: String
    let copyValue: String
    var font: Font = .caption2
    var color: Color? = nil
    let copy: (String) -> Void
    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 3) {
            Text(text)
                .font(font)
                .foregroundStyle(color ?? Color.primary)
                .lineLimit(1)
            if hovered || copied {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        copy(copyValue)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1))
                            copied = false
                        }
                    }
                    .help("Copy \"\(copyValue)\"")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

/// Copy hover button that flashes a checkmark after copying, so the click
/// visibly did something even though nothing navigates.
struct TileCopyButton: View {
    let help: String
    let copy: () -> Void
    @State private var copied = false

    var body: some View {
        TileHoverButton(symbol: copied ? "checkmark" : "doc.on.doc", help: help) {
            copy()
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1))
                copied = false
            }
        }
    }
}

/// Compact row in the Ignored section: dimmed name + location, with a
/// one-click restore button.
struct IgnoredRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let restore: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: restore) {
                Image(systemName: "eye")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show again")
        }
        .padding(.vertical, 1)
    }
}

/// One LLM-summary line: previous text (or the truncated raw facts, before the
/// first summary lands) stays visible with a mini spinner while a replacement
/// generates.
struct SummaryLine: View {
    let display: SummaryDisplay
    var font: Font = .caption2
    var lineLimit = 2
    /// Optional leading SF Symbol (e.g. person/sparkle to tell the agent
    /// tile's user and agent lines apart).
    var icon: String?
    @Environment(\.dashboardLive) private var live

    var body: some View {
        if !display.isEmpty {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                Text(display.text ?? "")
                    .font(font)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(lineLimit)
                // The indeterminate spinner is a continuous animation — hide
                // it while the dashboard is offscreen (see DashboardLiveKey).
                if display.isRefreshing, live {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
    }
}

/// Section header inside the dashboard.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .kerning(0.5)
    }
}

/// Section header with a trailing show-all/show-less toggle for sections
/// that truncate to the most recent tiles. The toggle only appears when
/// there's actually overflow to reveal.
struct ExpandableSectionHeader: View {
    let title: String
    let section: DashboardSection
    let totalCount: Int
    let isExpanded: Bool
    let canToggle: Bool
    let actions: DashboardActions

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            SectionHeader(title: title)
            Spacer()
            if canToggle {
                Button(isExpanded ? "Show less" : "Show all \(totalCount)") {
                    actions.setSectionExpanded(section, expanded: !isExpanded)
                }
                .buttonStyle(.borderless)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Muted info row for empty/error states ("No agents running", gh hints).
struct InfoRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }
}
