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

/// Shared row chrome: severity-tinted rounded border, hover tracking.
struct RowChrome: ViewModifier {
    let severity: TileSeverity

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(severity: severity).opacity(severity == .muted ? 0.04 : 0.09))
            )
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        Color(severity: severity).opacity(severity == .muted ? 0.25 : 0.55),
                        lineWidth: 1.5)
            )
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
                    .frame(width: 16)
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

private struct RepoRowView: View {
    let state: RepoTileState
    var summary: SummaryDisplay = SummaryDisplay()
    let actions: DashboardActions
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.isWorktree ? "arrow.triangle.branch" : "folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(severity: state.severity))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(state.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text("⎇ \(state.branch)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                problemsLine
                stateLine
            }
            Spacer(minLength: 8)
            if !state.agentDots.isEmpty {
                MiniDotRow(dots: state.agentDots, shape: .circle)
                    .help("Claude agents working here")
            }
            PRIndicator(ci: state.worstCI, prCount: state.prCount)
            if state.hasError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
                    .help("Fetch/status error")
            }
            trailing
        }
        .modifier(RowChrome(severity: state.severity))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        // The row's click goes where the top problem can be acted on — a
        // failing PR or run opens on GitHub. Finder is only the fallback for
        // rows with nothing to fix (nothing actionable lives in Finder).
        .onTapGesture {
            if let url = state.problems.compactMap(\.url).first {
                actions.openURL(url)
            } else {
                actions.openInFinder(path: state.path)
            }
        }
        .contextMenu { RepoContextMenuItems(state: state, actions: actions) }
        .help(state.problems.first?.url != nil
            ? "Click: open \(state.problems.first?.label ?? "") on GitHub"
            : "Click: reveal in Finder")
    }

    /// Failures only, each in its own color and individually clickable
    /// (failed run → that run, failing PR → that PR).
    @ViewBuilder
    private var problemsLine: some View {
        if !state.problems.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(state.problems.enumerated()), id: \.offset) { i, problem in
                    if i > 0 {
                        Text("·").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(problem.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(severity: problem.severity))
                        .lineLimit(1)
                        .onTapGesture {
                            if let url = problem.url { actions.openURL(url) }
                        }
                        .help(problem.url != nil ? "Open on GitHub" : "")
                }
            }
        }
    }

    /// Normal in-flight work in calm gray — informative, not alarming. Live
    /// workflow runs ride along; the LLM summary fills quiet rows.
    @ViewBuilder
    private var stateLine: some View {
        let activeRuns = state.runs.filter { $0.state != .failed }
        if !state.stateInfo.isEmpty || !activeRuns.isEmpty {
            HStack(spacing: 10) {
                if !state.stateInfo.isEmpty {
                    Text(state.stateInfo.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                ForEach(activeRuns) { run in
                    ActionsRunRow(run: run) { actions.openURL(run.url) }
                }
            }
        } else if state.problems.isEmpty, !summary.isEmpty {
            SummaryLine(display: summary, lineLimit: 1)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isHovering {
            HStack(spacing: 2) {
                TileCopyButton(help: "Copy \"\(RepoTileView.copyName(for: state))\"") {
                    actions.copyText(RepoTileView.copyName(for: state))
                }
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
            }
        } else {
            AgoText(date: state.lastActivity)
        }
    }
}

private struct PRRowView: View {
    let state: PRTileState
    let actions: DashboardActions
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(severity: state.severity))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(state.reference)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(state.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("⎇ \(state.branch) · \(state.author)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // The dominant fact ("CI failing", "changes requested") gets
                // its own severity-colored line so it can't be missed.
                Text(state.statusLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(severity: state.severity))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if state.isDraft {
                Text("draft")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(.quaternary))
            } else if state.ci != .none {
                Circle().fill(ciColor).frame(width: 7, height: 7)
            }
            trailing
        }
        .modifier(RowChrome(severity: state.severity))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture { actions.openURL(state.url) }
        .contextMenu {
            Button("Open on GitHub") { actions.openURL(state.url) }
            Button("Copy PR Number") { actions.copyText(String(state.number)) }
            Button("Copy URL") { actions.copyPath(state.url) }
            Button("Copy Branch Name") { actions.copyPath(state.branch) }
        }
        .help("\(state.reference) — \(state.title) · \(state.statusLabel)")
    }

    @ViewBuilder
    private var trailing: some View {
        if isHovering {
            TileCopyButton(help: "Copy PR number \(state.number)") {
                actions.copyText(String(state.number))
            }
        } else {
            AgoText(date: state.updatedAt)
        }
    }

    private var ciColor: Color {
        switch state.ci {
        case .pass: return .green
        case .fail: return .red
        case .pending: return .yellow
        case .none: return .clear
        }
    }
}
