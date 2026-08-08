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
            "number,title,url,isDraft,author,headRefName,reviewDecision,statusCheckRollup,updatedAt",
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
                ci: reduceCI(obj["statusCheckRollup"]),
                failingChecks: failingCheckNames(obj["statusCheckRollup"]),
                updatedAt: (obj["updatedAt"] as? String)
                    .flatMap { try? Date($0, strategy: .iso8601) })
        }
    }

    /// Recent repo-level workflow runs (deploys, dispatches, scheduled jobs).
    /// Returns nil on transport/CLI error (caller keeps last-known runs).
    public static func listRecentRuns(
        _ ghPath: String, ownerRepo: String
    ) async -> [WorkflowRun]? {
        let args = [
            "run", "list", "--repo", ownerRepo, "--limit", "10",
            "--json",
            "databaseId,workflowName,displayTitle,status,conclusion,headBranch,event,url,updatedAt",
        ]
        let r = await ProcessRunner.run(
            ghPath, args, environment: environment(ghPath: ghPath), timeout: 25)
        guard r.ok else { return nil }
        return parseRunList(r.stdout, now: Date())
    }

    /// Keeps the runs worth showing: non-PR-triggered (PR runs already surface
    /// as PR CI), still running or finished within the last hour, newest run
    /// per workflow so a busy push cadence doesn't stack duplicates.
    static func parseRunList(_ data: Data, now: Date) -> [WorkflowRun]? {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return nil }
        let cutoff = now.addingTimeInterval(-3600)
        var seenWorkflows = Set<String>()
        var runs: [WorkflowRun] = []
        for obj in arr {
            guard let id = obj["databaseId"] as? Int,
                let workflow = obj["workflowName"] as? String,
                let url = obj["url"] as? String
            else { continue }
            let event = obj["event"] as? String ?? ""
            if event.hasPrefix("pull_request") { continue }
            let updatedAt = (obj["updatedAt"] as? String)
                .flatMap { try? Date($0, strategy: .iso8601) }
            let state = reduceRun(
                status: obj["status"] as? String, conclusion: obj["conclusion"] as? String)
            if state != .running, (updatedAt ?? .distantPast) < cutoff { continue }
            // gh returns newest first, so the first hit per workflow is current.
            guard seenWorkflows.insert(workflow).inserted else { continue }
            runs.append(
                WorkflowRun(
                    id: id,
                    workflowName: workflow,
                    title: obj["displayTitle"] as? String ?? "",
                    branch: obj["headBranch"] as? String ?? "",
                    event: event,
                    state: state,
                    url: url,
                    updatedAt: updatedAt))
        }
        return runs
    }

    static func reduceRun(status: String?, conclusion: String?) -> WorkflowRun.State {
        if (status ?? "").uppercased() != "COMPLETED" { return .running }
        switch (conclusion ?? "").uppercased() {
        case "SUCCESS": return .passed
        case "FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED": return .failed
        default: return .other
        }
    }

    /// Names of the failing entries in a statusCheckRollup — CheckRuns carry
    /// `name`, StatusContexts carry `context`.
    static func failingCheckNames(_ any: Any?) -> [String] {
        guard let items = any as? [[String: Any]] else { return [] }
        var names: [String] = []
        for item in items {
            let conclusion = (item["conclusion"] as? String)?.uppercased() ?? ""
            let state = (item["state"] as? String)?.uppercased() ?? ""
            let failed =
                ["FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"]
                .contains(conclusion) || ["FAILURE", "ERROR"].contains(state)
            if failed, let name = (item["name"] as? String) ?? (item["context"] as? String) {
                names.append(name)
            }
        }
        return names
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
