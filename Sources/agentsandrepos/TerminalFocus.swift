import AgentsAndReposCore
import AppKit

/// Focuses the window hosting a Claude agent, best-effort, by strategy:
/// - Terminal.app / iTerm2: exact tab/session matched by the agent's tty
///   (AppleScript).
/// - WezTerm: exact pane matched by tty via `wezterm cli`.
/// - tmux: agents there have no GUI ancestor (the server daemonizes) —
///   select the pane/window, then focus the attached client's terminal.
/// - Everything else (IDEs like VS Code/JetBrains/Zed/Xcode/Cursor, and
///   terminals without tty scripting like Warp/Alacritty/Kitty/Ghostty):
///   raise the window whose title mentions the cwd name via Accessibility,
///   degrading to app-level activation.
/// Returns false when the agent has no focusable host at all (e.g.
/// background agents) so the caller can fall back to Finder.
@MainActor
enum TerminalFocus {

    static func focus(agentPid: Int32, cwd: String) -> Bool {
        let tty = ProcessTree.ttyName(of: pid_t(agentPid)).map { "/dev/\($0)" }
        if let app = hostApp(of: pid_t(agentPid)) {
            return focusHost(app: app, tty: tty, cwd: cwd)
        }
        if let tty, focusViaTmux(paneTTY: tty, cwd: cwd) { return true }
        return false
    }

    /// Shared by the direct path and the tmux-client path (where `tty` is
    /// the client's pty, not the agent's).
    private static func focusHost(app: NSRunningApplication, tty: String?, cwd: String) -> Bool {
        switch app.bundleIdentifier {
        case "com.apple.Terminal":
            if let tty, selectTerminalAppTab(tty: tty) {
                app.activate()
                return true
            }
        case "com.googlecode.iterm2":
            if let tty, selectITermSession(tty: tty) {
                app.activate()
                return true
            }
        case "com.github.wez.wezterm":
            if let tty, selectWezTermPane(tty: tty, app: app) {
                app.activate()
                return true
            }
        default:
            break
        }
        let token = (cwd as NSString).lastPathComponent
        if !token.isEmpty, AXWindowFocus.raise(app: app, titleToken: token) {
            app.activate()
            return true
        }
        // Unknown host, no tty, or scripting/AX declined — at least raise
        // the hosting app.
        return app.activate()
    }

    /// Nearest ancestor that is a real GUI app (registered with Launch
    /// Services). Shells/login in between return no NSRunningApplication.
    private static func hostApp(of pid: pid_t) -> NSRunningApplication? {
        for ancestor in ProcessTree.ancestors(of: pid) {
            guard let app = NSRunningApplication(processIdentifier: ancestor),
                app.bundleIdentifier != nil,
                app.activationPolicy != .prohibited,
                app != .current
            else { continue }
            return app
        }
        return nil
    }

    // MARK: - tmux

    private static let tmuxPaths = [
        "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux",
    ]

    /// The agent's tty IS its pane's pty, so the pane lookup works no matter
    /// how deep the agent sits under the pane's shell.
    private static func focusViaTmux(paneTTY: String, cwd: String) -> Bool {
        guard
            let panes = tmux(["list-panes", "-a", "-F", TmuxLocator.paneFormat]),
            let pane = TmuxLocator.pane(matchingTTY: paneTTY, inListOutput: panes)
        else { return false }
        tmux(["select-window", "-t", pane.windowId])
        tmux(["select-pane", "-t", pane.paneId])

        guard
            let clientsOut = tmux(["list-clients", "-F", TmuxLocator.clientFormat]),
            let client = TmuxLocator.bestClient(
                forSession: pane.sessionName,
                in: TmuxLocator.clients(fromListOutput: clientsOut))
        else { return false }  // detached server — nothing on screen to focus
        if client.sessionName != pane.sessionName {
            tmux(["switch-client", "-c", client.tty, "-t", pane.sessionName])
        }
        // The client process runs inside the user's terminal: focus that
        // terminal's window/tab by the client's own tty.
        guard let app = hostApp(of: client.pid) else { return false }
        return focusHost(app: app, tty: client.tty, cwd: cwd)
    }

    @discardableResult
    private static func tmux(_ args: [String]) -> String? {
        HostCommand.run(candidates: tmuxPaths, name: "tmux", args: args)
    }

    // MARK: - WezTerm

    private static func selectWezTermPane(tty: String, app: NSRunningApplication) -> Bool {
        var candidates = ["/opt/homebrew/bin/wezterm", "/usr/local/bin/wezterm"]
        if let bundled = app.bundleURL?
            .appendingPathComponent("Contents/MacOS/wezterm").path
        {
            candidates.insert(bundled, at: 0)
        }
        guard
            let list = HostCommand.run(
                candidates: candidates, name: "wezterm",
                args: ["cli", "list", "--format", "json"]),
            let pane = WezTermPanes.pane(matchingTTY: tty, inListJSON: Data(list.utf8))
        else { return false }
        // activate-pane focuses its containing tab and window too.
        return HostCommand.run(
            candidates: candidates, name: "wezterm",
            args: ["cli", "activate-pane", "--pane-id", "\(pane.paneId)"]) != nil
    }

    // MARK: - AppleScript tab matching

    /// Terminal.app: every tab exposes its tty; select the matching tab and
    /// bring its window to the front of Terminal's window list.
    private static func selectTerminalAppTab(tty: String) -> Bool {
        let script = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if (tty of t) is equal to "\(tty)" then
                            set selected of t to true
                            if miniaturized of w then set miniaturized of w to false
                            set index of w to 1
                            return true
                        end if
                    end repeat
                end repeat
                return false
            end tell
            """
        return runBoolScript(script)
    }

    /// iTerm2: sessions expose their tty; select session, tab, and window.
    private static func selectITermSession(tty: String) -> Bool {
        let script = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if (tty of s) is equal to "\(tty)" then
                                select s
                                select t
                                select w
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
                return false
            end tell
            """
        return runBoolScript(script)
    }

    /// Runs a script expected to return a boolean. Any scripting failure
    /// (no Automation permission, app not scriptable) reads as false so the
    /// caller degrades to app activation.
    private static func runBoolScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("TerminalFocus AppleScript error: \(error)")
            return false
        }
        return result.booleanValue
    }
}
