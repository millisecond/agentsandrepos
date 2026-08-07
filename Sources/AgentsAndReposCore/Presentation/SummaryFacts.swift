import Foundation

/// How a tile's summary line gets produced. Code answers directly whenever it
/// can say the thing exactly (clean repo, pure ahead/behind, git error) — the
/// LLM's time is reserved for genuine synthesis: describing what uncommitted
/// work or an agent task is about.
public enum SummaryPlan: Sendable, Equatable {
    /// Nothing worth saying; render no summary line.
    case none
    /// Deterministic text, shown as-is with zero model time.
    case fixed(String)
    /// Facts for the model; also the cache key for the generated text.
    case generate(String)
}

/// Deterministic, telegraphic fact strings fed to the on-device LLM as prompt
/// input. Because they're pure functions of tile/snapshot state they double as
/// cache keys: same facts → reuse the previous summary, no regeneration.
public enum SummaryFacts {

    // MARK: - Plans

    public static func repoPlan(_ tile: RepoTileState) -> SummaryPlan {
        if tile.hasError { return .fixed("Git status failing.") }
        if tile.dirty == 0, tile.untracked == 0 {
            // Counts say it all — no need to burn model time.
            switch (tile.ahead, tile.behind) {
            // An unreachable remote means "in sync" can't be claimed.
            case (0, 0) where tile.unreachable: return .fixed("Can't reach remote.")
            case (0, 0): return .fixed("Clean and in sync.")
            case (let a, 0): return .fixed("Push \(a) commit\(a == 1 ? "" : "s").")
            case (0, let b): return .fixed("Pull \(b) commit\(b == 1 ? "" : "s").")
            case (let a, let b): return .fixed("Push \(a), pull \(b).")
            }
        }
        let facts = repoFacts(tile)
        return facts.isEmpty ? .fixed("Uncommitted local changes.") : .generate(facts)
    }

    /// A user message at most this long is already tile-sized — show it
    /// verbatim instead of asking the model to compress it.
    public static let verbatimUserMessageMaxChars = 60

    /// Agent tiles carry two independent summaries: the last user message and
    /// the last agent reply, each summarized with no other context. The raw
    /// message is the whole prompt (and cache key). Short messages skip the
    /// model entirely and render as typed.
    public static func agentUserPlan(_ tile: AgentTileState) -> SummaryPlan {
        guard let msg = tile.task.lastUserMessage else { return .none }
        if msg.count <= verbatimUserMessageMaxChars { return .fixed(msg) }
        return .generate(msg)
    }

    public static func agentAgentPlan(_ tile: AgentTileState) -> SummaryPlan {
        tile.task.lastAgentMessage.map { .generate($0) } ?? .none
    }

    public static func workspacePlan(_ snap: Snapshot) -> SummaryPlan {
        let repos = snap.repoTiles + snap.worktreeTiles
        let quiet = snap.agentTiles.isEmpty && repos.allSatisfy {
            $0.dirty == 0 && $0.untracked == 0 && $0.ahead == 0 && $0.behind == 0
                && !$0.hasError
        }
        if quiet {
            return repos.isEmpty ? .none : .fixed("All quiet — everything clean and in sync.")
        }
        return .generate(workspaceFacts(snap))
    }

    /// Stable key for a summary slot. The `:user`/`:asst` suffix selects the
    /// summarizer's instructions for the two agent slots.
    public static func repoKey(_ tile: RepoTileState) -> String { "repo:\(tile.id)" }
    public static func agentUserKey(_ tile: AgentTileState) -> String { "agent:\(tile.id):user" }
    public static func agentAgentKey(_ tile: AgentTileState) -> String { "agent:\(tile.id):asst" }
    public static let workspaceKey = "workspace"

    /// Naming signal only: what the uncommitted work is about. Counts, PR/CI
    /// state, and worktrees live on the tile as badges — repeating them here
    /// just tempts the model into restating them.
    public static func repoFacts(_ tile: RepoTileState) -> String {
        var lines: [String] = []
        if !tile.changedPaths.isEmpty {
            // Basenames read better than full paths and keep the prompt short.
            let names = tile.changedPaths.prefix(8)
                .map { $0.split(separator: "/").last.map(String.init) ?? $0 }
            lines.append("Changed files: \(names.joined(separator: ", "))")
        }
        for task in tile.agentTasks.prefix(3) {
            lines.append("Agent task: \(task)")
        }
        return lines.joined(separator: "\n")
    }

    public static func workspaceFacts(_ snap: Snapshot) -> String {
        let repos = snap.repoTiles + snap.worktreeTiles
        let agents = snap.agentTiles
        var parts = ["Developer workspace: \(repos.count) repo\(repos.count == 1 ? "" : "s")."]
        let dirty = repos.filter { $0.dirty > 0 || $0.untracked > 0 }.count
        let unsynced = repos.filter { $0.ahead > 0 || $0.behind > 0 }.count
        let errors = repos.filter(\.hasError).count
        if dirty > 0 { parts.append("\(dirty) with uncommitted changes.") }
        if unsynced > 0 { parts.append("\(unsynced) out of sync with upstream.") }
        if errors > 0 { parts.append("\(errors) with git errors.") }
        let busy = agents.filter { $0.phase == .busy }.count
        let waiting = agents.filter { $0.phase == .waiting }.count
        if agents.isEmpty {
            parts.append("No coding agents running.")
        } else {
            parts.append("\(agents.count) coding agent\(agents.count == 1 ? "" : "s"):")
            if busy > 0 { parts.append("\(busy) working,") }
            if waiting > 0 { parts.append("\(waiting) waiting on the user,") }
            let idle = agents.count - busy - waiting
            if idle > 0 { parts.append("\(idle) idle.") }
        }
        let prs = snap.visiblePRs
        if prs.count > 0 {
            let failing = prs.filter { $0.pr.ci == .fail }.count
            var pr = "\(prs.count) open pull request\(prs.count == 1 ? "" : "s")"
            if failing > 0 { pr += ", \(failing) with failing CI" }
            parts.append(pr + ".")
        }
        return parts.joined(separator: " ")
    }
}
