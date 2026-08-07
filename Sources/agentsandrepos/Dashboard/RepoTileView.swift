import AgentsAndReposCore
import SwiftUI

/// Square tile for one repo or worktree: name + branch, git-state badges,
/// PR/CI corner indicator, and mini-dots for its agents. Worktrees are
/// first-class tiles titled "repo ⎇ name".
struct RepoTileView: View {
    let state: RepoTileState
    /// On-device LLM one-liner plus refresh state.
    var summary: SummaryDisplay = SummaryDisplay()
    let actions: DashboardActions
    @State private var isHovering = false

    var body: some View {
        Tile(severity: state.severity, height: tileHeight) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top) {
                    Text(state.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    PRIndicator(ci: state.worstCI, prCount: state.prCount)
                }
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Text(state.branch)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !state.runs.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(state.runs) { run in
                            ActionsRunRow(run: run) { actions.openURL(run.url) }
                        }
                    }
                    .padding(.top, 1)
                }
                // Summary soaks up the tile's flexible middle; otherwise a
                // plain spacer keeps badges pinned to the bottom.
                if !summary.isEmpty {
                    SummaryLine(display: summary, lineLimit: 3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    Spacer(minLength: 0)
                }
                badges
                HStack(spacing: 6) {
                    if !state.agentDots.isEmpty {
                        HStack(spacing: 4) {
                            MiniDotRow(dots: state.agentDots, shape: .circle)
                            Text(state.agentDots.count == 1
                                ? "1 agent" : "\(state.agentDots.count) agents")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                        .help("Claude agents working here — color shows status")
                    }
                    Spacer(minLength: 0)
                    if state.hasError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                            .help("Fetch/status error")
                    }
                }
            }
            .padding(9)
        }
        .overlay(alignment: .topTrailing) {
            if isHovering {
                HStack(spacing: 2) {
                    TileCopyButton(help: "Copy \"\(copyName)\"") {
                        actions.copyText(copyName)
                    }
                    // Ignore lives inside this menu (with the other actions)
                    // rather than as a bare corner button — one stray click
                    // next to Copy shouldn't hide a repo.
                    Menu {
                        contextMenuItems
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
                .padding(4)
            }
        }
        .onHover { isHovering = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { actions.openInFinder(path: state.path) }
        .contextMenu { contextMenuItems }
        .help(helpText)
    }

    /// What the copy button yields: the directory name — for worktrees that's
    /// the checkout dir ("repo-slug"), not the "repo ⎇ slug" display title —
    /// so it pastes cleanly into cd/CLI commands.
    private var copyName: String { Self.copyName(for: state) }

    /// Each workflow-run row adds to the standard height so the grid row grows
    /// with the tile instead of squeezing the badges out the bottom.
    private var tileHeight: CGFloat {
        112 + CGFloat(state.runs.count) * 17
    }

    /// Git-state badge row; shows a green check when fully clean and synced.
    /// Badges carry words ("3 modified"); when a crowded row won't fit the
    /// tile, ViewThatFits falls back to the compact symbol-only form.
    @ViewBuilder
    private var badges: some View {
        ViewThatFits(in: .horizontal) {
            badgeRow(compact: false)
            badgeRow(compact: true)
        }
        .frame(height: 14)
    }

    @ViewBuilder
    private func badgeRow(compact: Bool) -> some View {
        HStack(spacing: 4) {
            if state.dirty > 0 {
                CountBadge(
                    symbol: "●", count: state.dirty, label: "modified", color: .orange,
                    compact: compact)
            }
            if state.untracked > 0 {
                CountBadge(
                    symbol: "+", count: state.untracked, label: "new", color: .yellow,
                    compact: compact)
            }
            if state.ahead > 0 {
                CountBadge(
                    symbol: "↑", count: state.ahead, label: "to push", color: .blue,
                    compact: compact)
            }
            if state.behind > 0 {
                CountBadge(
                    symbol: "↓", count: state.behind, label: "to pull", color: .purple,
                    compact: compact)
            }
            if isCleanAndSynced {
                HStack(spacing: 2) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green.opacity(0.8))
                    Text("clean")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .help("No local changes, in sync with remote")
            }
        }
    }

    private var isCleanAndSynced: Bool {
        state.dirty == 0 && state.untracked == 0 && state.ahead == 0 && state.behind == 0
            && !state.hasError && state.severity != .muted
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        RepoContextMenuItems(state: state, actions: actions)
    }

    static func copyName(for state: RepoTileState) -> String {
        (state.path as NSString).lastPathComponent
    }

    private var helpText: String {
        var parts = [state.name, state.branch]
        if state.isWorktree {
            parts.append(state.isClaudeManaged ? "(claude worktree)" : "(worktree)")
        }
        if state.dirty > 0 { parts.append("\(state.dirty) modified") }
        if state.untracked > 0 { parts.append("\(state.untracked) new") }
        if state.ahead > 0 { parts.append("\(state.ahead) to push") }
        if state.behind > 0 { parts.append("\(state.behind) to pull") }
        if state.hasError { parts.append("⚠︎ fetch/status error") }
        for run in state.runs {
            parts.append("\(run.state.glyph) \(run.workflowName) \(run.state.rawValue)")
        }
        if let text = summary.text { parts.append("— \(text)") }
        return parts.joined(separator: " ")
    }
}

/// The repo/worktree action menu, shared between the tile (right-click and
/// hover ⋯) and the ranked full-width row.
struct RepoContextMenuItems: View {
    let state: RepoTileState
    let actions: DashboardActions

    var body: some View {
        Button("Open in Finder") { actions.openInFinder(path: state.path) }
        Button("Open in Terminal") { actions.openInTerminal(path: state.path) }
        if let gh = state.githubRepo {
            Button("Open on GitHub") { actions.openURL("https://github.com/\(gh)") }
            Button("Open Actions") { actions.openURL("https://github.com/\(gh)/actions") }
        }
        Button("Copy Name") { actions.copyText(RepoTileView.copyName(for: state)) }
        Button("Copy Path") { actions.copyPath(state.path) }
        Divider()
        Button("Fetch Now") { actions.fetchRepo(path: state.path) }
        Button("Ignore") { actions.ignoreRepo(path: state.path) }
        if !state.worktrees.isEmpty {
            Divider()
            ForEach(state.worktrees) { wt in
                Menu("⎇ \(wt.name)\(wt.isClaudeManaged ? " · claude" : "")") {
                    Button("Open in Finder") { actions.openInFinder(path: wt.path) }
                    Button("Open in Terminal") { actions.openInTerminal(path: wt.path) }
                    Button("Copy Path") { actions.copyPath(wt.path) }
                }
            }
        }
    }
}
