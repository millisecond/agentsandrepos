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
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    /// Divider + FooterBar, which sit below the scroll area.
    private let footerAllowance: CGFloat = 38
    /// Search bar + divider, pinned above the scroll area. Must be budgeted
    /// like the footer or a full-height dashboard overflows the screen and
    /// the popover clips the bar right off the top.
    private let searchAllowance: CGFloat = 44

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
        let query = SearchQuery(searchText)
        VStack(spacing: 0) {
            searchBar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let warning = perf.warning {
                            PerfBanner(message: warning)
                        }
                        if let version = updates.availableVersion {
                            UpdateBanner(version: version, actions: actions)
                        }
                        if DevMode.showRowGallery {
                            DevRowGalleryView(actions: actions)
                        }
                        if query.isEmpty {
                            workspaceSummary
                        }
                        agentsSection(snap, query)
                        rankedSection(snap, query)
                        ignoredSection(snap, query)
                        if noMatches(snap, query) {
                            InfoRow(text: "No matches for “\(searchText)”")
                        }
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
                    // Same staleness signal as the scroll reset: a reopen
                    // after a while closed starts a fresh lookup.
                    searchText = ""
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
        let budget = max(200, sizing.maxContentHeight - footerAllowance - searchAllowance)
        return min(contentHeight, budget)
    }

    // MARK: - Search

    /// Pinned type-to-filter bar. Matches names, branches, paths, status
    /// text, PR titles/authors, and agent transcript context — everything
    /// already in the snapshot, no repo contents.
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search agents, repos, PRs", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($searchFocused)
                .onExitCommand {
                    // First Escape clears; the next one (field unfocused)
                    // falls through to AppKit and closes the popover.
                    searchText = ""
                    searchFocused = false
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.25)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    searchFocused ? Color.accentColor.opacity(0.35) : Color.clear,
                    lineWidth: 1)
        )
        // A plain TextField's hit target is only the text line; the whole
        // box should focus it.
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = true }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Focusing search means a lookup is coming — nudge any mid-interval
        // polling now (staleness-gated in the engine, so this is cheap).
        .onChange(of: searchFocused) {
            if searchFocused { actions.searchFocused() }
        }
        .background(
            // Invisible ⌘F target; keyboardShortcut needs a live button.
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }

    /// The query missed everything — visible sections and hidden ones alike.
    private func noMatches(_ snap: Snapshot, _ query: SearchQuery) -> Bool {
        guard !query.isEmpty else { return false }
        return snap.agentTiles(matching: query).isEmpty
            && snap.rankedSection(matching: query).totalCount == 0
            && !snap.ignoredAgentTiles.contains { $0.matches(query) }
            && !snap.ignoredRepoTiles.contains { $0.matches(query) }
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
    private func agentsSection(_ snap: Snapshot, _ query: SearchQuery) -> some View {
        let tiles = snap.agentTiles(matching: query)
        // While searching, a sectionful of misses just disappears.
        if query.isEmpty || !tiles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Claude Agents")
                if tiles.isEmpty {
                    InfoRow(text: "No agents running")
                } else {
                    LazyVStack(spacing: 5) {
                        ForEach(tiles) { tile in
                            AgentTileView(
                                state: tile,
                                userSummary: summaries.display(
                                    for: SummaryFacts.agentUserKey(tile)),
                                agentSummary: summaries.display(
                                    for: SummaryFacts.agentAgentKey(tile)),
                                actions: actions)
                        }
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
    private func rankedSection(_ snap: Snapshot, _ query: SearchQuery) -> some View {
        let section = snap.rankedSection(now: Date(), matching: query)
        if query.isEmpty || section.totalCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                ExpandableSectionHeader(
                    title: "Repos, PRs, and Worktrees", section: .ranked,
                    totalCount: section.totalCount, isExpanded: section.isExpanded,
                    canToggle: query.isEmpty && section.canToggle, actions: actions)
                if query.isEmpty {
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
                }
                if section.totalCount == 0 {
                    InfoRow(
                        text: snap.repos.isEmpty
                            ? "No repos found"
                            : "All \(snap.repos.count) repos hidden — see Hidden below")
                } else {
                    LazyVStack(spacing: 5) {
                        ForEach(section.visible) { item in
                            RankedRowView(
                                item: item,
                                summary: rowSummary(for: item),
                                actions: actions)
                                .background(DemoFrameReporter(kind: .row, id: item.id))
                        }
                    }
                }
                // Search results already include matching unreachable repos.
                let unreachable = snap.unreachableTiles
                if query.isEmpty && !unreachable.isEmpty {
                    UnreachableLumpView(
                        tiles: unreachable,
                        isExpanded: snap.config.isSectionExpanded(.unreachable),
                        actions: actions)
                }
            }
        }
    }

    private func rowSummary(for item: RankedTile) -> SummaryDisplay {
        switch item {
        case .repo(let tile): return summaries.display(for: SummaryFacts.repoKey(tile))
        case .pr: return SummaryDisplay()
        }
    }

    // MARK: - Hidden

    /// Compact list of everything hidden from the sections above — ignored
    /// agents and repos — with one-click restore. Absent entirely when
    /// nothing is hidden.
    @ViewBuilder
    private func ignoredSection(_ snap: Snapshot, _ query: SearchQuery) -> some View {
        // A search is a lookup — a hidden repo the query names still shows
        // here, so "where did I put that" works even for ignored things.
        let agents = snap.ignoredAgentTiles.filter { query.isEmpty || $0.matches(query) }
        let repos = snap.ignoredRepoTiles.filter { query.isEmpty || $0.matches(query) }
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
