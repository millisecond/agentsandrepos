import AgentsAndReposCore
import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private(set) var snapshot: Snapshot = .empty
    weak var delegate: (any MenuActionDelegate)?
    /// Set by AppDelegate after construction (the popover needs the store,
    /// which needs the controller-independent wiring).
    var popoverController: DashboardPopoverController?

    init(delegate: any MenuActionDelegate) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        self.delegate = delegate

        if let button = statusItem.button {
            button.image = AgentIcon.idle
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    /// Debug override for eyeballing status-item states without manufacturing
    /// the real condition: launch with AAR_FORCE_STATE=waiting|busy|error|idle.
    private let forcedState = ProcessInfo.processInfo.environment["AAR_FORCE_STATE"]

    func update(snapshot: Snapshot) {
        self.snapshot = snapshot
        guard let button = statusItem.button else { return }
        let agents = snapshot.visibleAgents
        var waiting = agents.filter { $0.status.isWaiting }.count
        var busy = agents.filter { $0.status.isBusy }.count
        var errors = snapshot.visibleRepos.filter(\.hasError).count
        if let forcedState {
            (waiting, busy, errors) = (0, 0, 0)
            switch forcedState {
            case "waiting": waiting = 3
            case "busy": busy = 3
            case "error": errors = 3
            default: break
            }
        }

        let image: NSImage
        let title: String
        if waiting > 0 {
            image = AgentIcon.waiting
            title = " \(waiting)"
        } else if busy > 0 {
            image = AgentIcon.busy
            title = " \(busy)"
        } else if errors > 0 {
            image = AgentIcon.error
            title = " \(errors)"
        } else {
            image = AgentIcon.idle
            title = ""
        }
        // Setting an unchanged title/image still dirties the status-bar
        // window's layout; skip both so per-tick publishes don't redraw the
        // menu bar.
        if button.image !== image { button.image = image }
        if button.title != title { button.title = title }
    }

    // MARK: - Click handling

    /// Left-click toggles the dashboard popover; right-click pops the legacy
    /// text menu (assign → performClick → detach, so left-click stays ours).
    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            MenuBuilder.rebuild(menu: menu, snapshot: snapshot, controller: self)
            delegate?.menuOpened()
            statusItem.menu = menu
            sender.performClick(nil)
            statusItem.menu = nil
        } else {
            guard let popoverController else { return }
            popoverController.toggle(relativeTo: sender)
            if popoverController.isShown { delegate?.menuOpened() }
        }
    }

    // MARK: - Actions

    @objc func openURLAction(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func openInFinderAction(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    @objc func openInTerminalAction(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", "Terminal", path]
        try? proc.run()
    }

    @objc func copyPathAction(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc func fetchNowAction(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        delegate?.fetchRepo(path: path)
    }

    @objc func togglePRScopeAction(_ sender: NSMenuItem) {
        delegate?.togglePRScope()
    }

    @objc func toggleAutoFetchAction(_ sender: NSMenuItem) {
        delegate?.toggleAutoFetch()
    }

    @objc func refreshAction(_ sender: NSMenuItem) {
        delegate?.refreshNow()
    }

    @objc func settingsAction(_ sender: NSMenuItem) {
        delegate?.openSettings()
    }

    @objc func quitAction(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
