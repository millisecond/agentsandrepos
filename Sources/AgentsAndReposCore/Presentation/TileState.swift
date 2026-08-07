import Foundation

/// Semantic severity for a tile or indicator dot. The UI layer maps these to
/// colors; Core stays appearance-agnostic so the mapping is unit-testable.
public enum TileSeverity: Sendable, Equatable, Comparable {
    case muted
    case ok
    case info
    case attention
    case urgent
}

/// Everything an agent tile renders, derived from an AgentSession plus the
/// human-readable location the menu already computed (repo name, "repo ⎇ wt",
/// or an abbreviated path).
public struct AgentTileState: Sendable, Equatable, Identifiable {
    public enum Phase: Sendable, Equatable {
        case idle, busy, waiting, unknown
    }

    public let id: String
    public let pid: Int32
    public let phase: Phase
    public let severity: TileSeverity
    public let isPulsing: Bool
    public let title: String
    public let subtitle: String
    public let statusLabel: String
    public let glyph: String
    public let path: String
    public let task: AgentTask
    /// LED levels for the activity bars (see `AgentActivityMeter`); empty
    /// hides the strip.
    public let activity: [Int]

    public init(agent: AgentSession, location: String, path: String) {
        self.id = agent.sessionId
        self.pid = agent.pid
        switch agent.status {
        case .waiting:
            phase = .waiting
            severity = .attention
        case .busy:
            phase = .busy
            severity = .info
        case .idle:
            phase = .idle
            severity = .muted
        case .unknown:
            phase = .unknown
            severity = .muted
        }
        self.isPulsing = agent.status.isBusy
        let bg = agent.isBackground ? " (bg)" : ""
        self.title = agent.displayName + bg
        self.subtitle = location
        self.statusLabel = agent.status.label
        self.glyph = agent.status.glyph
        self.path = path
        self.task = agent.task
        self.activity = agent.activity
    }
}

