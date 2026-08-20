import AgentsAndReposCore
import SwiftUI

/// Full-width row for the ranked feed — one item per line so the eye scans
/// straight down instead of zig-zagging a grid. Severity reads from the
/// leading icon and border tint, details compress into two lines.
struct RankedRowView: View {
    let item: RankedTile
    var summary: SummaryDisplay = SummaryDisplay()
    let actions: DashboardActions

    var body: some View {
        switch item {
        case .repo(let state):
            RepoRowView(state: state, summary: summary, actions: actions)
        case .pr(let state):
            PRRowView(state: state, actions: actions)
        }
    }
}

/// Which family a row belongs to. Agent rows get heavier chrome (a solid
/// leading accent bar, stronger wash and stroke) so the top section reads
/// as "live things" and the ranked feed below as "things to look at" even
/// when both carry the same severity color.
enum RowChromeStyle {
    case ranked
    case agent
}

/// Shared row chrome: severity-tinted rounded border, hover tracking.
struct RowChrome: ViewModifier {
    let severity: TileSeverity
    /// Overrides the severity-derived chrome color (e.g. an agent shell
    /// phase's teal, which has no TileSeverity of its own).
    var tint: Color? = nil
    var style: RowChromeStyle = .ranked

    func body(content: Content) -> some View {
        let color = tint ?? Color(severity: severity)
        let muted = tint == nil && severity == .muted
        let agent = style == .agent
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        content
            .padding(.horizontal, 9)
            .padding(.leading, agent ? 4 : 0)
            // Agent rows run tighter: the wide layout already carries two
            // summary lines, so tall padding just spreads the live section.
            .padding(.vertical, agent ? 6 : 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(color.opacity(muted ? 0.04 : agent ? 0.13 : 0.09)))
            .background(shape.fill(.quaternary.opacity(0.35)))
            .overlay(alignment: .leading) {
                if agent {
                    color.opacity(muted ? 0.5 : 0.9).frame(width: 4)
                }
            }
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    color.opacity(muted ? 0.25 : agent ? 0.7 : 0.55),
                    lineWidth: 1.5)
            )
    }
}

/// What kind of thing a ranked row is, told apart by the *shape* around the
/// leading glyph rather than by color (color is spent on severity): a bare
/// folder for a repo, a rounded square for a worktree, a circle for a PR.
enum RowKind {
    case repo
    case worktree
    case pr

    var symbol: String {
        switch self {
        case .repo: return "folder"
        case .worktree: return "arrow.triangle.branch"
        case .pr: return "arrow.triangle.pull"
        }
    }

    var help: String {
        switch self {
        case .repo: return "Repository"
        case .worktree: return "Linked worktree"
        case .pr: return "Pull request"
        }
    }
}

struct RowKindIcon: View {
    let kind: RowKind
    let color: Color
    /// CI or a workflow run is in flight on this row: the outline itself
    /// becomes the spinner (a teal segment orbiting the kind shape). Repos
    /// draw a bare folder — no outline to spin — so only worktree squares
    /// and PR circles animate.
    var spinning = false
    @Environment(\.dashboardLive) private var live
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch kind {
            case .repo:
                Image(systemName: kind.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(color)
            case .worktree:
                Image(systemName: kind.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(color.opacity(0.16)))
                    .overlay(outline(
                        RoundedRectangle(cornerRadius: 5, style: .continuous),
                        perimeter: 70))
            case .pr:
                Image(systemName: kind.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(color.opacity(0.16)))
                    .overlay(outline(Circle(), perimeter: 60))
            }
        }
        .frame(width: 20)
        .help(spinning ? "\(kind.help) — CI running" : kind.help)
    }

    /// Static teal (not severity color) when spinning but motion is off —
    /// reduce-motion still gets the in-flight signal, just without the lap.
    @ViewBuilder
    private func outline(_ shape: some InsettableShape, perimeter: CGFloat) -> some View {
        if spinning, live, !reduceMotion {
            OrbitingOutline(shape: shape, color: .teal, perimeter: perimeter)
        } else if spinning {
            shape.strokeBorder(Color.teal.opacity(0.6), lineWidth: 1)
        } else {
            shape.strokeBorder(color.opacity(0.45), lineWidth: 1)
        }
    }
}

/// Hover-revealed hint in a row's bottom-right corner naming where a click
/// lands ("↗ GitHub", "↗ Finder", "↗ Terminal"). Purely informational — the
/// row's own tap performs the action, so clicks pass straight through.
struct DestinationHint: View {
    let symbol: String
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 7, weight: .bold))
            Image(systemName: symbol)
                .font(.system(size: 8))
            Text(label)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(.tertiary)
        .allowsHitTesting(false)
    }
}

/// "5m ago"-style stamp for a row's trailing edge.
private struct AgoText: View {
    let date: Date?

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        if let date {
            Text(Self.relative.localizedString(for: date, relativeTo: Date()))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help("Last activity: \(date.formatted(date: .abbreviated, time: .shortened))")
        }
    }
}

