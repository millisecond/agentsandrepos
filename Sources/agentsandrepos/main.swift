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

        config: ~/.config/agentsandrepos/config.json
        """)
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

guard SingleInstanceLock.acquire() else {
    FileHandle.standardError.write(Data("\(AppInfo.displayName) is already running\n".utf8))
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
