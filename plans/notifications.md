# Local notifications

Status: implemented on `notifications-exploration` (default off, opt-in).

## What ships

- **Opt-in banner** at the top of the dashboard: "Get important local
  notifications about agent permission requests and Git builds/actions", with
  Dismiss and Enable. First render stamps
  `notificationsPromptFirstShownAt`; the banner ages out 24h later on its
  own (`NotificationPrompt.shouldShow`). Dismiss and Enable both retire it
  permanently. Hidden in `--demo` mode.
- **Two triggers** (`NotificationPlanner`, Core, unit-tested):
  - a repo-level GitHub Actions run finishing — `running → passed/failed`
    transitions, plus runs first seen already-finished if they completed
    within the last 10 minutes (covers short runs that start and end
    between the 5-minute sweeps). First ingest is baseline-only so launch
    never floods.
  - an agent in `waiting` status for over 5 minutes — `updatedAt` seeds the
    wait clock, so something already pending at launch notifies right away.
    One notification per waiting spell; leaving and re-entering `waiting`
    starts a fresh cycle.
  - Both respect `ignoredRepos` / `ignoredAgents`.
- **Settings**: master toggle plus per-trigger toggles; works regardless of
  what happened to the banner.

## Architecture

- `NotificationPlanner` (Core): pure snapshot-diffing state machine, no I/O.
  Runs on every publish (3s agent tick is the hot path) — dictionary work
  only, and `NotificationCoordinator` short-circuits when disabled, so idle
  cost is nil and no new timers or subprocess spawns exist (perf rules 1/5).
- `NotificationCoordinator` (app): sits on the same snapshot callback as
  `SnapshotStore`; resets the planner when notifications get toggled off so
  re-enabling re-primes instead of replaying stale transitions.
- Delivery: `UserNotificationDeliverer` (UNUserNotificationCenter) when
  running from a real .app bundle; `OsascriptNotificationDeliverer`
  (`osascript -e 'display notification'`) for bare `swift build` binaries,
  where the UN framework traps without a bundle. Passed runs deliver
  silently; failures and waiting agents get the default sound.

- **Click-through** (bundled app only): clicking a notification goes where
  clicking the matching tile would — a finished run opens its GitHub page,
  a waiting agent focuses its terminal window via `TerminalFocus` (Finder
  fallback). `PlannedNotification.ClickTarget` rides in the UN userInfo;
  `NotificationClickRouter` (the center delegate) decodes and routes. The
  osascript dev fallback has no click hook — clicks open Script Editor.

## Future options (not built)

- PR-level CI (`PullRequest.ci`) transitions — deliberately left out of v1
  to keep noise down; repo-level runs already cover deploys and pushes.
- Configurable waiting threshold (hardcoded 5 min; `NotificationPlanner`
  takes it as an init parameter, so it's a Settings stepper away).
- macOS authorization status surfaced in Settings ("denied — enable in
  System Settings → Notifications").
