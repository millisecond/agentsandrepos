import Foundation

/// Thin wrapper around spawning `/usr/bin/git`. All calls carry an anti-hang
/// environment (no terminal prompts, ssh BatchMode) and a hard timeout —
/// essential when running under launchd in the background.
public enum GitClient {
    public static let binary = "/usr/bin/git"

    public static func environment() -> [String: String] {
        [
            "PATH": "/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
            "LC_ALL": "C",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_ASKPASS": "/usr/bin/false",
            "SSH_ASKPASS": "/usr/bin/false",
            "GIT_SSH_COMMAND": "ssh -oBatchMode=yes -oConnectTimeout=10",
            "GIT_OPTIONAL_LOCKS": "0",
        ]
    }

    public static func status(_ repoPath: String) async -> GitState {
        let r = await ProcessRunner.run(
            binary,
            ["-C", repoPath, "status", "--porcelain=v2", "--branch", "--untracked-files=normal"],
            environment: environment(), timeout: 10)
        guard r.ok else {
            var s = GitState()
            s.statusError = r.timedOut ? "status timed out" : firstLine(r.stderrText)
            return s
        }
        return PorcelainV2Parser.parse(r.stdoutText)
    }

    /// Returns nil on success, or a short error message.
    public static func fetch(_ repoPath: String) async -> String? {
        let r = await ProcessRunner.run(
            binary, ["-C", repoPath, "fetch", "--quiet", "--prune"],
            environment: environment(), timeout: 60)
        if r.timedOut { return "fetch timed out" }
        if r.exitCode != 0 { return firstLine(r.stderrText, fallback: "fetch failed (\(r.exitCode))") }
        return nil
    }

    public static func remoteNames(_ repoPath: String) async -> [String] {
        let r = await ProcessRunner.run(
            binary, ["-C", repoPath, "remote"], environment: environment(), timeout: 10)
        guard r.ok else { return [] }
        return r.stdoutText.split(separator: "\n").map(String.init)
    }

    public static func remoteURL(_ repoPath: String, remote: String = "origin") async -> String? {
        let r = await ProcessRunner.run(
            binary, ["-C", repoPath, "remote", "get-url", remote],
            environment: environment(), timeout: 10)
        guard r.ok else { return nil }
        let url = r.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    /// Committer date of HEAD, or nil for empty/broken repos.
    public static func lastCommitDate(_ repoPath: String) async -> Date? {
        let r = await ProcessRunner.run(
            binary, ["-C", repoPath, "log", "-1", "--format=%ct"],
            environment: environment(), timeout: 10)
        guard r.ok,
            let epoch = TimeInterval(r.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    /// Is `ancestor` contained in `descendant`'s history? Nil when git can't
    /// answer (bad oid, timeout) — distinct from a definite no.
    public static func isAncestor(
        _ repoPath: String, _ ancestor: String, of descendant: String
    ) async -> Bool? {
        let r = await ProcessRunner.run(
            binary, ["-C", repoPath, "merge-base", "--is-ancestor", ancestor, descendant],
            environment: environment(), timeout: 10)
        if r.timedOut { return nil }
        switch r.exitCode {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    public static func worktrees(_ repoPath: String) async -> [Worktree] {
        let r = await ProcessRunner.run(
            binary, ["-C", repoPath, "worktree", "list", "--porcelain"],
            environment: environment(), timeout: 10)
        guard r.ok else { return [] }
        return WorktreeListParser.parse(r.stdoutText, mainPath: repoPath)
    }

    /// Fast-forwards the repo to its upstream ONLY when it is provably safe:
    /// clean tree, on a branch with an upstream, strictly behind (never diverged),
    /// and no in-progress merge/rebase/cherry-pick/bisect. `--ff-only` is the
    /// final backstop — this path can never lose work. Never pushes, never resets.
    @discardableResult
    public static func fastForwardIfSafe(_ repoPath: String) async -> Bool {
        let s = await status(repoPath)
        guard s.statusError == nil, !s.detached, s.upstream != nil,
            s.dirty == 0, s.untracked == 0, s.ahead == 0, s.behind > 0
        else { return false }

        let gd = await ProcessRunner.run(
            binary, ["-C", repoPath, "rev-parse", "--git-dir"],
            environment: environment(), timeout: 5)
        guard gd.ok else { return false }
        var gitDir = gd.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !gitDir.hasPrefix("/") { gitDir = repoPath + "/" + gitDir }
        for marker in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG",
                       "rebase-merge", "rebase-apply"] {
            if FileManager.default.fileExists(atPath: gitDir + "/" + marker) { return false }
        }

        let m = await ProcessRunner.run(
            binary, ["-C", repoPath, "merge", "--ff-only", "--quiet", "@{upstream}"],
            environment: environment(), timeout: 20)
        return m.ok
    }

    private static func firstLine(_ text: String, fallback: String = "git error") -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
