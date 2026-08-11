import Foundation

/// A linked git worktree of a repo (from `git worktree list --porcelain`).
public struct Worktree: Sendable, Equatable, Identifiable {
    public let path: String
    public let branch: String?
    public let detached: Bool
    /// Heuristic: the worktree lives in a Claude-managed location.
    public let isClaudeManaged: Bool
    /// Locked via `git worktree lock` — must never be labeled removable.
    public let locked: Bool
    /// Git's own flag: the directory is gone and only the admin record
    /// remains; `git worktree prune` would clean it up.
    public let prunable: Bool

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(
        path: String, branch: String?, detached: Bool, isClaudeManaged: Bool,
        locked: Bool = false, prunable: Bool = false
    ) {
        self.path = path
        self.branch = branch
        self.detached = detached
        self.isClaudeManaged = isClaudeManaged
        self.locked = locked
        self.prunable = prunable
    }
}
