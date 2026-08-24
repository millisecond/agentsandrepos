import Foundation

/// Owns all polling state and cadences, publishing immutable `Snapshot`s.
///
/// Tiers:
///   discovery  — scan roots + worktrees + remotes   every 10 min
///   agents     — read ~/.claude/sessions            every 3 s
///   status     — `git status` all repos/worktrees   every `statusIntervalSeconds`
///   fetch      — `git fetch` (+ optional ff)        every `fetchIntervalMinutes`
///   prs        — `gh pr list`                       every `prIntervalMinutes`
///
/// An FSEvents watcher over the roots (plus out-of-root worktrees) front-runs
/// the discovery/status/PR loops: file events trigger a targeted refresh
/// within seconds, and the loops remain the backstop for anything the
/// filesystem can't signal (remote PR/branch activity, dropped events).
public actor RefreshEngine {

    private struct RemoteInfo {
        var hasRemote: Bool
        var github: String?
    }

    private var config: AppConfig
    private let onSnapshot: @Sendable (Snapshot) -> Void

    private var repos: [Repo] = []
    private var worktreesByRepo: [String: [Worktree]] = [:]
    private var gitStates: [String: GitState] = [:]
    private var sessions: [AgentSession] = []
    private var agentDebouncer = AgentStatusDebouncer()
    private var activityMeter = AgentActivityMeter()
    private var prs: [String: [PullRequest]] = [:]
    private var runs: [String: [WorkflowRun]] = [:]
    private var remoteInfo: [String: RemoteInfo] = [:]

    private var ghPath: String?
    private var ghAvailability: GHAvailability = .unknown
    private var lastGHProbe: Date = .distantPast

    private var fetchBackoffUntil: [String: Date] = [:]
    private var fetchBackoffDelay: [String: TimeInterval] = [:]
    private var lastFetchAt: Date?

    /// HEAD commit dates keyed by path, valid while the oid matches — saves a
    /// `git log` spawn on every status poll.
    private var commitDateCache: [String: (oid: String, date: Date?)] = [:]

    /// Branch-vs-main ancestry keyed by path, valid while (branch head,
    /// local main, remote main) all stand still — the `merge-base` spawns
    /// happen only when one of those oids moves. The oids themselves come
    /// from RefReader (plain file reads), so checking staleness is free.
    private var mergeStateCache: [String: (key: String, state: BranchMergeState?)] = [:]
    private var refReader = RefReader()

    private var loops: [Task<Void, Never>] = []
    private var started = false

    /// Popover visibility, mirrored in by the app. Drives the on-open GitHub
    /// refresh and keeps the actions watch loop alive while the user looks.
    private var uiVisible = false
    private var lastFullRunsSweepAt: Date = .distantPast
    private var lastStatusSweepAt: Date = .distantPast
    /// Fast follower for in-flight workflow runs; nil whenever the popover is
    /// hidden and nothing is running, so idle cost is zero.
    private var actionsWatchLoop: Task<Void, Never>?

    private var fsWatcher: FSEventsWatcher?
    private var watchedPaths: Set<String> = []
    private var dirtyStatusPaths: Set<String> = []
    private var statusDrainScheduled = false
    private var rediscoverScheduled = false
    private var prNudgePending: Set<String> = []

    public init(config: AppConfig, onSnapshot: @escaping @Sendable (Snapshot) -> Void) {
        self.config = config
        self.onSnapshot = onSnapshot
    }

    // MARK: - Lifecycle

    public func start() {
        guard !started else { return }
        started = true
        Task {
            await self.discoverTick()
            self.agentsTick()
            await self.statusTick()
            self.publish()
            self.startLoops()
        }
    }

    public func stop() {
        cancelLoops()
        actionsWatchLoop?.cancel()
        actionsWatchLoop = nil
        fsWatcher = nil
        watchedPaths = []
        started = false
    }

    private func startLoops() {
        // Bootstrap already ran discovery/agents/status once, so those sleep first.
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                guard let self else { return }
                await self.discoverTick()
                await self.publish()
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                await self.agentsTick()
                await self.publish()
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(Double(max(5, await self.config.statusIntervalSeconds))))
                await self.statusTick()
                await self.publish()
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.fetchTick(force: false)
                await self.publish()
                try? await Task.sleep(for: .seconds(Double(max(1, await self.config.fetchIntervalMinutes)) * 60))
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.prTick()
                await self.runsTick()
                await self.publish()
                try? await Task.sleep(for: .seconds(Double(max(1, await self.config.prIntervalMinutes)) * 60))
            }
        })
    }

    private func cancelLoops() {
        for t in loops { t.cancel() }
        loops.removeAll()
    }

    // MARK: - Public controls

    /// Cheap refresh for menu-open: agents + git status.
    public func kickLight() async {
        agentsTick()
        await statusTick()
        publish()
    }

    /// Search-bar focus: the user is about to look something up, so bring
    /// anything mid-interval current now. Staleness-gated so focus/blur
    /// cycles cost nothing: a status sweep re-runs only after 30s, GitHub
    /// data after 60s (the same bar as popover-show). Deliberately no
    /// `git fetch` — search reads local state and PR metadata, and O(repos)
    /// network spawns aren't worth a focus event.
    public func kickSearch() async {
        agentsTick()
        if Date().timeIntervalSince(lastStatusSweepAt) > 30 {
            await statusTick()
        }
        publish()
        if Date().timeIntervalSince(lastFullRunsSweepAt) > 60 {
            await prTick()
            await runsTick()
            publish()
        }
    }

    /// Popover shown/hidden. On show, GitHub PR/actions data older than a
    /// minute refreshes immediately, and the actions watch loop spins up to
    /// follow anything running while the popover stays open.
    public func setUIVisible(_ visible: Bool) async {
        guard visible != uiVisible else { return }
        uiVisible = visible
        guard visible else { return }  // hidden: watch loop winds down itself
        if Date().timeIntervalSince(lastFullRunsSweepAt) > 60 {
            await prTick()
            await runsTick()
            publish()
        } else {
            startActionsWatchIfNeeded()
        }
    }

    // MARK: - Actions watch loop

    private var runningActionPaths: Set<String> {
        Set(runs.filter { $0.value.contains { $0.state == .running } }.map(\.key))
    }

    /// Runs while the popover is visible or any workflow run is in flight —
    /// checked every 20s, and exits the moment neither holds. Ticks are
    /// targeted at repos with running actions (O(active), not O(repos));
    /// while the popover is open a full sweep happens at most once a minute
    /// to pick up newly started runs.
    private func startActionsWatchIfNeeded() {
        guard started else { return }  // `snapshot` CLI runs without loops
        guard actionsWatchLoop == nil else { return }
        guard uiVisible || !runningActionPaths.isEmpty else { return }
        actionsWatchLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                if await self.actionsWatchTick() { return }
            }
        }
    }

    /// Returns true when the watch is done and the loop should exit.
    private func actionsWatchTick() async -> Bool {
        let active = runningActionPaths
        if !uiVisible, active.isEmpty {
            actionsWatchLoop = nil
            return true
        }
        if uiVisible, Date().timeIntervalSince(lastFullRunsSweepAt) > 60 {
            await runsTick()
        } else if !active.isEmpty {
            await runsTick(only: active)
        }
        publish()
        return false
    }

    /// Agents only — for the ~/.claude/sessions watcher, which fires on every
    /// session-file rewrite (constantly while agents work). Repo status has
    /// its own FSEvents path and poll loop; sweeping `git status` across all
    /// repos here spawned hundreds of processes per minute for nothing.
    public func kickAgents() {
        agentsTick()
        publish()
    }

    /// Full refresh: agents, status, fetch, PRs.
    public func kickAll() async {
        agentsTick()
        await discoverTick()
        await statusTick()
        publish()
        await fetchTick(force: true)
        await prTick()
        await runsTick()
        publish()
    }

    public func fetchNow(path: String) async {
        guard let repo = repos.first(where: { $0.path == path }) else { return }
        await fetchOne(repo, force: true)
        publish()
    }

    public func updateConfig(_ new: AppConfig) async {
        let rootsChanged = new.roots != config.roots || new.scanDepth != config.scanDepth
        let scopeChanged = new.prScope != config.prScope
        config = new
        ConfigStore.save(new)
        if started {
            cancelLoops()
            startLoops()
        }
        if rootsChanged { await discoverTick() }
        await statusTick()
        publish()
        if scopeChanged { await prTick(); publish() }
    }

    public func currentConfig() -> AppConfig { config }

    public func togglePRScope() async {
        var c = config
        c.prScope = c.prScope == .mine ? .all : .mine
        await updateConfig(c)
    }

    public func toggleAutoFetch() async {
        var c = config
        c.fetchEnabled.toggle()
        await updateConfig(c)
    }

    /// Ignore/unignore just mutate config and republish — no polling work
    /// changes, so skip the heavier updateConfig path.
    public func setRepoIgnored(path: String, ignored: Bool) {
        var c = config
        c.ignoredRepos.removeAll { $0 == path }
        if ignored { c.ignoredRepos.append(path) }
        config = c
        ConfigStore.save(c)
        publish()
    }

    public func setSectionExpanded(_ section: DashboardSection, expanded: Bool) {
        var c = config
        c.expandedSections.removeAll { $0 == section.rawValue }
        if expanded { c.expandedSections.append(section.rawValue) }
        config = c
        ConfigStore.save(c)
        publish()
    }

    public func setAgentIgnored(sessionId: String, ignored: Bool) {
        var c = config
        c.ignoredAgents.removeAll { $0 == sessionId }
        if ignored { c.ignoredAgents.append(sessionId) }
        // Sessions never come back once gone; prune dead ids so the list
        // doesn't grow forever.
        let live = Set(sessions.map(\.sessionId))
        c.ignoredAgents.removeAll { $0 != sessionId && !live.contains($0) }
        config = c
        ConfigStore.save(c)
        publish()
    }

    /// One-shot full pass for the `snapshot` CLI.
    public func snapshotOnce(includePRs: Bool) async -> Snapshot {
        await discoverTick()
        agentsTick()
        await statusTick()
        if includePRs {
            await prTick()
            await runsTick()
        }
        return currentSnapshot()
    }

    // MARK: - Ticks

    private func discoverTick() async {
        var found = RepoDiscovery.discover(roots: config.roots, maxDepth: config.scanDepth)

        // Enumerate worktrees + remotes for each repo.
        var newWorktrees: [String: [Worktree]] = [:]
        await forEachCapped(found, cap: 6) { repo in
            let wts = await GitClient.worktrees(repo.path)
            await self.storeWorktrees(repo.path, wts)
            await self.resolveRemoteIfNeeded(repo.path)
        }
        newWorktrees = worktreesByRepo

        // A linked worktree that also sits under a scanned root would be
        // discovered as a standalone repo — dedupe it out.
        let allWorktreePaths = Set(newWorktrees.values.flatMap { $0.map(\.path) })
        found.removeAll { allWorktreePaths.contains($0.path) }

        repos = found
        let valid = Set(found.map(\.path))
        worktreesByRepo = worktreesByRepo.filter { valid.contains($0.key) }
        prs = prs.filter { valid.contains($0.key) }
        runs = runs.filter { valid.contains($0.key) }
        let statusPaths = valid.union(worktreesByRepo.values.flatMap { $0.map(\.path) })
        mergeStateCache = mergeStateCache.filter { statusPaths.contains($0.key) }
        rebuildWatcherIfNeeded()
    }

    // MARK: - File events

    /// Watch the roots recursively; linked worktrees living outside every root
    /// (e.g. Claude-managed ones under ~/.claude) get their own entries.
    private func rebuildWatcherIfNeeded() {
        guard started else { return }  // `snapshot` CLI runs without a watcher
        let roots = config.roots.map { ($0 as NSString).expandingTildeInPath }
        var paths = Set(roots)
        for wt in worktreesByRepo.values.flatMap({ $0 }) {
            if !roots.contains(where: { wt.path == $0 || wt.path.hasPrefix($0 + "/") }) {
                paths.insert(wt.path)
            }
        }
        guard paths != watchedPaths || fsWatcher == nil else { return }
        watchedPaths = paths
        fsWatcher = FSEventsWatcher(paths: Array(paths)) { [weak self] eventPaths in
            guard let self else { return }
            Task { await self.noteFileEvents(eventPaths) }
        }
    }

    private func noteFileEvents(_ eventPaths: [String]) {
        let known = repos.map(\.path) + worktreesByRepo.values.flatMap { $0.map(\.path) }
        let c = WatchEventClassifier.classify(
            eventPaths: eventPaths, knownPaths: known,
            roots: config.roots, maxDepth: config.scanDepth)
        if c.rediscover { scheduleRediscover() }
        if !c.statusPaths.isEmpty {
            dirtyStatusPaths.formUnion(c.statusPaths)
            scheduleStatusDrain()
        }
        if !c.prRepoPaths.isEmpty { schedulePRNudge(c.prRepoPaths) }
    }

    /// Trailing 1s debounce: `git status` may itself rewrite .git/index, so the
    /// event→status→event echo converges instead of ping-ponging tightly.
    private func scheduleStatusDrain() {
        guard !statusDrainScheduled, !dirtyStatusPaths.isEmpty else { return }
        statusDrainScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.drainDirtyStatus()
        }
    }

    private func drainDirtyStatus() async {
        statusDrainScheduled = false
        let batch = dirtyStatusPaths
        dirtyStatusPaths.removeAll()
        guard !batch.isEmpty else { return }
        await forEachCapped(Array(batch), cap: 6) { path in
            await self.statusOne(path)
        }
        publish()
        scheduleStatusDrain()  // events that arrived while the batch ran
    }

    private func scheduleRediscover() {
        guard !rediscoverScheduled else { return }
        rediscoverScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.runScheduledRediscover()
        }
    }

    private func runScheduledRediscover() async {
        rediscoverScheduled = false
        await discoverTick()
        await statusTick()
        publish()
    }

    /// Remote refs moved (a push, or a fetch that brought commits). A PR often
    /// follows a push by a few seconds, so check once shortly after instead of
    /// waiting out the PR loop.
    private func schedulePRNudge(_ repoPaths: Set<String>) {
        let fresh = repoPaths.subtracting(prNudgePending)
        guard !fresh.isEmpty else { return }
        prNudgePending.formUnion(fresh)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            await self?.runPRNudge(fresh)
        }
    }

    private func runPRNudge(_ repoPaths: Set<String>) async {
        prNudgePending.subtract(repoPaths)
        await prTick(only: repoPaths)
        // A push usually kicks workflows on the same repo — check those too.
        await runsTick(only: repoPaths)
        publish()
    }

    private func storeWorktrees(_ repoPath: String, _ wts: [Worktree]) {
        worktreesByRepo[repoPath] = wts
    }

    private func resolveRemoteIfNeeded(_ repoPath: String) async {
        if remoteInfo[repoPath] != nil { return }
        if let url = await GitClient.remoteURL(repoPath) {
            remoteInfo[repoPath] = RemoteInfo(
                hasRemote: true, github: RemoteURLParser.githubOwnerRepo(from: url))
        } else {
            let names = await GitClient.remoteNames(repoPath)
            remoteInfo[repoPath] = RemoteInfo(hasRemote: !names.isEmpty, github: nil)
        }
    }

    private func agentsTick() {
        let now = Date()
        // The meter's evidence lags this tick by one (it records below, after
        // the debounce), but the hold only needs bucket-granularity truth.
        var read = agentDebouncer.apply(AgentSessionReader.read()) { id in
            activityMeter.bucketsSinceLastAppend(id: id, at: now)
        }
        // Transcript sizes come from the stat cache the read above just
        // warmed — the meter costs no filesystem access of its own.
        for i in read.indices {
            let s = read[i]
            if let size = TranscriptTaskReader.cachedTranscriptSize(
                cwd: s.cwd, sessionId: s.sessionId)
            {
                activityMeter.record(
                    id: s.sessionId, transcriptSize: size, busy: s.status.isBusy,
                    shell: s.status.isShell, at: now)
            }
            read[i] = s.withActivity(activityMeter.levels(id: s.sessionId, at: now))
        }
        activityMeter.prune(keeping: Set(read.map(\.sessionId)))
        sessions = read
    }

    private func statusTick() async {
        let paths = repos.map(\.path) + worktreesByRepo.values.flatMap { $0.map(\.path) }
        await forEachCapped(paths, cap: 6) { path in
            await self.statusOne(path)
        }
        lastStatusSweepAt = Date()
    }

    private func statusOne(_ path: String) async {
        var s = await GitClient.status(path)
        if let old = gitStates[path] {
            s.lastFetch = old.lastFetch
            s.fetchError = old.fetchError
        }
        if s.statusError == nil {
            s.lastActivity = RepoActivity.lastActivity(
                repoPath: path,
                commitDate: await commitDate(path, headOid: s.headOid),
                changedPaths: s.changedPaths)
            s.mergeState = await mergeState(path, status: s)
        }
        gitStates[path] = s
    }

    /// Where the checkout's branch stands vs main — nil on main itself,
    /// detached HEADs, or when no main branch can be found.
    private func mergeState(_ path: String, status s: GitState) async -> BranchMergeState? {
        guard !s.detached, let branch = s.branch, let head = s.headOid else { return nil }
        let refs = refReader.mainRefs(repoPath: owningRepoPath(of: path))
        guard let mainName = refs.branchName, branch != mainName else { return nil }

        let key = "\(head)|\(refs.localOid ?? "-")|\(refs.remoteOid ?? "-")"
        if let cached = mergeStateCache[path], cached.key == key { return cached.state }

        var state: BranchMergeState?
        if let remote = refs.remoteOid, await GitClient.isAncestor(path, head, of: remote) == true {
            state = .mergedRemote
        } else if let local = refs.localOid, await GitClient.isAncestor(path, head, of: local) == true {
            state = .mergedLocal
        } else if refs.localOid != nil || refs.remoteOid != nil {
            state = .unmerged
        }
        mergeStateCache[path] = (key, state)
        return state
    }

    /// Linked worktrees resolve refs through their parent repo; everything
    /// else is its own repo.
    private func owningRepoPath(of path: String) -> String {
        if let owner = worktreesByRepo.first(where: { $0.value.contains { $0.path == path } }) {
            return owner.key
        }
        return path
    }

    private func commitDate(_ path: String, headOid: String?) async -> Date? {
        if let oid = headOid, let cached = commitDateCache[path], cached.oid == oid {
            return cached.date
        }
        let date = await GitClient.lastCommitDate(path)
        if let oid = headOid { commitDateCache[path] = (oid, date) }
        return date
    }

    private func fetchTick(force: Bool) async {
        guard config.fetchEnabled || force else { return }
        let now = Date()
        let candidates = repos.filter { repo in
            guard remoteInfo[repo.path]?.hasRemote == true else { return false }
            if !force, let until = fetchBackoffUntil[repo.path], until > now { return false }
            return true
        }
        guard !candidates.isEmpty else { return }
        await forEachCapped(candidates, cap: 6) { repo in
            await self.fetchOne(repo, force: force)
        }
        lastFetchAt = Date()
    }

    private func fetchOne(_ repo: Repo, force: Bool) async {
        let err = await GitClient.fetch(repo.path)
        var s = gitStates[repo.path] ?? GitState()
        if let err {
            s.fetchError = err
            gitStates[repo.path] = s
            let delay = min((fetchBackoffDelay[repo.path] ?? 150) * 2, 3600)
            fetchBackoffDelay[repo.path] = delay
            fetchBackoffUntil[repo.path] = Date().addingTimeInterval(delay)
            return
        }
        s.fetchError = nil
        s.lastFetch = Date()
        gitStates[repo.path] = s
        fetchBackoffDelay[repo.path] = nil
        fetchBackoffUntil[repo.path] = nil

        await statusOne(repo.path)
        for wt in worktreesByRepo[repo.path] ?? [] { await statusOne(wt.path) }

        // Opt-in fast-forward: main worktree only, and never under an active
        // (busy/waiting) agent. Idle agents don't block it.
        if config.autoFastForward, !hasActiveAgent(at: repo.path) {
            let st = gitStates[repo.path] ?? GitState()
            if st.behind > 0, st.ahead == 0, st.isClean, !st.detached, st.upstream != nil {
                await GitClient.fastForwardIfSafe(repo.path)
                await statusOne(repo.path)
            }
        }
    }

    private func hasActiveAgent(at path: String) -> Bool {
        sessions.contains { s in
            s.status.isActive && (s.cwd == path || s.cwd.hasPrefix(path + "/"))
        }
    }

    /// Locates gh and (re)probes auth at most every 15 min. Nil unless usable.
    private func ghReady() async -> String? {
        if ghPath == nil { ghPath = GHClient.findBinary() }
        guard let gh = ghPath else {
            ghAvailability = .notInstalled
            return nil
        }
        if ghAvailability != .ok || Date().timeIntervalSince(lastGHProbe) > 900 {
            ghAvailability = await GHClient.probe(gh)
            lastGHProbe = Date()
        }
        return ghAvailability == .ok ? gh : nil
    }

    private func githubRepos(only: Set<String>?) -> [(Repo, String)] {
        repos.compactMap { repo -> (Repo, String)? in
            guard only == nil || only?.contains(repo.path) == true else { return nil }
            guard let owner = remoteInfo[repo.path]?.github else { return nil }
            return (repo, owner)
        }
    }

    private func prTick(only: Set<String>? = nil) async {
        guard let gh = await ghReady() else { return }
        let mineOnly = config.prScope == .mine
        await forEachCapped(githubRepos(only: only), cap: 3) { (repo, owner) in
            if let list = await GHClient.listOpenPRs(gh, ownerRepo: owner, mineOnly: mineOnly) {
                await self.storePRs(repo.path, list)
            }
        }
    }

    /// One gh spawn per repo — the 5-minute loop is the accepted budget for a
    /// full sweep; the actions watch loop passes `only` to stay O(active runs).
    private func runsTick(only: Set<String>? = nil) async {
        guard let gh = await ghReady() else { return }
        await forEachCapped(githubRepos(only: only), cap: 3) { (repo, owner) in
            if let recent = await GHClient.listRecentRuns(gh, ownerRepo: owner) {
                await self.storeRuns(repo.path, recent)
            }
        }
        if only == nil { lastFullRunsSweepAt = Date() }
        startActionsWatchIfNeeded()
    }

    private func storePRs(_ repoPath: String, _ list: [PullRequest]) {
        prs[repoPath] = list
    }

    private func storeRuns(_ repoPath: String, _ list: [WorkflowRun]) {
        runs[repoPath] = list
    }

    // MARK: - Snapshot assembly

    private func publish() {
        onSnapshot(currentSnapshot())
    }

    private func currentSnapshot() -> Snapshot {
        // Map each session to its innermost containing location (worktrees are
        // deeper than or disjoint from main repos, so longest prefix wins).
        var agentsByPath: [String: [AgentSession]] = [:]
        var other: [AgentSession] = []
        let allPaths =
            repos.map(\.path) + worktreesByRepo.values.flatMap { $0.map(\.path) }
        for session in sessions {
            let best =
                allPaths
                .filter { session.cwd == $0 || session.cwd.hasPrefix($0 + "/") }
                .max { $0.count < $1.count }
            if let best {
                agentsByPath[best, default: []].append(session)
            } else {
                other.append(session)
            }
        }

        let overviews = repos.map { repo in
            let wts = (worktreesByRepo[repo.path] ?? []).map { wt in
                WorktreeOverview(
                    worktree: wt,
                    git: gitStates[wt.path],
                    agents: agentsByPath[wt.path] ?? [])
            }
            return RepoOverview(
                repo: repo,
                git: gitStates[repo.path],
                agents: agentsByPath[repo.path] ?? [],
                prs: prs[repo.path] ?? [],
                worktrees: wts,
                githubRepo: remoteInfo[repo.path]?.github,
                runs: runs[repo.path] ?? [])
        }
        return Snapshot(
            repos: overviews,
            otherAgents: other,
            ghAvailability: ghAvailability,
            lastFetchAt: lastFetchAt,
            config: config,
            generatedAt: Date())
    }

    // MARK: - Helpers

    /// Runs `op` over items with at most `cap` in flight. The closures call back
    /// into this actor; the slow parts (subprocess waits) are suspension points,
    /// so real parallelism is preserved.
    private func forEachCapped<T: Sendable>(
        _ items: [T], cap: Int, _ op: @escaping @Sendable (T) async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = items.makeIterator()
            var inFlight = 0
            while inFlight < cap, let item = iterator.next() {
                group.addTask { await op(item) }
                inFlight += 1
            }
            while await group.next() != nil {
                if let item = iterator.next() {
                    group.addTask { await op(item) }
                }
            }
        }
    }
}
