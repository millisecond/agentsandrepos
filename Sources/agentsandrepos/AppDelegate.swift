import AgentsAndReposCore
import AppKit

@MainActor
protocol MenuActionDelegate: AnyObject {
    func menuOpened()
    func refreshNow()
    func togglePRScope()
    func toggleAutoFetch()
    func fetchRepo(path: String)
    func setRepoIgnored(path: String, ignored: Bool)
    func setAgentIgnored(sessionId: String, ignored: Bool)
    func setSectionExpanded(section: DashboardSection, expanded: Bool)
    func openSettings()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: RefreshEngine!
    private var statusController: StatusItemController!
    private var settingsController: SettingsWindowController?
    private var watcher: DirectoryWatcher?
    private var lastSnapshot: Snapshot = .empty
    private let store = SnapshotStore()
    private let summaryService = SummaryService()
    private let updateChecker = UpdateChecker()
    private let perfMonitor = PerfMonitor()
    private var popoverController: DashboardPopoverController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = ConfigStore.load()
        statusController = StatusItemController(delegate: self)

        let actions = DashboardActions(delegate: self)
        popoverController = DashboardPopoverController(
            store: store, actions: actions, summaries: summaryService,
            updates: updateChecker, perf: perfMonitor)
        actions.closePopover = { [weak self] in self?.popoverController.close() }
        statusController.popoverController = popoverController
        updateChecker.start()
        perfMonitor.start()

        engine = RefreshEngine(config: config) { [weak self] snap in
            Task { @MainActor in
                guard let self else { return }
                self.lastSnapshot = snap
                self.store.update(snap)
                self.statusController.update(snapshot: snap)
                self.summaryService.update(snapshot: snap)
            }
        }
        let engine = engine!
        Task { await engine.start() }

        popoverController.onVisibilityChange = { visible in
            Task { await engine.setUIVisible(visible) }
        }

        // Session files rewrite constantly while agents work; only the agent
        // list needs refreshing here. Repo status has its own FSEvents path —
        // a kickLight would sweep `git status` across every repo per rewrite.
        watcher = DirectoryWatcher(path: AgentSessionReader.defaultDir) {
            Task { await engine.kickAgents() }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake(_:)),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func didWake(_ notification: Notification) {
        let engine = engine!
        Task { await engine.kickLight() }
    }
}

extension AppDelegate: MenuActionDelegate {
    func menuOpened() {
        let engine = engine!
        Task { await engine.kickLight() }
    }

    func refreshNow() {
        let engine = engine!
        Task { await engine.kickAll() }
    }

    func togglePRScope() {
        let engine = engine!
        Task { await engine.togglePRScope() }
    }

    func toggleAutoFetch() {
        let engine = engine!
        Task { await engine.toggleAutoFetch() }
    }

    func fetchRepo(path: String) {
        let engine = engine!
        Task { await engine.fetchNow(path: path) }
    }

    func setRepoIgnored(path: String, ignored: Bool) {
        let engine = engine!
        Task { await engine.setRepoIgnored(path: path, ignored: ignored) }
    }

    func setAgentIgnored(sessionId: String, ignored: Bool) {
        let engine = engine!
        Task { await engine.setAgentIgnored(sessionId: sessionId, ignored: ignored) }
    }

    func setSectionExpanded(section: DashboardSection, expanded: Bool) {
        let engine = engine!
        Task { await engine.setSectionExpanded(section, expanded: expanded) }
    }

    func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(summaries: summaryService) {
                [weak self] newConfig in
                guard let self else { return }
                let engine = self.engine!
                Task { await engine.updateConfig(newConfig) }
                self.settingsController?.close()
            }
        }
        settingsController?.show(config: lastSnapshot.config)
    }
}
