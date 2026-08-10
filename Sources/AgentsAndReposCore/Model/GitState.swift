import Foundation

/// Local git status for a repo, as parsed from `git status --porcelain=v2 --branch`.
public struct GitState: Sendable, Equatable {
    public var branch: String?
    /// HEAD commit sha from `# branch.oid`; nil for unborn branches. Lets the
    /// engine cache the HEAD commit date instead of spawning `git log` per poll.
    public var headOid: String?
    public var detached: Bool
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    /// Tracked files with staged/unstaged/conflicted changes.
    public var dirty: Int
    public var untracked: Int
    /// Paths of changed/untracked files (capped) — feeds the LLM job description.
    public var changedPaths: [String]
    /// When the repo was last worked on: the newer of the HEAD commit time and
    /// the modification times of currently changed files. Drives auto-hiding
    /// of stale repos.
    public var lastActivity: Date?
    public var lastFetch: Date?
    public var fetchError: String?
    public var statusError: String?

    public init(
        branch: String? = nil,
        headOid: String? = nil,
        detached: Bool = false,
        upstream: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        dirty: Int = 0,
        untracked: Int = 0,
        changedPaths: [String] = [],
        lastActivity: Date? = nil,
        lastFetch: Date? = nil,
        fetchError: String? = nil,
        statusError: String? = nil
    ) {
        self.branch = branch
        self.headOid = headOid
        self.detached = detached
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.dirty = dirty
        self.untracked = untracked
        self.changedPaths = changedPaths
        self.lastActivity = lastActivity
        self.lastFetch = lastFetch
        self.fetchError = fetchError
        self.statusError = statusError
    }

    public var isClean: Bool { dirty == 0 && untracked == 0 }

    public var needsAttention: Bool {
        !isClean || ahead > 0 || behind > 0 || fetchError != nil || statusError != nil
    }

    public var hasError: Bool { fetchError != nil || statusError != nil }

    /// Short human summary like "main ●3 +1 ↑2↓1".
    public var summary: String {
        var parts: [String] = []
        if detached {
            parts.append("detached")
        } else if let branch {
            parts.append(branch)
        }
        if dirty > 0 { parts.append("●\(dirty)") }
        if untracked > 0 { parts.append("+\(untracked)") }
        if ahead > 0 || behind > 0 {
            var arrows = ""
            if ahead > 0 { arrows += "↑\(ahead)" }
            if behind > 0 { arrows += "↓\(behind)" }
            parts.append(arrows)
        }
        if fetchError != nil || statusError != nil { parts.append("⚠︎") }
        return parts.joined(separator: " ")
    }
}