/// Everything a repo tile renders, derived from a RepoOverview — or from a
/// WorktreeOverview, which renders as a first-class tile of its own titled
/// "repo ⎇ name".
public struct RepoTileState: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let branch: String
    public let path: String
    public let githubRepo: String?
    /// True when this tile is a linked worktree rather than the main repo.
    public let isWorktree: Bool
    public let isClaudeManaged: Bool

    public let severity: TileSeverity
    /// Local git breakage (`git status` itself failing) — genuinely urgent.
    public let hasError: Bool
    /// The remote can't be reached (fetch failing: wrong account, no network).
    /// Deliberately NOT urgent — on a machine signed into the wrong GitHub
    /// account this is most repos, and it would drown the ranked list.
    public let unreachable: Bool
    public let dirty: Int
    public let untracked: Int
    public let ahead: Int
    public let behind: Int
    /// Changed/untracked file paths (capped) — LLM job-description input.
    public let changedPaths: [String]
    /// Most recent activity across the repo and its worktrees (commits or
    /// edits to changed files). Drives recency sorting and the stale list.
    public let lastActivity: Date?
    /// Tasks of agents working in this repo or its worktrees (from transcripts).
    public let agentTasks: [String]

    public let prCount: Int
    public let worstCI: PullRequest.CIStatus

    /// Recent repo-level workflow runs (deploys, dispatches). Worktree tiles
    /// never carry these — runs belong to the repo, not a checkout.
    public let runs: [WorkflowRun]
    public let worstRun: WorkflowRun.State?

    /// One severity per agent working directly in this tile's checkout.
    /// Worktree agents dot their own worktree tile, not the parent repo's.
    public let agentDots: [TileSeverity]
    /// Full worktree states, for the parent repo's context menu.
    public let worktrees: [WorktreeTileState]

    public init(repo r: RepoOverview) {
        self.id = r.repo.path
        self.name = r.repo.name
        self.path = r.repo.path
        self.githubRepo = r.githubRepo
        self.isWorktree = false
        self.isClaudeManaged = false

        let git = r.git
        if git?.detached == true {
            self.branch = "detached"
        } else {
            self.branch = git?.branch ?? "…"
        }
        self.hasError = git?.statusError != nil
        self.unreachable = git?.fetchError != nil
        self.dirty = git?.dirty ?? 0
        self.untracked = git?.untracked ?? 0
        self.ahead = git?.ahead ?? 0
        self.behind = git?.behind ?? 0
        self.changedPaths = git?.changedPaths ?? []
        self.lastActivity = r.lastActivity
        self.agentTasks = Self.tasks(of: r.agents)

        // A PR whose branch is checked out in a worktree belongs to that
        // worktree's tile; the parent keeps the rest.
        let wtBranches = Set(r.worktrees.compactMap { $0.git?.branch ?? $0.worktree.branch })
        let prs = r.prs.filter { !wtBranches.contains($0.headRefName) }
        self.prCount = prs.count
        self.worstCI = Self.worstCI(of: prs)

        self.runs = r.runs
        self.worstRun = WorkflowRun.worstState(of: r.runs)

        self.agentDots = Self.dots(of: r.agents)
        self.worktrees = r.worktrees.map {
            WorktreeTileState(worktree: $0, repoName: r.repo.name)
        }

        self.severity = Self.severity(
            hasError: hasError, worstCI: worstCI, worstRun: worstRun, git: git,
            agentDots: agentDots, unreachable: unreachable)
    }

    public init(worktree wt: WorktreeOverview, parent r: RepoOverview) {
        self.id = wt.worktree.path
        self.name = Self.worktreeTitle(repoName: r.repo.name, worktreeName: wt.worktree.name)
        self.path = wt.worktree.path
        self.githubRepo = r.githubRepo
        self.isWorktree = true
        self.isClaudeManaged = wt.isClaudeManaged

        let git = wt.git
        let branchName = git?.branch ?? wt.worktree.branch
        if git?.detached == true || (git == nil && wt.worktree.detached) {
            self.branch = "detached"
        } else {
            self.branch = branchName ?? "…"
        }
        self.hasError = git?.statusError != nil
        self.unreachable = git?.fetchError != nil
        self.dirty = git?.dirty ?? 0
        self.untracked = git?.untracked ?? 0
        self.ahead = git?.ahead ?? 0
        self.behind = git?.behind ?? 0
        self.changedPaths = git?.changedPaths ?? []
        self.lastActivity = git?.lastActivity
        self.agentTasks = Self.tasks(of: wt.agents)

        let prs = r.prs.filter { $0.headRefName == branchName }
        self.prCount = prs.count
        self.worstCI = Self.worstCI(of: prs)

        self.runs = []
        self.worstRun = nil

        self.agentDots = Self.dots(of: wt.agents)
        self.worktrees = []

        self.severity = Self.severity(
            hasError: hasError, worstCI: worstCI, worstRun: nil, git: git,
            agentDots: agentDots, unreachable: unreachable)
    }

    /// Plain-words statement of everything this checkout needs, worst first —
    /// "Deploy failed · 10 modified · 2 new · 3 to push". Empty when clean
    /// and synced, so callers can gate on "not green → say why".
    public var needs: [String] {
        var parts: [String] = []
        if hasError { parts.append("git status error") }
        for run in runs where run.state == .failed {
            parts.append("\(run.workflowName) failed")
        }
        if worstCI == .fail { parts.append("PR checks failing") }
        if agentDots.contains(.attention) { parts.append("agent waiting on input") }
        if dirty > 0 { parts.append("\(dirty) modified") }
        if untracked > 0 { parts.append("\(untracked) new") }
        if ahead > 0 { parts.append("\(ahead) to push") }
        if behind > 0 { parts.append("\(behind) to pull") }
        // Last: it explains stale remote data, but must never shout over
        // real local work.
        if unreachable { parts.append("can't connect") }
        return parts
    }

    /// The only thing wrong is that the remote can't be reached — no local
    /// work, nothing failing. These lump into one summary row instead of
    /// flooding the ranked list (work machines often can't auth to most
    /// personal repos and vice versa).
    public var isQuietUnreachable: Bool {
        unreachable && !hasError && dirty == 0 && untracked == 0 && ahead == 0
            && behind == 0 && worstCI != .fail && worstRun != .failed
            && !agentDots.contains(.attention)
    }

    public var needsLabel: String? {
        needs.isEmpty ? nil : needs.joined(separator: " · ")
    }

    /// "repo ⎇ name", dropping a redundant "repo-" prefix from the worktree's
    /// directory name (Claude-managed worktrees are usually named "repo-slug").
    static func worktreeTitle(repoName: String, worktreeName: String) -> String {
        var short = worktreeName
        if short.count > repoName.count + 1, short.hasPrefix(repoName + "-") {
            short = String(short.dropFirst(repoName.count + 1))
        }
        return "\(repoName) ⎇ \(short)"
    }

    static func dots(of agents: [AgentSession]) -> [TileSeverity] {
        agents.map { agent in
            switch agent.status {
            case .waiting: return .attention
            case .busy: return .info
            case .idle, .unknown: return .muted
            }
        }
    }

    static func tasks(of agents: [AgentSession]) -> [String] {
        var tasks: [String] = []
        for a in agents {
            if let t = a.task.lastUserMessage, !tasks.contains(t) { tasks.append(t) }
        }
        return tasks
    }

    /// fail > pending > pass > none — the corner indicator shows the worst.
    static func worstCI(of prs: [PullRequest]) -> PullRequest.CIStatus {
        var worst = PullRequest.CIStatus.none
        for pr in prs {
            switch (pr.ci, worst) {
            case (.fail, _): return .fail
            case (.pending, .pass), (.pending, .none): worst = .pending
            case (.pass, .none): worst = .pass
            default: break
            }
        }
        return worst
    }

    /// Precedence: CI/run-fail or status error → urgent > dirty/untracked or
    /// waiting agent → attention > ahead/behind, running action, or busy agent
    /// → info > clean → ok > no git or unreachable-remote → muted. A fetch
    /// error alone never raises severity — an unreachable clean repo is an
    /// unknown, not an emergency.
    static func severity(
        hasError: Bool, worstCI: PullRequest.CIStatus, worstRun: WorkflowRun.State?,
        git: GitState?, agentDots: [TileSeverity], unreachable: Bool = false
    ) -> TileSeverity {
        if hasError || worstCI == .fail || worstRun == .failed { return .urgent }
        guard let git else { return .muted }
        if !git.isClean || agentDots.contains(.attention) { return .attention }
        if git.ahead > 0 || git.behind > 0 || agentDots.contains(.info)
            || worstRun == .running
        { return .info }
        return unreachable ? .muted : .ok
    }
}