/// One muted summary row standing in for every repo whose only problem is an
/// unreachable remote (wrong GitHub account, no network). Keeps a work
/// machine's dozens of auth failures from flooding the ranked list; expands
/// on demand into the usual rows.
struct UnreachableLumpView: View {
    let tiles: [RepoTileState]
    let isExpanded: Bool
    let actions: DashboardActions

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tiles.count == 1
                        ? "1 repo can't connect"
                        : "\(tiles.count) repos can't connect")
                        .font(.callout.weight(.semibold))
                    Text("fetch failing — wrong GitHub account? try `gh auth switch`")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(isExpanded ? "Hide" : "Show") {
                    actions.setSectionExpanded(.unreachable, expanded: !isExpanded)
                }
                .buttonStyle(.borderless)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .modifier(RowChrome(severity: .muted))
            if isExpanded {
                ForEach(tiles) { tile in
                    RankedRowView(item: .repo(tile), actions: actions)
                }
            }
        }
    }
}

/// The PR action menu, shared between right-click and the hover ⋯ button.
struct PRContextMenuItems: View {
    let state: PRTileState
    let actions: DashboardActions

    var body: some View {
        Button("Open on GitHub") { actions.openURL(state.url) }
        Button("Copy PR Number") { actions.copyText(String(state.number)) }
        Button("Copy URL") { actions.copyPath(state.url) }
        Button("Copy Branch Name") { actions.copyPath(state.branch) }
    }
}

