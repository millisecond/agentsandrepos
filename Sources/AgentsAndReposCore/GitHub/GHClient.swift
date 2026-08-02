import Foundation

/// Wraps the `gh` CLI. Auth is entirely delegated to the user's `gh auth login`.
public enum GHClient {
    public static func findBinary() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let c = String(dir) + "/gh"
                if FileManager.default.isExecutableFile(atPath: c) { return c }
            }
        }
        return nil
    }

    static func environment(ghPath: String) -> [String: String] {
        let ghDir = (ghPath as NSString).deletingLastPathComponent
        return [
            "HOME": NSHomeDirectory(),
            "PATH": "\(ghDir):/usr/bin:/bin",
            "GH_NO_UPDATE_NOTIFIER": "1",
            "GH_PROMPT_DISABLED": "1",
            "GH_PAGER": "cat",
            "NO_COLOR": "1",
        ]
    }

    public static func probe(_ ghPath: String) async -> GHAvailability {
        let r = await ProcessRunner.run(
            ghPath, ["auth", "status"], environment: environment(ghPath: ghPath), timeout: 15)
        if r.timedOut { return .error("gh auth status timed out") }
        return r.exitCode == 0 ? .ok : .notAuthenticated
    }

    /// Returns nil on transport/CLI error (caller keeps last-known PRs).
    public static func listOpenPRs(
        _ ghPath: String, ownerRepo: String, mineOnly: Bool
    ) async -> [PullRequest]? {
        var args = [
            "pr", "list", "--repo", ownerRepo, "--state", "open", "--limit", "50",
            "--json",
            "number,title,url,isDraft,author,headRefName,reviewDecision,statusCheckRollup",
        ]
        if mineOnly { args += ["--author", "@me"] }
        let r = await ProcessRunner.run(
            ghPath, args, environment: environment(ghPath: ghPath), timeout: 25)
        guard r.ok else { return nil }
        return parsePRList(r.stdout)
    }

    static func parsePRList(_ data: Data) -> [PullRequest]? {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return nil }
        return arr.compactMap { obj in
            guard let number = obj["number"] as? Int,
                let title = obj["title"] as? String,
                let url = obj["url"] as? String
            else { return nil }
            return PullRequest(
                number: number,
                title: title,
                url: url,
                isDraft: obj["isDraft"] as? Bool ?? false,
                author: (obj["author"] as? [String: Any])?["login"] as? String ?? "",
                headRefName: obj["headRefName"] as? String ?? "",
                reviewDecision: obj["reviewDecision"] as? String,
                ci: reduceCI(obj["statusCheckRollup"]))
        }
    }

    /// Collapses gh's statusCheckRollup (a mix of CheckRun {status, conclusion}
    /// and StatusContext {state} objects) into one pass/fail/pending signal.
    static func reduceCI(_ any: Any?) -> PullRequest.CIStatus {
        guard let items = any as? [[String: Any]], !items.isEmpty else { return .none }
        var pending = false
        for item in items {
            let conclusion = (item["conclusion"] as? String)?.uppercased() ?? ""
            let state = (item["state"] as? String)?.uppercased() ?? ""
            let status = (item["status"] as? String)?.uppercased() ?? ""
            if ["FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"]
                .contains(conclusion) || ["FAILURE", "ERROR"].contains(state)
            {
                return .fail
            }
            if !status.isEmpty && status != "COMPLETED" { pending = true }
            if ["PENDING", "EXPECTED", "IN_PROGRESS", "QUEUED", "WAITING"].contains(state)
                || conclusion == "PENDING"
            { pending = true }
            if status.isEmpty && state.isEmpty && conclusion.isEmpty { pending = true }
        }
        return pending ? .pending : .pass
    }
}
