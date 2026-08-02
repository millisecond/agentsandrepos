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
        Tile(severity: state.severity) {
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
                    MiniDotRow(dots: state.agentDots, shape: .circle)
                    Spacer(minLength: 0)
                    if state.hasError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(9)
        }
        .overlay(alignment: .topTrailing) {
            if isHovering {
                TileIgnoreButton(help: state.isWorktree ? "Ignore this worktree" : "Ignore this repo") {
                    actions.ignoreRepo(path: state.path)
                }
            }
        }
        .onHover { isHovering = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { actions.openInFinder(path: state.path) }
        .contextMenu { contextMenuItems }
        .help(helpText)
    }

    /// Git-state badge row; shows a green check when fully clean and synced.
    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if state.dirty > 0 { CountBadge(symbol: "●", count: state.dirty, color: .orange) }
            if state.untracked > 0 { CountBadge(symbol: "+", count: state.untracked, color: .yellow) }
            if state.ahead > 0 { CountBadge(symbol: "↑", count: state.ahead, color: .blue) }
            if state.behind > 0 { CountBadge(symbol: "↓", count: state.behind, color: .purple) }
            if isCleanAndSynced {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green.opacity(0.8))
            }
        }
        .frame(height: 14)
    }

    private var isCleanAndSynced: Bool {
        state.dirty == 0 && state.untracked == 0 && state.ahead == 0 && state.behind == 0
            && !state.hasError && state.severity != .muted
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Open in Finder") { actions.openInFinder(path: state.path) }
        Button("Open in Terminal") { actions.openInTerminal(path: state.path) }
        if let gh = state.githubRepo {
            Button("Open on GitHub") { actions.openURL("https://github.com/\(gh)") }
        }
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

    private var helpText: String {
        var parts = [state.name, state.branch]
        if state.isWorktree {
            parts.append(state.isClaudeManaged ? "(claude worktree)" : "(worktree)")
        }
        if state.dirty > 0 { parts.append("●\(state.dirty)") }
        if state.untracked > 0 { parts.append("+\(state.untracked)") }
        if state.ahead > 0 { parts.append("↑\(state.ahead)") }
        if state.behind > 0 { parts.append("↓\(state.behind)") }
        if state.hasError { parts.append("⚠︎ fetch/status error") }
        if let text = summary.text { parts.append("— \(text)") }
        return parts.joined(separator: " ")
    }
}
