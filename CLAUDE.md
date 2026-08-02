# agentsandrepos

Swift 6 SPM menubar app (no Xcode project). Core logic lives in the
`AgentsAndReposCore` library target (unit-tested), UI in the `agentsandrepos`
executable. The binary doubles as a CLI (`agentsandrepos snapshot`).

## Build, test, run

- `swift build` / `swift test` must run **unsandboxed** (xcrun cache lives in
  /var/folders).
- The instance the user actually runs is the **release** build:
  `.build/arm64-apple-macosx/release/agentsandrepos`. After changes:
  `swift build -c release`, kill the running instance, relaunch that binary.
  Never leave a debug build resident — debug SwiftUI rendering is several
  times slower and shows up directly as menu-bar CPU.
- A single-instance lock means the last relaunch wins; check
  `ps aux | grep agentsandrepos` before assuming which binary is live.

## Performance invariants — read before touching Engine/, watchers, or UI

This is a resident menubar app: **idle CPU is a feature**. It once sat at 35%
CPU because none of the rules below were enforced; each rule marks a real
regression that shipped. Keep them true:

1. **Recurring work scales with changes, not with repo/session count.** A
   watcher callback may only refresh the thing that changed (`kickAgents()`
   for session-file writes, `statusOne(path)` for repo events) — never sweep
   all repos. The sessions watcher once ran `git status` across 52 repos on
   every session-file rewrite, which is constantly while agents work.
2. **Snapshot publishes are deduped by equality.** `Snapshot.==` deliberately
   excludes `generatedAt`. If you add a field that changes on every publish
   (timestamps, counters), exclude it from `==` too, or the dedupe dies
   silently and the dashboard re-renders every tick.
   `SnapshotEqualityTests` guards this.
3. **UI updates are gated on visibility.** The popover's hosting view (and its
   window, once shown) outlives close, so `@Published` writes while closed
   still re-render offscreen. `SnapshotStore.setLive` gates the flow; any new
   window or hosted view needs the same treatment. Same principle as LLM
   summaries: agent/workspace generation only while the popover is visible.
4. **No unconditional re-reads.** Cache and validate cheaply: transcript tails
   by mtime+size (`TranscriptTaskReader`), HEAD commit dates by
   `GitState.headOid`, remote info resolved once. New pollers need the same
   discipline.
5. **Subprocess spawns are the budget.** At idle, spawn count should be ~0
   outside the 45s status loop and 5m fetch/PR loops. Avoid redundant AppKit
   writes too (e.g. setting an unchanged `button.title` dirties status-bar
   layout).
6. **Measure after changing any polling/watching/UI path.** Sustained check:
   `ps -o etime,cputime,%cpu -p <pid>` — cputime/etime should stay under ~2%.
   If it's above that, `sample <pid> 5` and read the call graph before
   guessing.
7. **The app watches itself.** `PerfMonitor` (getrusage every 30s) shows a red
   dashboard banner when the 5-minute average tops 15% (hysteresis clears at
   8%; `CPUWatchdogModel` in Core, unit-tested) and logs to category `perf`.
   Visible to end users by design. If you see that banner after a change you
   made, that's rule 6 telling you to profile.
