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
    public let hasError: Bool
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
        self.hasError = git?.fetchError != nil || git?.statusError != nil
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

        self.agentDots = Self.dots(of: r.agents)
        self.worktrees = r.worktrees.map {
            WorktreeTileState(worktree: $0, repoName: r.repo.name)
        }

        self.severity = Self.severity(
            hasError: hasError, worstCI: worstCI, git: git, agentDots: agentDots)
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
        self.hasError = git?.fetchError != nil || git?.statusError != nil
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

        self.agentDots = Self.dots(of: wt.agents)
        self.worktrees = []

        self.severity = Self.severity(
            hasError: hasError, worstCI: worstCI, git: git, agentDots: agentDots)
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

    /// Precedence: CI-fail/error → urgent > dirty/untracked or waiting agent →
    /// attention > ahead/behind or busy agent → info > clean → ok > no git → muted.
    static func severity(
        hasError: Bool, worstCI: PullRequest.CIStatus, git: GitState?,
        agentDots: [TileSeverity]
    ) -> TileSeverity {
        if hasError || worstCI == .fail { return .urgent }
        guard let git else { return .muted }
        if !git.isClean || agentDots.contains(.attention) { return .attention }
        if git.ahead > 0 || git.behind > 0 || agentDots.contains(.info) { return .info }
        return .ok
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

/// One row in the dashboard's Hidden repo list, tagged with why it's hidden
/// (which also determines the row's icon and restore action).
public struct HiddenRepoEntry: Sendable, Equatable, Identifiable {
    public enum Reason: Sendable, Equatable {
        case ignored, stale
    }

    public let tile: RepoTileState
    public let reason: Reason

    public var id: String { tile.id }

    public init(tile: RepoTileState, reason: Reason) {
        self.tile = tile
        self.reason = reason
    }
}

extension Snapshot {
    public func isRepoIgnored(_ path: String) -> Bool {
        config.ignoredRepos.contains(path)
    }

    public func isAgentIgnored(_ sessionId: String) -> Bool {
        config.ignoredAgents.contains(sessionId)
    }

    /// Auto-hidden: no commits or file edits for `autoHideStaleDays`, and
    /// nothing live going on (no agents, no open PRs). Unknown activity keeps
    /// a repo visible; explicit ignoring takes precedence over staleness.
    /// Only applies to repos found by scanning a folder of repos — a repo the
    /// user added directly as a root is always shown.
    public func isRepoStale(_ r: RepoOverview) -> Bool {
        guard config.autoHideStaleDays > 0, !r.repo.isRoot,
            !isRepoIgnored(r.repo.path),
            !config.staleExemptRepos.contains(r.repo.path)
        else { return false }
        guard r.allAgents.isEmpty, r.prs.isEmpty else { return false }
        guard let activity = r.lastActivity else { return false }
        let cutoff = TimeInterval(config.autoHideStaleDays) * 86_400
        return generatedAt.timeIntervalSince(activity) > cutoff
    }

    /// All agent sessions except individually ignored ones — drives the
    /// status-item badge, so an ignored agent can't ping the menu bar.
    public var visibleAgents: [AgentSession] {
        allAgents.filter { !isAgentIgnored($0.sessionId) }
    }

    /// Repos except ignored and stale ones — drives badges and menu sections.
    public var visibleRepos: [RepoOverview] {
        repos.filter { !isRepoIgnored($0.repo.path) && !isRepoStale($0) }
    }

    /// Count of auto-hidden stale repos, for the dashboard's one-line note.
    public var staleRepoCount: Int {
        repos.count(where: isRepoStale)
    }

    /// PRs from visible repos only.
    public var visiblePRs: [(repo: RepoOverview, pr: PullRequest)] {
        allPRs.filter { !isRepoIgnored($0.repo.repo.path) }
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

    /// Repo and worktree tiles, one flat first-class list: needs-attention
    /// (by severity) first, then most recently touched, then alphabetical.
    /// Ignored/stale repos are excluded — they live in
    /// `ignoredRepoTiles`/`staleRepoTiles`; worktrees hide with their parent.
    public var repoTiles: [RepoTileState] {
        visibleRepos.flatMap { r in
            [RepoTileState(repo: r)] + visibleWorktreeTiles(of: r)
        }.sorted(by: Self.repoTileOrder)
    }

    private func visibleWorktreeTiles(of r: RepoOverview) -> [RepoTileState] {
        r.worktrees.filter { !isRepoIgnored($0.worktree.path) }
            .map { RepoTileState(worktree: $0, parent: r) }
    }

    static func repoTileOrder(_ lhs: RepoTileState, _ rhs: RepoTileState) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
        switch (lhs.lastActivity, rhs.lastActivity) {
        case let (l?, r?) where l != r: return l > r
        case (.some, .none): return true
        case (.none, .some): return false
        default:
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Tiles for stale auto-hidden repos, alphabetical.
    public var staleRepoTiles: [RepoTileState] {
        repos.filter(isRepoStale)
            .map(RepoTileState.init(repo:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The dashboard's Hidden repo list: explicitly ignored and stale
    /// auto-hidden repos merged into ONE alphabetical list, so an entry is
    /// findable by name regardless of why it's hidden.
    public var hiddenRepoEntries: [HiddenRepoEntry] {
        let entries =
            ignoredRepoTiles.map { HiddenRepoEntry(tile: $0, reason: .ignored) }
            + staleRepoTiles.map { HiddenRepoEntry(tile: $0, reason: .stale) }
        return entries.sorted {
            $0.tile.name.localizedCaseInsensitiveCompare($1.tile.name) == .orderedAscending
        }
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