/// A worktree tile nested visually under (or alongside) its repo.
public struct WorktreeTileState: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let repoName: String
    public let branch: String
    public let path: String
    public let severity: TileSeverity
    public let isClaudeManaged: Bool
    public let gitSummary: String

    public init(worktree wt: WorktreeOverview, repoName: String) {
        self.id = wt.worktree.path
        self.name = wt.worktree.name
        self.repoName = repoName
        self.branch = wt.git?.branch ?? wt.worktree.branch ?? ""
        self.path = wt.worktree.path
        self.isClaudeManaged = wt.isClaudeManaged
        self.gitSummary = wt.git?.summary ?? wt.worktree.branch ?? ""
        if wt.git?.fetchError != nil || wt.git?.statusError != nil {
            self.severity = .urgent
        } else if wt.git?.needsAttention == true {
            self.severity = .attention
        } else if !wt.agents.isEmpty {
            self.severity = .info
        } else {
            self.severity = .ok
        }
    }
}

/// Everything a PR tile renders, derived from a PullRequest plus the name of
/// the repo it belongs to.
public struct PRTileState: Sendable, Equatable, Identifiable {
    /// The PR URL — numbers collide across repos.
    public let id: String
    public let number: Int
    public let title: String
    public let repoName: String
    /// "repo #123" — the tile's identity line.
    public let reference: String
    public let author: String
    public let branch: String
    public let isDraft: Bool
    public let ci: PullRequest.CIStatus
    public let severity: TileSeverity
    public let statusLabel: String
    public let url: String
    /// Drives recency sorting; not rendered.
    public let updatedAt: Date?