private struct RepoRowView: View {
    let state: RepoTileState
    var summary: SummaryDisplay = SummaryDisplay()
    let actions: DashboardActions
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Only worktree rows spin: a worktree IS the branch the CI is
            // running for, so the motion points at the action. A plain repo
            // row's click lands in Finder, where nothing is active.
            RowKindIcon(
                kind: state.isWorktree ? .worktree : .repo,
                color: Color(severity: state.severity),
                spinning: state.isWorktree
                    && (state.worstCI == .pending
                        || state.runs.contains { $0.state == .running }))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    CopyHoverText(
                        text: titleText,
                        copyValue: RepoTileView.copyName(for: state),
                        font: .callout.weight(.semibold),
                        copy: actions.copyText)
                    // On a worktree row the branch is what you scan for, so
                    // it reads as a label rather than a footnote.
                    CopyHoverText(
                        text: "⎇ \(state.branch)",
                        copyValue: state.branch,
                        font: state.isWorktree ? .caption.weight(.medium) : .caption2,
                        color: state.isWorktree ? nil : .secondary,
                        copy: actions.copyText)
                    if let dir = worktreeDirName {
                        Text(dir)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help("Worktree directory")
                    }
                    if let reason = state.pruneReason {
                        PruneableBadge(help: reason)
                    } else if let merge = state.mergeState {
                        MergeStateBadge(state: merge)
                    }
                }
                problemsLine
                stateLine
            }
            Spacer(minLength: 8)
            // Hover controls appear in the spacer's empty gap, LEFT of the
            // persistent meta — dots, counts, and timestamp never move.
            if isHovering {
                ellipsisMenu
            }
            if !state.agentDots.isEmpty {
                MiniDotRow(dots: state.agentDots, shape: .circle)
                    .help(agentsHelp)
            }
            PRIndicator(ci: state.worstCI, prCount: state.prCount)
            if state.hasError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
                    .help("Fetch/status error")
            }
            AgoText(date: state.lastActivity)
        }
        .modifier(RowChrome(severity: state.severity))
        .overlay(alignment: .bottomTrailing) {
            if isHovering {
                DestinationHint(symbol: destinationSymbol, label: destinationLabel)
                    .padding(.trailing, 8)
                    .padding(.bottom, 5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        // The row's click goes where the top problem can be acted on — a
        // failing PR or run opens on GitHub, a waiting agent gets its
        // terminal focused. Finder is only the fallback for rows with
        // nothing to fix (nothing actionable lives in Finder).
        .onTapGesture(perform: performPrimary)
        .contextMenu { RepoContextMenuItems(state: state, actions: actions) }
    }

    /// Worktree names arrive as "repo ⎇ dir"; the row shows the repo alone
    /// so the branch that follows isn't printed twice.
    private var titleText: String {
        guard state.isWorktree, let range = state.name.range(of: " ⎇ ") else { return state.name }
        return String(state.name[..<range.lowerBound])
    }

    /// The worktree's directory name, only when it tells you something the
    /// branch doesn't (`repo-feature` vs `⎇ feature` is the same fact).
    private var worktreeDirName: String? {
        guard state.isWorktree, let range = state.name.range(of: " ⎇ ") else { return nil }
        let dir = String(state.name[range.upperBound...])
        let branchTail = state.branch.split(separator: "/").last.map(String.init) ?? state.branch
        return dir == state.branch || dir == branchTail ? nil : dir
    }

    private func performPrimary() {
        switch primaryTarget {
        case .url(let url): actions.openURL(url)
        case .agent(let pid): actions.focusAgent(pid: pid, fallbackPath: state.path)
        case .finder: actions.openInFinder(path: state.path)
        }
    }

    /// Where a plain row click lands, from the worst actionable problem down.
    private enum PrimaryTarget {
        case url(String)
        case agent(Int32)
        case finder
    }

    private var primaryTarget: PrimaryTarget {
        for problem in state.problems {
            if let url = problem.url { return .url(url) }
            if let pid = problem.agentPid { return .agent(pid) }
        }
        return .finder
    }

    private var destinationSymbol: String {
        switch primaryTarget {
        case .url: return "globe"
        case .agent: return "terminal"
        case .finder: return "folder"
        }
    }

    private var destinationLabel: String {
        switch primaryTarget {
        case .url: return "GitHub"
        case .agent: return "Terminal"
        case .finder: return "Finder"
        }
    }

    /// "2 Claude agents here — 1 waiting on you, 1 working"
    private var agentsHelp: String {
        let waiting = state.agentDots.filter { $0 == .attention }.count
        let busy = state.agentDots.filter { $0 == .info }.count
        let idle = state.agentDots.count - waiting - busy
        var parts: [String] = []
        if waiting > 0 { parts.append("\(waiting) waiting on you") }
        if busy > 0 { parts.append("\(busy) working") }
        if idle > 0 { parts.append("\(idle) idle") }
        let n = state.agentDots.count
        return "\(n) Claude agent\(n == 1 ? "" : "s") here — \(parts.joined(separator: ", "))"
    }


    /// Failures, one full line each: colored label, secondary detail (commit
    /// subject, PR title, failing check names), relative stamp. Each line is
    /// clickable when it has somewhere to act (that run, that PR).
    @ViewBuilder
    private var problemsLine: some View {
        ForEach(Array(state.problems.enumerated()), id: \.offset) { _, problem in
            HStack(spacing: 4) {
                Text(problem.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(severity: problem.severity))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let detail = problem.detail {
                    Text("— \(detail)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                AgoText(date: problem.date)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let url = problem.url { actions.openURL(url) }
            }
            .help(
                problem.url != nil
                    ? "Open on GitHub"
                    : problem.agentPid != nil
                        ? "Row click focuses the waiting agent's terminal" : "")
        }
    }

    /// One full line per live workflow run, then the calm gray counts line.
    /// The LLM summary fills rows with nothing else to say.
    @ViewBuilder
    private var stateLine: some View {
        let activeRuns = state.runs.filter { $0.state != .failed }
        ForEach(activeRuns) { run in
            ActionsRunRow(run: run) { actions.openURL(run.url) }
        }
        if !state.stateInfo.isEmpty {
            Text(state.stateInfo.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(
                    "modified/new: uncommitted local files · to push/pull: commits vs upstream · can't connect: git fetch failing (credentials?)"
                )
        } else if state.problems.isEmpty, activeRuns.isEmpty, !summary.isEmpty {
            SummaryLine(display: summary, lineLimit: 1)
        }
    }

    @ViewBuilder
    private var ellipsisMenu: some View {
        Menu {
            RepoContextMenuItems(state: state, actions: actions)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(4)
                .background(Circle().fill(.thickMaterial))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .background(DemoFrameReporter(kind: .ellipsis, id: state.id))
    }
}

private struct PRRowView: View {
    let state: PRTileState
    let actions: DashboardActions
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            RowKindIcon(
                kind: .pr,
                color: Color(severity: state.severity),
                spinning: state.ci == .pending)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    CopyHoverText(
                        text: state.reference,
                        copyValue: String(state.number),
                        font: .callout.weight(.semibold),
                        copy: actions.copyText)
                        .layoutPriority(1)
                    Text(state.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(state.title)
                }
                HStack(spacing: 0) {
                    CopyHoverText(
                        text: "⎇ \(state.branch)",
                        copyValue: state.branch,
                        color: .secondary,
                        copy: actions.copyText)
                    Text(" · \(state.author)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // The dominant fact ("CI failing", "changes requested") gets
                // its own severity-colored line so it can't be missed.
                Text(state.statusLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(severity: state.severity))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isHovering {
                ellipsisMenu
            }
            if state.isDraft {
                Text("draft")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(.quaternary))
                    .help("Draft — not ready for review")
            } else if state.ci == .pass || state.ci == .fail {
                // Pending doesn't need a trailing dot — the leading outline
                // is the spinner while CI runs.
                CIStatusDot(ci: state.ci)
                    .help(ciHelp)
            }
            AgoText(date: state.updatedAt)
        }
        .modifier(RowChrome(severity: state.severity))
        .overlay(alignment: .bottomTrailing) {
            if isHovering {
                DestinationHint(symbol: "globe", label: "GitHub")
                    .padding(.trailing, 8)
                    .padding(.bottom, 5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture { actions.openURL(state.url) }
        .contextMenu { PRContextMenuItems(state: state, actions: actions) }
    }

    private var ellipsisMenu: some View {
        Menu {
            PRContextMenuItems(state: state, actions: actions)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(4)
                .background(Circle().fill(.thickMaterial))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    private var ciHelp: String {
        switch state.ci {
        case .pass: return "CI passing"
        case .fail: return "CI failing"
        case .pending: return "CI running"
        case .none: return ""
        }
    }
}
