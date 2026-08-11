import Foundation

/// Parses `git worktree list --porcelain` output into linked worktrees,
/// excluding the main worktree itself.
public enum WorktreeListParser {
    public static func parse(_ text: String, mainPath: String) -> [Worktree] {
        var out: [Worktree] = []
        var path: String?
        var branch: String?
        var detached = false
        var locked = false
        var prunable = false
        var isFirstEntry = true

        func flush() {
            defer {
                path = nil
                branch = nil
                detached = false
                locked = false
                prunable = false
            }
            guard let p = path else { return }
            // Git lists the main worktree first even when invoked from a
            // linked worktree; skipping by position (not just path) keeps a
            // worktree checkout from reporting its own main repo as linked.
            let isMain = isFirstEntry
            isFirstEntry = false
            let canonical = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
            guard !isMain, canonical != mainPath else { return }
            out.append(Worktree(
                path: canonical,
                branch: branch,
                detached: detached,
                isClaudeManaged: looksClaudeManaged(canonical),
                locked: locked,
                prunable: prunable))
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch ") {
                var b = String(line.dropFirst("branch ".count))
                if b.hasPrefix("refs/heads/") { b = String(b.dropFirst("refs/heads/".count)) }
                branch = b
            } else if line == "detached" {
                detached = true
            } else if line == "locked" || line.hasPrefix("locked ") {
                locked = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                prunable = true
            }
        }
        flush()
        return out
    }

    /// Heuristic for worktrees created by Claude Code (worktree isolation) or
    /// similar agent tooling.
    static func looksClaudeManaged(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains("/.claude/") || lower.contains("claude-worktree")
            || lower.contains("/worktrees/") || lower.contains("-worktree-")
    }
}