    public init(pr: PullRequest, repoName: String) {
        self.id = pr.url
        self.number = pr.number
        self.title = pr.title
        self.repoName = repoName
        self.reference = "\(repoName) #\(pr.number)"
        self.author = pr.author
        self.branch = pr.headRefName
        self.isDraft = pr.isDraft
        self.ci = pr.ci
        self.url = pr.url
        self.severity = Self.severity(pr)
        self.statusLabel = Self.statusLabel(pr)
        self.updatedAt = pr.updatedAt
    }

    /// Precedence: CI fail → urgent > changes requested → attention >
    /// draft → muted > CI pending → info > approved/passing → ok >
    /// awaiting review → info.
    static func severity(_ pr: PullRequest) -> TileSeverity {
        if pr.ci == .fail { return .urgent }
        if pr.reviewDecision == "CHANGES_REQUESTED" { return .attention }
        if pr.isDraft { return .muted }
        if pr.ci == .pending { return .info }
        if pr.reviewDecision == "APPROVED" || pr.ci == .pass { return .ok }
        return .info
    }

    /// One line naming the dominant fact, same precedence as `severity`.
    static func statusLabel(_ pr: PullRequest) -> String {
        if pr.ci == .fail { return "CI failing" }
        if pr.reviewDecision == "CHANGES_REQUESTED" { return "changes requested" }
        if pr.isDraft { return "draft" }
        if pr.ci == .pending { return "CI running" }
        if pr.reviewDecision == "APPROVED" {
            return pr.ci == .pass ? "approved · CI passing" : "approved"
        }
        if pr.ci == .pass { return "CI passing" }
        return "awaiting review"
    }
}

/// A dashboard section truncated to the `recentLimit` most recent tiles,
/// expandable to the full list via a persisted per-section config flag.
public struct TileSection<Tile: Identifiable & Sendable & Equatable>: Sendable, Equatable {
    public static var recentLimit: Int { 6 }

    /// The tiles to render: the full list when expanded, else the first
    /// `limit` of it.
    public let visible: [Tile]
    public let totalCount: Int
    public let isExpanded: Bool
    public let limit: Int

    /// How many tiles are hidden behind the show-more control.
    public var overflowCount: Int { totalCount - visible.count }
    /// Whether a show-more/show-less control is warranted at all.
    public var canToggle: Bool { totalCount > limit }

    init(all: [Tile], isExpanded: Bool, limit: Int = TileSection.recentLimit) {
        self.visible = isExpanded ? all : Array(all.prefix(limit))
        self.totalCount = all.count
        self.isExpanded = isExpanded
        self.limit = limit
    }
}

extension Snapshot {
    public func isRepoIgnored(_ path: String) -> Bool {
        config.ignoredRepos.contains(path)
    }

    public func isAgentIgnored(_ sessionId: String) -> Bool {
        config.ignoredAgents.contains(sessionId)
    }

    /// All agent sessions except individually ignored ones — drives the
    /// status-item badge, so an ignored agent can't ping the menu bar.
    public var visibleAgents: [AgentSession] {
        allAgents.filter { !isAgentIgnored($0.sessionId) }
    }

    /// Repos except ignored ones — drives badges and menu sections.
    public var visibleRepos: [RepoOverview] {
        repos.filter { !isRepoIgnored($0.repo.path) }
    }

    /// PRs from visible repos only.
    public var visiblePRs: [(repo: RepoOverview, pr: PullRequest)] {
        allPRs.filter { !isRepoIgnored($0.repo.repo.path) }
    }

