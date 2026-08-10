import Foundation

/// Where a non-main branch's commits stand relative to the repo's main
/// branch. Nil (absent) on main itself, detached HEADs, or repos with no
/// discernible main.
///
/// Detection is ancestry-based (`merge-base --is-ancestor`), so squash- or
/// rebase-merged branches read as `.unmerged` — their original commits really
/// aren't in main's history.
public enum BranchMergeState: String, Sendable, Equatable, Codable {
    /// Contained in origin's main — merged upstream, safe to clean up.
    case mergedRemote
    /// Contained in local main only (origin doesn't have it yet, or is stale).
    case mergedLocal
    /// Has commits no main knows about — genuinely new code.
    case unmerged

    public var label: String {
        switch self {
        case .mergedRemote: return "merged"
        case .mergedLocal: return "merged locally"
        case .unmerged: return "unmerged"
        }
    }

    /// Single-token form for text summaries (CLI, menus).
    public var compactLabel: String {
        switch self {
        case .mergedRemote: return "merged"
        case .mergedLocal: return "merged-local"
        case .unmerged: return "unmerged"
        }
    }

    public var help: String {
        switch self {
        case .mergedRemote: return "Branch is merged into origin's main"
        case .mergedLocal: return "Merged into local main; origin's main doesn't have it yet"
        case .unmerged: return "Has commits not on any main — new code"
        }
    }
}
