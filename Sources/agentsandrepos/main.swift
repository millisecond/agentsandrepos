import AgentsAndReposCore
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--version") || arguments.first == "version" {
    print("\(AppInfo.displayName) (agentsandrepos) \(Version.current)")
    exit(0)
}

if arguments.contains("--help") || arguments.first == "help" {
    print(
        """
        \(AppInfo.displayName) (agentsandrepos) — menubar overview of git repos, Claude Code agents, and GitHub PRs

        usage:
          agentsandrepos             run the menubar app
          agentsandrepos snapshot    print a one-shot overview to stdout
                          --no-prs   skip GitHub PR lookup
          agentsandrepos --version   print version
          agentsandrepos --demo      run the UI on scripted fake data (README
                                     recording; see scripts/record-demo.sh)
          agentsandrepos --onboarding
                                     show the first-run welcome popover even
                                     though config exists (dev walkthroughs;
                                     Start saves for real)
          agentsandrepos unregister-login
                                     remove the login item (used by uninstall)

        config: ~/.config/agentsandrepos/config.json
        """)
    exit(0)
}

if arguments.first == "unregister-login" {
    // Used by packaging/uninstall.sh: only the app itself can remove its
    // SMAppService login item, so this must run while the bundle still exists.
    if LaunchAtLogin.isAvailable {
        LaunchAtLogin.set(enabled: false)
        print("login item unregistered")
    } else {
        print("not running from an app bundle; no login item to unregister")
    }
    exit(0)
}

if arguments.first == "snapshot" {
    let includePRs = !arguments.contains("--no-prs")
    let output = OutputBox()
    let sem = DispatchSemaphore(value: 0)
    // Detached so nothing lands on the (blocked) main actor.
    Task.detached {
        let text = await SnapshotCommand.run(includePRs: includePRs)
        output.set(text)
        sem.signal()
    }
    sem.wait()
    print(output.get())
    exit(0)
}

// Demo mode locks on its own path so a recording can run beside the user's
// resident instance (the record script quits the real one anyway, to keep a
// second menubar icon out of frame).
let lockPath =
    DemoMode.enabled
    ? NSHomeDirectory() + "/.config/agentsandrepos/demo.lock"
    : SingleInstanceLock.defaultPath
guard SingleInstanceLock.acquire(path: lockPath) else {
    FileHandle.standardError.write(Data("\(AppInfo.displayName) is already running\n".utf8))
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
