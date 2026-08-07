import Foundation

/// Scores a tile for the unified dashboard feed: how badly it wants eyes,
/// blending state severity with recency of activity. Higher sorts first.
public enum AttentionScore {
    /// urgent 100 > attention 60 > info 30 > ok 10 > muted 0 — spaced so a
    /// burst of recency can lift an ok item over a stale attention one, but
    /// never over anything urgent.
    static func base(_ severity: TileSeverity) -> Double {
        switch severity {
        case .urgent: return 100
        case .attention: return 60
        case .info: return 30
        case .ok: return 10
        case .muted: return 0
        }
    }

    /// Bucketed decay: touched in the last 15 minutes earns 50, fading to 0
    /// past a week. Buckets keep ordering stable between re-renders instead
    /// of reshuffling on every tick of a continuous curve.
    static func recency(_ date: Date?, now: Date) -> Double {
        guard let date else { return 0 }
        switch now.timeIntervalSince(date) {
        case ..<900: return 50
        case ..<3600: return 35
        case ..<21600: return 20
        case ..<86400: return 10
        case ..<604_800: return 4
        default: return 0
        }
    }

    public static func score(severity: TileSeverity, lastActivity: Date?, now: Date) -> Double {
        base(severity) + recency(lastActivity, now: now)
    }
}

/// One entry in the unified feed: a repo/worktree tile or a PR tile, ranked
/// together on a shared score.
public enum RankedTile: Sendable, Equatable, Identifiable {
    case repo(RepoTileState)
    case pr(PRTileState)

    /// Namespaced so a PR and a repo can never collide in the grid's ForEach.
    public var id: String {
        switch self {
        case .repo(let r): return "repo:\(r.id)"
        case .pr(let p): return "pr:\(p.id)"
        }
    }

    public var severity: TileSeverity {
        switch self {
        case .repo(let r): return r.severity
        case .pr(let p): return p.severity
        }
    }

    public var lastActivity: Date? {
        switch self {
        case .repo(let r): return r.lastActivity
        case .pr(let p): return p.updatedAt
        }
    }

    var sortName: String {
        switch self {
        case .repo(let r): return r.name
        case .pr(let p): return p.reference
        }
    }

    public func score(now: Date) -> Double {
        AttentionScore.score(severity: severity, lastActivity: lastActivity, now: now)
    }
}

extension Snapshot {
    /// Everything below the agents section, stack-ranked: repos, worktrees,
    /// and PRs in one list, most urgent-and-recent first. Ties break by
    /// recency, then name, so the order is deterministic. Repos whose only
    /// problem is an unreachable remote are lumped into `unreachableTiles`
    /// instead — see `isQuietUnreachable`.
    public func rankedTiles(now: Date = Date()) -> [RankedTile] {
        let all =
            repoTiles.filter { !$0.isQuietUnreachable }.map(RankedTile.repo)
            + worktreeTiles.filter { !$0.isQuietUnreachable }.map(RankedTile.repo)
            + prTiles.map(RankedTile.pr)
        return all
            .map { (tile: $0, score: $0.score(now: now)) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                switch (lhs.tile.lastActivity, rhs.tile.lastActivity) {
                case let (l?, r?) where l != r: return l > r
                case (.some, .none): return true
                case (.none, .some): return false
                default: break
                }
                return lhs.tile.sortName.localizedCaseInsensitiveCompare(rhs.tile.sortName)
                    == .orderedAscending
            }
            .map(\.tile)
    }

    /// Repos (and worktrees) excluded from the ranked list because their only
    /// issue is a fetch failure — collapsed into one "can't connect" row.
    /// Recency-ordered for when the lump is expanded.
    public var unreachableTiles: [RepoTileState] {
        (repoTiles + worktreeTiles).filter(\.isQuietUnreachable)
    }

    /// Rows are ~3× denser than tiles, so the ranked feed defaults to a
    /// deeper cut than the grid sections did.
    public static var rankedRecentLimit: Int { 12 }

    public func rankedSection(now: Date = Date()) -> TileSection<RankedTile> {
        TileSection(
            all: rankedTiles(now: now),
            isExpanded: config.isSectionExpanded(.ranked),
            limit: Self.rankedRecentLimit)
    }
}
