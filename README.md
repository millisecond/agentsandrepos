# Agents & Repos

A macOS menubar app to optimize your claude code usage: 
- Search across all claude code sessions and git  
- Quickly open/focus any claude code session or repo/PR
- Local LLM summaries of your last prompt and the agent's work 
- Find sessions waiting on your input 
- Overview of how active each claude code agent has been recently 

This software is developed with **strong assistance from claude code** with a human leading the ideas, design decisions, testing, and debugging. 

![Agents & Repos demo](docs/demo.gif)

## Install or upgrade

```sh
brew install --cask millisecond/tap/agentsandrepos && open -a "Agents & Repos"
```

The same command installs, upgrades, and (re)launches — look for the new
menubar icon. It installs a prebuilt, notarized, universal (Apple Silicon +
Intel) `Agents & Repos.app` — no Xcode needed — and links the
`agentsandrepos` CLI. On an upgrade, Homebrew stops the running copy before
swapping the app; when a new release is out, the in-app banner copies this
command for you. To start it at login, enable **Start at login** in the app's
Settings (a standard login item, visible in System Settings → General → Login
Items).

Heads up: the app phones home once a day to check for new releases; the
request carries a random install UUID and nothing else, and you can turn it
off in Settings — details under [Update check](#update-check) below.

## Build from source

```sh
swift build -c release
.build/release/agentsandrepos &          # bare binary: no login-item support
```

Or skip the manual steps entirely: clone the repo and ask Claude Code to
build and launch it — fitting, since that's how most of this app was written.

Two things only the brew cask's notarized build provides:

- **Local notifications** (opt-in, see Settings): macOS delivers them only
  from a signed, notarized app bundle, so source builds compile them out
  entirely — no Settings section, no permission prompt.
  `packaging/make-app.sh` turns them on with
  `AGENTSANDREPOS_NOTIFICATIONS=1 swift build -c release`.
- **Start at login**: needs an app bundle, not a bare binary.

`packaging/make-app.sh` builds that full bundle, but signs and notarizes with
the maintainer's Developer ID — to use it yourself, swap in your own identity
and notary profile (or sign ad-hoc with `codesign --force --sign - --entitlements
packaging/agentsandrepos.entitlements` for a local bundle, losing
notifications; keep the entitlements or Focus Session can't drive Terminal).

## Configuration

`~/.config/agentsandrepos/config.json` (also editable from the Settings window):

```json
{
  "roots": ["~/Projects"],
  "scanDepth": 3,
  "fetchEnabled": true,
  "fetchIntervalMinutes": 5,
  "autoFastForward": false,
  "prScope": "mine",
  "prIntervalMinutes": 5,
  "statusIntervalSeconds": 45,
  "showLLMSummaries": true,
  "checkForUpdates": true
}
```

Hidden repos and agents, custom agent names, and expanded sections live in
the same file (`ignoredRepos`, `ignoredAgents`, `agentNames`,
`expandedSections`) and are managed from the dashboard.

- `roots` — folders scanned (depth-limited) for git repos; a root can also be a
  single repo.
- `autoFastForward` — off by default. When on, only repos that are clean, on a
  branch with an upstream, and strictly behind get `merge --ff-only`; repos
  with a busy/waiting agent are skipped.
- `prScope` — `"mine"` or `"all"`.

PR data comes from the [`gh` CLI](https://cli.github.com) using your existing
`gh auth login`; without it the PR section degrades to a hint.

Agent detection reads `~/.claude/sessions/*.json` (Claude Code's live session
records) and verifies each PID is actually alive, guarding against PID reuse.
The last prompt and reply on each agent row come from that session's
transcript under `~/.claude/projects/`. Everything is read locally: summaries
run on-device (Apple Intelligence), and nothing from your sessions or repos
leaves the machine — the only network traffic is `git fetch`, `gh`, and the
[update check](#update-check).

## Uninstall

```sh
brew uninstall --cask agentsandrepos          # removes the app + CLI link
brew uninstall --zap --cask agentsandrepos    # …plus caches and preferences
```

Your configuration (roots, ignored repos, settings) lives in
`~/.config/agentsandrepos` — `--zap` removes that too; a plain uninstall
leaves it for a future reinstall.

## Update check

Once a day the app asks `api.agentsandrepos.com` for the latest release and
shows a banner when a newer version exists. The request carries a random
install UUID (`install_id`), generated on first launch and stored locally in
UserDefaults, used only to count installs — it contains no personal
information and is never derived from anything on the machine. If the check
fails for any reason it does so silently and no banner appears. Turn the
check off entirely with **Check for updates daily** in Settings.

## CPU self-check

A background app should cost nothing while you're not looking at it, so the
app watches its own CPU use (one `getrusage` call every 30 seconds). If its
5-minute average stays above ~15% of a core — normal is around 1% — a red
banner appears at the top of the dashboard with the measured average.
Restarting the app clears it; if it comes back, please open an issue. Warn and
clear events are also written to the unified log (subsystem
`com.millisecond.agentsandrepos`, category `perf`):

```sh
/usr/bin/log show --last 1h --predicate 'subsystem == "com.millisecond.agentsandrepos" AND category == "perf"'
```

## Publishing checklist (maintainer)

1. Bump `Version.current` in `Sources/AgentsAndReposCore/Version.swift` to
   match the tag (the in-app update banner compares it against the latest
   release advertised by `api.agentsandrepos.com`, which relays this repo's
   latest GitHub release), commit, then `git tag vX.Y.Z && git push --tags`.
2. Quit the running app, then `packaging/make-app.sh` — builds, signs,
   notarizes, and staples `dist/agentsandrepos-<version>.zip`, printing its
   sha256 (needs the `agentsandrepos-notary` keychain profile).
3. `gh release create vX.Y.Z dist/agentsandrepos-X.Y.Z.zip`
4. In the tap repo (`millisecond/homebrew-tap`), edit `version` and `sha256`
   in `Casks/agentsandrepos.rb` **in place** — don't copy
   `packaging/agentsandrepos.rb` over it; that file keeps a placeholder
   sha256. Push the tap.

## Requirements

- macOS 14+, Apple Silicon or Intel
- Optional: [`gh`](https://cli.github.com) for PRs and Actions runs; macOS 26
  on an Apple Intelligence-capable Mac for on-device summaries (everything
  else works without them)
- Xcode toolchain only to build from source (the cask ships a prebuilt,
  Developer ID-signed and notarized app)
