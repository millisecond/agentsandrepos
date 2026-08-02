import Foundation

/// A linked git worktree of a repo (from `git worktree list --porcelain`).
public struct Worktree: Sendable, Equatable, Identifiable {
    public let path: String
    public let branch: String?
    public let detached: Bool
    /// Heuristic: the worktree lives in a Claude-managed location.
    public let isClaudeManaged: Bool

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, branch: String?, detached: Bool, isClaudeManaged: Bool) {
        self.path = path
        self.branch = branch
        self.detached = detached
        self.isClaudeManaged = isClaudeManaged
    }
}
