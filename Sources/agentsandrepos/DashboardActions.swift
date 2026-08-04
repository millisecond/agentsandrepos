import AgentsAndReposCore
import AppKit

/// Actions the dashboard tiles and footer can trigger. Local ones act on
/// NSWorkspace/pasteboard directly; engine-backed ones go through the same
/// MenuActionDelegate the legacy menu uses.
@MainActor
final class DashboardActions {
    weak var delegate: (any MenuActionDelegate)?
    /// Set by the owner so Settings/Quit can dismiss the popover first.
    var closePopover: () -> Void = {}

    init(delegate: (any MenuActionDelegate)? = nil) {
        self.delegate = delegate
    }

    /// Primary click on an agent tile: jump to the terminal/IDE window
    /// running that agent; fall back to revealing its cwd in Finder (e.g.
    /// background agents with no host window).
    func focusAgent(pid: Int32, fallbackPath: String) {
        closePopover()
        if !TerminalFocus.focus(agentPid: pid, cwd: fallbackPath) {
            openInFinder(path: fallbackPath)
        }
    }

    func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    func openInFinder(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    func openInTerminal(path: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", "Terminal", path]
        try? proc.run()
    }

    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func fetchRepo(path: String) { delegate?.fetchRepo(path: path) }
    func ignoreRepo(path: String) { delegate?.setRepoIgnored(path: path, ignored: true) }
    func unignoreRepo(path: String) { delegate?.setRepoIgnored(path: path, ignored: false) }
    func ignoreAgent(sessionId: String) { delegate?.setAgentIgnored(sessionId: sessionId, ignored: true) }
    func unignoreAgent(sessionId: String) { delegate?.setAgentIgnored(sessionId: sessionId, ignored: false) }
    func setSectionExpanded(_ section: DashboardSection, expanded: Bool) {
        delegate?.setSectionExpanded(section: section, expanded: expanded)
    }
    func refreshNow() { delegate?.refreshNow() }
    func togglePRScope() { delegate?.togglePRScope() }
    func toggleAutoFetch() { delegate?.toggleAutoFetch() }

    func copyUpgradeCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(UpdateCheck.upgradeCommand, forType: .string)
    }

    func openSettings() {
        closePopover()
        delegate?.openSettings()
    }

    func quit() {
        closePopover()
        NSApp.terminate(nil)
    }
}
