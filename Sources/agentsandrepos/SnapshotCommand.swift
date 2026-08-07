import AgentsAndReposCore
import Foundation

final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func set(_ t: String) { lock.withLock { text = t } }
    func get() -> String { lock.withLock { text } }
}

/// `agentsandrepos snapshot` — one-shot plain-text overview.
enum SnapshotCommand {
    static func run(includePRs: Bool) async -> String {
        let config = ConfigStore.load()
        let engine = RefreshEngine(config: config) { _ in }
        let snap = await engine.snapshotOnce(includePRs: includePRs)
        return format(snap)
    }

    static func format(_ s: Snapshot) -> String {
        var lines: [String] = []

        let agents = s.allAgents
        lines.append("Agents (\(agents.count)):")
        if agents.isEmpty {
            lines.append("  none")
        }
        for r in s.repos {
            for a in r.agents {
                lines.append("  \(a.status.glyph) \(pad(a.displayName, 24)) \(pad(a.status.label, 28)) \(r.repo.name)  (pid \(a.pid))")
            }
            for wt in r.worktrees {
                for a in wt.agents {
                    lines.append("  \(a.status.glyph) \(pad(a.displayName, 24)) \(pad(a.status.label, 28)) \(r.repo.name) ⎇ \(wt.worktree.name)  (pid \(a.pid))")
                }
            }
        }
        for a in s.otherAgents {
            lines.append("  \(a.status.glyph) \(pad(a.displayName, 24)) \(pad(a.status.label, 28)) \(a.cwd)  (pid \(a.pid))")
        }

        let attention = s.repos.filter(\.needsAttention)
        lines.append("")
        lines.append("Repos (\(s.repos.count) discovered, \(attention.count) need attention):")
        for r in s.repos {
            let git = r.git
            let summary = git?.summary ?? "?"
            let marker = r.needsAttention ? "•" : " "
            lines.append("  \(marker) \(pad(r.repo.name, 28)) \(summary)")
            for wt in r.worktrees {
                let claude = wt.isClaudeManaged ? " [claude]" : ""
                lines.append("      ⎇ \(pad(wt.worktree.name, 24)) \(wt.git?.summary ?? wt.worktree.branch ?? "?")\(claude)")
            }
        }

        if s.ghAvailability == .ok || !s.allPRs.isEmpty {
            lines.append("")
            lines.append("Open PRs (\(s.config.prScope == .mine ? "mine" : "all")):")
            let prs = s.allPRs
            if prs.isEmpty { lines.append("  none") }
            for (repo, pr) in prs {
                let ci = pr.ci.glyph.isEmpty ? "" : " \(pr.ci.glyph)"
                let draft = pr.isDraft ? " (draft)" : ""
                lines.append("  \(pad(repo.repo.name, 20)) #\(pr.number) \(pr.title)\(ci)\(draft)")
            }
            let runs = s.allRuns
            if !runs.isEmpty {
                lines.append("")
                lines.append("Recent Actions:")
                for (repo, run) in runs {
                    lines.append("  \(pad(repo.repo.name, 20)) \(run.state.glyph) \(pad(run.workflowName, 20)) \(run.branch) (\(run.event), \(run.state.rawValue))")
                }
            }
        } else {
            lines.append("")
            switch s.ghAvailability {
            case .notInstalled: lines.append("PRs: gh CLI not found — install with `brew install gh`")
            case .notAuthenticated: lines.append("PRs: not logged in — run `gh auth login`")
            case .error(let e): lines.append("PRs: \(e)")
            default: break
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
}
