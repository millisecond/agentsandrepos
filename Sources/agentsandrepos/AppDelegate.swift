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
    func setNotificationsEnabled(_ enabled: Bool)
    func dismissNotificationsPrompt()
    func noteNotificationsPromptShown()
    func openSettings()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Nil in demo mode — the UI runs on DemoTimeline snapshots instead.
    private var engine: RefreshEngine?
    private var demoDriver: DemoDriver?
    private var statusController: StatusItemController!
    private var settingsController: SettingsWindowController?
    private var watcher: DirectoryWatcher?
    private var lastSnapshot: Snapshot = .empty
    private let store = SnapshotStore()
    private let summaryService = SummaryService()
    private let updateChecker = UpdateChecker()
    private let perfMonitor = PerfMonitor()
    private var notifications: NotificationCoordinator?
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

        // Demo mode: no engine, no watcher, no network, no perf banner —
        // DemoDriver feeds scripted snapshots straight into the store.
        if DemoMode.enabled {
            demoDriver = DemoDriver(
                store: store, statusController: statusController,
                popoverController: popoverController)
            demoDriver?.start()
            return
        }

        updateChecker.start()
        perfMonitor.start()
        notifications = NotificationCoordinator()

        let engine = RefreshEngine(config: config) { [weak self] snap in
            Task { @MainActor in
                guard let self else { return }
                self.lastSnapshot = snap
                self.store.update(snap)
                self.statusController.update(snapshot: snap)
                self.summaryService.update(snapshot: snap)
                self.notifications?.ingest(snap)
            }
        }
        self.engine = engine
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
        guard let engine else { return }
        Task { await engine.kickLight() }
    }
}

extension AppDelegate: MenuActionDelegate {
    func menuOpened() {
        guard let engine else { return }
        Task { await engine.kickLight() }
    }

    func refreshNow() {
        guard let engine else { return }
        Task { await engine.kickAll() }
    }

    func togglePRScope() {
        guard let engine else { return }
        Task { await engine.togglePRScope() }
    }

    func toggleAutoFetch() {
        guard let engine else { return }
        Task { await engine.toggleAutoFetch() }
    }

    func fetchRepo(path: String) {
        guard let engine else { return }
        Task { await engine.fetchNow(path: path) }
    }

    func setRepoIgnored(path: String, ignored: Bool) {
        guard let engine else { return }
        Task { await engine.setRepoIgnored(path: path, ignored: ignored) }
    }

    func setAgentIgnored(sessionId: String, ignored: Bool) {
        guard let engine else { return }
        Task { await engine.setAgentIgnored(sessionId: sessionId, ignored: ignored) }
    }

    func setSectionExpanded(section: DashboardSection, expanded: Bool) {
        guard let engine else { return }
        Task { await engine.setSectionExpanded(section, expanded: expanded) }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        guard let engine else { return }
        if enabled { notifications?.requestAuthorization() }
        Task { await engine.setNotificationsEnabled(enabled) }
    }

    func dismissNotificationsPrompt() {
        guard let engine else { return }
        Task { await engine.dismissNotificationsPrompt() }
    }

    func noteNotificationsPromptShown() {
        guard let engine else { return }
        Task { await engine.noteNotificationsPromptShown() }
    }

    func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(
                summaries: summaryService,
                onTestNotification: { [weak self] in self?.notifications?.sendTest() }
            ) {
                [weak self] newConfig in
                guard let self else { return }
                if newConfig.notificationsEnabled {
                    self.notifications?.requestAuthorization()
                }
                if let engine = self.engine {
                    Task { await engine.updateConfig(newConfig) }
                }
                self.settingsController?.close()
            }
        }
        settingsController?.show(config: lastSnapshot.config)
    }
}
