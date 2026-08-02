import Foundation

/// A worktree plus its live state, nested under a repo.
public struct WorktreeOverview: Sendable, Equatable, Identifiable {
    public let worktree: Worktree
    public let git: GitState?
    public let agents: [AgentSession]

    public var id: String { worktree.path }

    public init(worktree: Worktree, git: GitState?, agents: [AgentSession]) {
        self.worktree = worktree
        self.git = git
        self.agents = agents
    }

    /// Claude-managed if flagged by path, or if an agent is actually working inside it.
    public var isClaudeManaged: Bool { worktree.isClaudeManaged || !agents.isEmpty }
}

/// One repo plus everything the UI shows about it.
public struct RepoOverview: Sendable, Equatable, Identifiable {
    public let repo: Repo
    public let git: GitState?
    public let agents: [AgentSession]
    public let prs: [PullRequest]
    public let worktrees: [WorktreeOverview]
    /// "owner/name" when origin points at github.com.
    public let githubRepo: String?

    public var id: String { repo.path }

    public init(
        repo: Repo, git: GitState?, agents: [AgentSession], prs: [PullRequest],
        worktrees: [WorktreeOverview], githubRepo: String?
    ) {
        self.repo = repo
        self.git = git
        self.agents = agents
        self.prs = prs
        self.worktrees = worktrees
        self.githubRepo = githubRepo
    }

    public var allAgents: [AgentSession] { agents + worktrees.flatMap(\.agents) }

    /// Most recent activity across the main repo and its worktrees.
    public var lastActivity: Date? {
        ([git?.lastActivity] + worktrees.map { $0.git?.lastActivity })
            .compactMap { $0 }
            .max()
    }

    public var needsAttention: Bool {
        if git?.needsAttention == true { return true }
        if worktrees.contains(where: { $0.git?.needsAttention == true }) { return true }
        return false
    }
}

public enum GHAvailability: Sendable, Equatable {
    case unknown
    case ok
    case notInstalled
    case notAuthenticated
    case error(String)
}

/// Immutable aggregate of everything the UI renders.
public struct Snapshot: Sendable, Equatable {
    public var repos: [RepoOverview]
    /// Live agent sessions whose cwd didn't match any discovered repo/worktree.
    public var otherAgents: [AgentSession]
    public var ghAvailability: GHAvailability
    public var lastFetchAt: Date?
    public var config: AppConfig
    public var generatedAt: Date

    public init(
        repos: [RepoOverview], otherAgents: [AgentSession], ghAvailability: GHAvailability,
        lastFetchAt: Date?, config: AppConfig, generatedAt: Date
    ) {
        self.repos = repos
        self.otherAgents = otherAgents
        self.ghAvailability = ghAvailability
        self.lastFetchAt = lastFetchAt
        self.config = config
        self.generatedAt = generatedAt
    }

    public static let empty = Snapshot(
        repos: [], otherAgents: [], ghAvailability: .unknown,
        lastFetchAt: nil, config: AppConfig(), generatedAt: .distantPast
    )

    /// `generatedAt` is a wall-clock stamp that differs on every publish; it
    /// must not participate in equality or the "skip no-op publishes" dedupe
    /// never fires and the UI re-renders on every poll tick.
    public static func == (a: Snapshot, b: Snapshot) -> Bool {
        a.repos == b.repos && a.otherAgents == b.otherAgents
            && a.ghAvailability == b.ghAvailability
            && a.lastFetchAt == b.lastFetchAt
            && a.config == b.config
    }

    public var allAgents: [AgentSession] {
        repos.flatMap(\.allAgents) + otherAgents
    }

    public var allPRs: [(repo: RepoOverview, pr: PullRequest)] {
        repos.flatMap { r in r.prs.map { (r, $0) } }
    }
}
