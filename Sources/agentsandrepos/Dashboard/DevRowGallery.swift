import AgentsAndReposCore
import SwiftUI

/// Dev-only row gallery: one of every ranked-row variant in every severity,
/// built from synthetic fixtures so design passes don't depend on real repos
/// happening to be in the right states.
///
/// Enable with `AGENTSANDREPOS_DEV_ROWS=1` in the environment or a
/// `--dev-rows` launch argument; invisible otherwise.
enum DevMode {
    static let showRowGallery =
        ProcessInfo.processInfo.environment["AGENTSANDREPOS_DEV_ROWS"] == "1"
        || CommandLine.arguments.contains("--dev-rows")
}

struct DevRowGalleryView: View {
    let actions: DashboardActions
    /// Survives relaunches so the gallery stays out of the way once hidden.
    @AppStorage("devRowGalleryExpanded") private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Dev · Row Gallery")
                Spacer()
                Button(expanded ? "Hide" : "Show") { expanded.toggle() }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if expanded {
                galleryRows
            }
        }
    }

    @ViewBuilder
    private var galleryRows: some View {
        VStack(alignment: .leading, spacing: 5) {
                ForEach(Self.fixtures, id: \.label) { fixture in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fixture.label)
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        RankedRowView(item: fixture.tile, actions: actions)
                    }
                }
                Text("unreachable lump")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                UnreachableLumpView(
                    tiles: Self.unreachableFixtures, isExpanded: false, actions: actions)
        }
    }

    // MARK: - Fixtures

    private struct Fixture {
        let label: String
        let tile: RankedTile
    }

    private static let fixtures: [Fixture] = [
        Fixture(
            label: "repo · urgent · failed run + failing PR + local work",
            tile: .repo(repoTile(
                name: "urgent-repo",
                git: GitState(branch: "main", ahead: 3, dirty: 12, untracked: 3),
                prs: [pr(.fail, number: 91)],
                runs: [run(.failed, workflow: "Deploy")]))),
        Fixture(
            label: "repo · urgent · git status broken",
            tile: .repo(repoTile(
                name: "broken-repo",
                git: GitState(branch: "main", statusError: "index locked")))),
        Fixture(
            label: "repo · attention · agent waiting · unmerged branch",
            tile: .repo(repoTile(
                name: "waiting-repo",
                git: GitState(branch: "feat/checkout", dirty: 4, mergeState: .unmerged),
                agents: [agent(.waiting(nil), name: "fix-tests")]))),
        Fixture(
            label: "repo · info · local work + busy agent + running deploy · merged locally",
            tile: .repo(repoTile(
                name: "active-repo",
                git: GitState(
                    branch: "feat/pricing", ahead: 2, dirty: 7, untracked: 1,
                    mergeState: .mergedLocal),
                agents: [agent(.busy, name: "refactor")],
                runs: [run(.running, workflow: "Deploy")]))),
        Fixture(
            label: "repo · ok · clean, recent passed deploy",
            tile: .repo(repoTile(
                name: "green-repo",
                git: GitState(branch: "main"),
                runs: [run(.passed, workflow: "Deploy")]))),
        Fixture(
            label: "repo · muted · clean but unreachable",
            tile: .repo(repoTile(
                name: "offline-repo",
                git: GitState(branch: "main", fetchError: "auth")))),
        Fixture(
            label: "worktree · info · new files · merged upstream",
            tile: .repo(worktreeTile())),
        Fixture(
            label: "PR · urgent · CI failing",
            tile: .pr(prTile(pr(.fail, number: 101), title: "Fix checkout crash"))),
        Fixture(
            label: "PR · attention · changes requested",
            tile: .pr(prTile(
                pr(.pass, number: 102, reviewDecision: "CHANGES_REQUESTED"),
                title: "Add pricing table"))),
        Fixture(
            label: "PR · info · CI running",
            tile: .pr(prTile(pr(.pending, number: 103), title: "Migrate build to SPM"))),
        Fixture(
            label: "PR · ok · approved, CI passing",
            tile: .pr(prTile(
                pr(.pass, number: 104, reviewDecision: "APPROVED"),
                title: "Bump dependencies"))),
        Fixture(
            label: "PR · muted · draft",
            tile: .pr(prTile(pr(.none, number: 105, isDraft: true), title: "WIP: dark mode"))),
    ]

    private static var unreachableFixtures: [RepoTileState] {
        (1...3).map { i in
            repoTile(
                name: "work-repo-\(i)", git: GitState(branch: "main", fetchError: "auth"))
        }
    }

    // MARK: - Fixture builders

    private static func repoTile(
        name: String, git: GitState?, agents: [AgentSession] = [],
        prs: [PullRequest] = [], runs: [WorkflowRun] = []
    ) -> RepoTileState {
        var g = git
        g?.lastActivity = Date().addingTimeInterval(-300)
        return RepoTileState(
            repo: RepoOverview(
                repo: Repo(path: "/dev/fixtures/\(name)", name: name, root: "/dev/fixtures"),
                git: g, agents: agents, prs: prs, worktrees: [],
                githubRepo: "dev/\(name)", runs: runs))
    }

    private static func worktreeTile() -> RepoTileState {
        let wt = WorktreeOverview(
            worktree: Worktree(
                path: "/dev/fixtures/gallery-repo-feature", branch: "feature",
                detached: false, isClaudeManaged: true),
            git: GitState(
                branch: "feature", untracked: 2,
                lastActivity: Date().addingTimeInterval(-7200), mergeState: .mergedRemote),
            agents: [])
        let parent = RepoOverview(
            repo: Repo(path: "/dev/fixtures/gallery-repo", name: "gallery-repo", root: "/dev/fixtures"),
            git: GitState(branch: "main"), agents: [], prs: [], worktrees: [wt],
            githubRepo: "dev/gallery-repo")
        return RepoTileState(worktree: wt, parent: parent)
    }

    private static func prTile(_ pr: PullRequest, title: String) -> PRTileState {
        PRTileState(
            pr: PullRequest(
                number: pr.number, title: title, url: pr.url, isDraft: pr.isDraft,
                author: pr.author, headRefName: pr.headRefName,
                reviewDecision: pr.reviewDecision, ci: pr.ci,
                failingChecks: pr.failingChecks,
                updatedAt: Date().addingTimeInterval(-1800)),
            repoName: "gallery-repo")
    }

    private static func pr(
        _ ci: PullRequest.CIStatus, number: Int, reviewDecision: String? = nil,
        isDraft: Bool = false
    ) -> PullRequest {
        PullRequest(
            number: number, title: "add promo pricing to checkout",
            url: "https://github.com/dev/gallery-repo/pull/\(number)",
            isDraft: isDraft, author: "casey", headRefName: "feat/gallery-\(number)",
            reviewDecision: reviewDecision, ci: ci,
            failingChecks: ci == .fail ? ["PR Check", "ci/lint"] : [])
    }

    private static func agent(
        _ status: AgentSession.Status, name: String
    ) -> AgentSession {
        AgentSession(
            pid: 1, sessionId: "dev-\(name)", cwd: "/dev/fixtures", name: name,
            kind: "interactive", status: status, startedAt: nil, updatedAt: nil)
    }

    private static func run(
        _ state: WorkflowRun.State, workflow: String
    ) -> WorkflowRun {
        WorkflowRun(
            id: workflow.hashValue, workflowName: workflow, title: "dev fixture",
            branch: "main", event: "push", state: state,
            url: "https://github.com/dev/gallery-repo/actions",
            updatedAt: Date().addingTimeInterval(-120))
    }
}
