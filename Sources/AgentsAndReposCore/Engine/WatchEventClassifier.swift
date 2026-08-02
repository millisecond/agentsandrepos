import Foundation

/// The refresh work a batch of file events implies.
public struct WatchClassification: Equatable, Sendable {
    /// Repo/worktree paths whose `git status` should be refreshed.
    public var statusPaths: Set<String> = []
    /// Repo paths whose remote refs moved (a push, or a fetch that brought
    /// commits) — worth an early PR re-check.
    public var prRepoPaths: Set<String> = []
    /// A repo/worktree may have appeared or vanished — rescan the roots.
    public var rediscover = false

    public var isEmpty: Bool { statusPaths.isEmpty && prRepoPaths.isEmpty && !rediscover }

    public init() {}
}

/// Pure mapping from FSEvents paths to refresh actions, so the noisy parts
/// (git's own churn, build artifacts) can be unit-tested away from the engine.
public enum WatchEventClassifier {
    static let ignoredBasenames: Set<String> = [".DS_Store"]

    public static func classify(
        eventPaths: [String], knownPaths: [String], roots: [String], maxDepth: Int
    ) -> WatchClassification {
        var out = WatchClassification()
        // Longest containing path wins: worktrees are deeper than or disjoint
        // from main repos.
        let known = knownPaths.sorted { $0.count > $1.count }
        let expandedRoots = roots.map { ($0 as NSString).expandingTildeInPath }
        for raw in eventPaths {
            let path = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            if ignoredBasenames.contains((path as NSString).lastPathComponent) { continue }
            if let owner = known.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                classifyInsideRepo(path: path, owner: owner, into: &out)
            } else {
                classifyOutsideRepos(
                    path: path, roots: expandedRoots, maxDepth: max(1, maxDepth), into: &out)
            }
        }
        return out
    }

    private static func classifyInsideRepo(
        path: String, owner: String, into out: inout WatchClassification
    ) {
        guard path.count > owner.count else {
            out.statusPaths.insert(owner)
            return
        }
        let comps = path.dropFirst(owner.count + 1).split(separator: "/").map(String.init)
        guard comps.first == ".git" else {
            // Working-tree change. Skip the artifact dirs discovery skips too.
            if comps.contains(where: { RepoDiscovery.skipNames.contains($0) }) { return }
            out.statusPaths.insert(owner)
            return
        }
        if comps.count >= 2 {
            switch comps[1] {
            case "objects", "logs":
                // Bulk churn; anything status-visible also touches refs/HEAD/index.
                return
            case "worktrees":
                out.rediscover = true
                out.statusPaths.insert(owner)
                return
            case "refs" where comps.count >= 3 && comps[2] == "remotes":
                out.prRepoPaths.insert(owner)
            default:
                break
            }
        }
        if comps.last?.hasSuffix(".lock") == true { return }
        out.statusPaths.insert(owner)
    }

    private static func classifyOutsideRepos(
        path: String, roots: [String], maxDepth: Int, into out: inout WatchClassification
    ) {
        for root in roots where path.hasPrefix(root + "/") {
            let comps = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
            // Discovery finds repos at most `maxDepth` below a root, so only
            // the first maxDepth+1 components can be a new repo's `.git`.
            for comp in comps.prefix(maxDepth + 1) {
                if comp == ".git" {
                    out.rediscover = true
                    return
                }
                if RepoDiscovery.skipNames.contains(comp) || comp.hasPrefix(".") { return }
            }
            // Shallow activity outside any known repo (e.g. a repo moved in
            // wholesale fires one rename event with no `.git` in it) — rescan.
            if comps.count <= maxDepth + 1 { out.rediscover = true }
            return
        }
    }
}
