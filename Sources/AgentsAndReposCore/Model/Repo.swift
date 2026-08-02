import Foundation

/// A discovered local git repository.
public struct Repo: Sendable, Hashable, Identifiable {
    /// Canonical absolute path (symlinks resolved) — the stable identity of the repo.
    public let path: String
    public let name: String
    /// The configured root folder this repo was discovered under.
    public let root: String
    /// True when the configured root IS this repo (the user added the repo
    /// folder directly, rather than it being found by scanning a folder of
    /// repos). Directly-added repos are never stale-hidden.
    public let isRoot: Bool

    public var id: String { path }

    public init(path: String, name: String, root: String, isRoot: Bool = false) {
        self.path = path
        self.name = name
        self.root = root
        self.isRoot = isRoot
    }
}
