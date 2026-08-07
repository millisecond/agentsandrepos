import AgentsAndReposCore
import SwiftUI

/// Reports the laid-out height of the scrollable content so the popover can
/// hug it instead of reserving a fixed height.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Root dashboard: tile grids for agents and repos, compact PR rows, footer.
struct DashboardView: View {
    @ObservedObject var store: SnapshotStore
    @ObservedObject var sizing: DashboardSizing
    @ObservedObject var summaries: SummaryService
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var perf: PerfMonitor
    let actions: DashboardActions

    @State private var contentHeight: CGFloat = 400

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]
    /// Divider + FooterBar, which sit below the scroll area.
    private let footerAllowance: CGFloat = 38

    init(
        store: SnapshotStore, actions: DashboardActions, sizing: DashboardSizing,
        summaries: SummaryService, updates: UpdateChecker, perf: PerfMonitor
    ) {
        self.store = store
        self.actions = actions
        self.sizing = sizing
        self.summaries = summaries
        self.updates = updates
        self.perf = perf
    }

    var body: some View {
        let snap = store.snapshot
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let warning = perf.warning {
                            PerfBanner(message: warning)
                        }
                        if let version = updates.availableVersion {
                            UpdateBanner(version: version, actions: actions)
                        }
                        workspaceSummary
                        agentsSection(snap)
                        rankedSection(snap)
                        ignoredSection(snap)
                    }
                    .padding(12)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ContentHeightKey.self, value: geo.size.height)
                        })
                    .id("dashboard-top")
                }
                .frame(height: scrollHeight)
                .onChange(of: sizing.scrollToTopTick) {
                    proxy.scrollTo("dashboard-top", anchor: .top)
                }
            }
            Divider()
            FooterBar(snapshot: snap, actions: actions)
        }
        .frame(width: 492)
        .environment(\.dashboardLive, store.isLive)
        .onPreferenceChange(ContentHeightKey.self) { height in
            Task { @MainActor in contentHeight = height }
        }
    }

    /// Hug the content when it's short; stop at the screen's height when not.
    private var scrollHeight: CGFloat {
        let budget = max(200, sizing.maxContentHeight - footerAllowance)
        return min(contentHeight, budget)
    }

    // MARK: - Workspace summary

    /// One-line on-device LLM digest of the whole workspace. Absent until the
    /// first generation lands (or when summaries are off/unavailable).
    @ViewBuilder
    private var workspaceSummary: some View {
        let display = summaries.display(for: SummaryFacts.workspaceKey)
        if !display.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                SummaryLine(display: display, font: .caption, lineLimit: 2)
            }
        }
    }

    // MARK: - Agents

    @ViewBuilder
    private func agentsSection(_ snap: Snapshot) -> some View {
        let tiles = snap.agentTiles
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Claude Agents")
            if tiles.isEmpty {
                InfoRow(text: "No agents running")
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(tiles) { tile in
                        AgentTileView(
                            state: tile,
                            userSummary: summaries.display(for: SummaryFacts.agentUserKey(tile)),
                            agentSummary: summaries.display(for: SummaryFacts.agentAgentKey(tile)),
                            actions: actions)
                    }
                }
            }
        }
    }

    // MARK: - Ranked feed

    /// Repos, worktrees, and PRs stack-ranked together by attention score
    /// (severity + recency) — the most urgent-and-recent things sit right
    /// below the agents instead of being spread across three sections.
    @ViewBuilder
    private func rankedSection(_ snap: Snapshot) -> some View {
        let scope = snap.config.prScope == .mine ? "My PRs" : "All PRs"
        let section = snap.rankedSection(now: Date())
        VStack(alignment: .leading, spacing: 8) {
            ExpandableSectionHeader(
                title: "Needs Attention · Repos & \(scope)", section: .ranked,
                totalCount: section.totalCount, isExpanded: section.isExpanded,
                canToggle: section.canToggle, actions: actions)
            switch snap.ghAvailability {
            case .notInstalled:
                InfoRow(text: "gh CLI not found — brew install gh (PRs won't show)")
            case .notAuthenticated:
                InfoRow(text: "Run `gh auth login` to see PRs")
            case .error(let e):
                InfoRow(text: "GitHub: \(e)")
            case .unknown, .ok:
                EmptyView()
            }
            if section.totalCount == 0 {
                InfoRow(
                    text: snap.repos.isEmpty
                        ? "No repos found"
                        : "All \(snap.repos.count) repos hidden — see Hidden below")
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(section.visible) { item in
                        switch item {
                        case .repo(let tile):
                            RepoTileView(
                                state: tile,
                                summary: summaries.display(for: SummaryFacts.repoKey(tile)),
                                actions: actions)
                        case .pr(let tile):
                            PRTileView(state: tile, actions: actions)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Hidden

    /// Compact list of everything hidden from the sections above — ignored
    /// agents and repos — with one-click restore. Absent entirely when
    /// nothing is hidden.
    @ViewBuilder
    private func ignoredSection(_ snap: Snapshot) -> some View {
        let agents = snap.ignoredAgentTiles
        let repos = snap.ignoredRepoTiles
        if !agents.isEmpty || !repos.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "Hidden · \(agents.count + repos.count)")
                    .padding(.bottom, 2)
                ForEach(agents) { tile in
                    IgnoredRow(
                        symbol: "sparkle", title: tile.title, subtitle: tile.subtitle
                    ) {
                        actions.unignoreAgent(sessionId: tile.id)
                    }
                }
                ForEach(repos) { tile in
                    IgnoredRow(
                        symbol: tile.isWorktree ? "arrow.triangle.branch" : "folder",
                        title: tile.name,
                        subtitle: tile.branch
                    ) {
                        actions.unignoreRepo(path: tile.path)
                    }
                }
            }
        }
    }
}