    /// PR tiles: most recently updated first (unknown dates last), then by
    /// repo name, then by PR number within a repo. Two local clones of the
    /// same GitHub repo fetch the same PRs — dedupe by URL (the tile id), or
    /// the duplicated ForEach identity renders a blank cell in the grid.
    public var prTiles: [PRTileState] {
        var seen = Set<String>()
        return visiblePRs
            .filter { seen.insert($0.pr.url).inserted }
            .map { PRTileState(pr: $0.pr, repoName: $0.repo.repo.name) }
            .sorted { lhs, rhs in
                switch (lhs.updatedAt, rhs.updatedAt) {
                case let (l?, r?) where l != r: return l > r
                case (.some, .none): return true
                case (.none, .some): return false
                default: break
                }
                if lhs.repoName != rhs.repoName {
                    return lhs.repoName.localizedCaseInsensitiveCompare(rhs.repoName)
                        == .orderedAscending
                }
                return lhs.number < rhs.number
            }
    }

    /// Agent tiles across the whole snapshot: waiting first, then busy,
    /// then everything else; stable by name within a band. Ignored agents
    /// are excluded — they live in `ignoredAgentTiles`.
    public var agentTiles: [AgentTileState] {
        allAgentTiles.filter { !isAgentIgnored($0.id) }
    }

    /// Tiles for ignored agents whose sessions are still live, alphabetical.
    public var ignoredAgentTiles: [AgentTileState] {
        allAgentTiles.filter { isAgentIgnored($0.id) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var allAgentTiles: [AgentTileState] {
        var tiles: [AgentTileState] = []
        for r in repos {
            for a in r.agents {
                tiles.append(AgentTileState(agent: a, location: r.repo.name, path: r.repo.path))
            }
            for wt in r.worktrees {
                for a in wt.agents {
                    tiles.append(AgentTileState(
                        agent: a,
                        location: "\(r.repo.name) ⎇ \(wt.worktree.name)",
                        path: wt.worktree.path))
                }
            }
        }
        for a in otherAgents {
            tiles.append(AgentTileState(
                agent: a, location: Self.abbreviatePath(a.cwd), path: a.cwd))
        }
        return tiles.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    /// Top-level repo tiles: most recently touched first, then alphabetical.
    /// Ignored repos are excluded — they live in `ignoredRepoTiles`. Worktrees
    /// have their own list, `worktreeTiles`.
    public var repoTiles: [RepoTileState] {
        visibleRepos.map(RepoTileState.init(repo:)).sorted(by: Self.recencyOrder)
    }

    /// Worktree tiles of visible repos, same ordering as repo tiles.
    /// A hidden repo's worktrees hide with it.
    public var worktreeTiles: [RepoTileState] {
        visibleRepos.flatMap(visibleWorktreeTiles(of:)).sorted(by: Self.recencyOrder)
    }

    private func visibleWorktreeTiles(of r: RepoOverview) -> [RepoTileState] {
        r.worktrees.filter { !isRepoIgnored($0.worktree.path) }
            .map { RepoTileState(worktree: $0, parent: r) }
    }

    static func recencyOrder(_ lhs: RepoTileState, _ rhs: RepoTileState) -> Bool {
        switch (lhs.lastActivity, rhs.lastActivity) {
        case let (l?, r?) where l != r: return l > r
        case (.some, .none): return true
        case (.none, .some): return false
        default:
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: Recent-N sections

    public var prSection: TileSection<PRTileState> {
        section(prTiles, .prs)
    }

    public var worktreeSection: TileSection<RepoTileState> {
        section(worktreeTiles, .worktrees)
    }

    public var repoSection: TileSection<RepoTileState> {
        section(repoTiles, .repos)
    }

    private func section<T>(_ all: [T], _ id: DashboardSection) -> TileSection<T> {
        TileSection(all: all, isExpanded: config.isSectionExpanded(id))
    }

    /// Tiles for ignored repos and individually ignored worktrees of
    /// still-visible repos, alphabetical. (A hidden repo's worktrees hide
    /// with it and don't get their own rows.)
    public var ignoredRepoTiles: [RepoTileState] {
        let repoTiles = repos.filter { isRepoIgnored($0.repo.path) }
            .map(RepoTileState.init(repo:))
        let worktreeTiles = repos.filter { !isRepoIgnored($0.repo.path) }
            .flatMap { r in
                r.worktrees.filter { isRepoIgnored($0.worktree.path) }
                    .map { RepoTileState(worktree: $0, parent: r) }
            }
        return (repoTiles + worktreeTiles)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
