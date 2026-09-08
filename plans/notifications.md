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
- **Surprise scoring for runs** (`RunSurpriseScorer`, `RunBelief`, Core,
  unit-tested). Every push to a green repo used to produce the same
  "passed" alert; now each finished run is scored against what the app
  remembers about that workflow and only the surprising ones get the full
  treatment. See "Surprise scoring" below.
- **Settings**: master toggle plus per-trigger toggles; works regardless of
  what happened to the banner.
- **Alert style with timed auto-hide**: `NSUserNotificationAlertStyle=alert`
  defaults the app to persistent Alerts (user-overridable in System
  Settings; macOS snapshots the style at first registration, so a machine
  that already registered as Banners needs its entry reset to pick it up).
  Because Alerts never self-dismiss, the app withdraws its own: CI results
  after 5 minutes, waiting-agent alerts after 1 minute
  (`PlannedNotification.expiresAfter`, scheduled by the coordinator with a
  generation guard so re-posts aren't killed by stale timers). Resolution
  also withdraws — an agent that stops waiting or a run that gets re-run
  takes its alert down immediately (`NotificationPlan.withdraw`).
  Withdrawal removes the Notification Center entry too; macOS has no
  screen-only dismissal.

## Surprise scoring

The nightly-report problem: a friend who reports the same five plant
heights every night is tuned out by the night one plant doubles. The fix,
borrowed from the vendor-spreadsheet checker: remember what you said last
time, measure how surprised you should be, and sort into buckets.

1. **The belief.** After each finished run the planner writes a note per
   workflow (key `owner/repo#Workflow`, path-based when there's no GitHub
   remote): last outcome, current streak, an EMA failure rate, EMA
   mean/variance of run duration (`startedAt → updatedAt`, now requested
   from `gh run list`), EMA mean/variance of the gap between finishes, and
   how many results have been swallowed since the last line let through.
   `BeliefStore` persists it to
   `~/.config/agentsandrepos/notification-beliefs.json` (written only when a
   run finishes, read once at launch) so knowledge survives relaunches and
   the notifications-off `reset()`.
2. **The score.** Each component adds `log(1 + z)`, z being standard
   deviations from the belief, so a wobble adds nothing and a jump adds a
   lot but never absurdly much:
   - outcome vs. failure rate (Bernoulli z; rate clamped to 2–98%)
   - duration vs. the usual (sd floored at 25% of mean / 60s; capped at 2.0)
   - a lull — this finish came much later than the cadence predicted
     (sd floored at 50% of mean / 1h; only the long side counts; capped 1.5)
   - **passed ↔ failed flip: flat 3.0**, always extreme
   - **no belief yet: flat 3.0** — first night, everything is news, which is
     exactly what the branch did before scoring existed
   Duration/gap need 3 samples before they count. The caps mean only flips
   and first sightings reach extreme on their own; a slow run or a lull can
   tip another component over a cutoff.
3. **The buckets** (`SurpriseTier`, cutoffs 1.0 and 2.5):
   - **extreme**: the full alert as before — 5-min expiry, sound for
     failures, and a subtitle with the "since last time" clause
     ("first failure after 12 passes", "back to green after 3 failures",
     "took 20m, usually 4m", "first run in 7d").
   - **unusual**: a quiet line — no sound, 90-s expiry, same subtitle
     ("2nd failure in a row, took 9m, usually 4m").
   - **normal**: swallowed. With α = 0.2 a second consecutive failure is
     unusual (≈1.1) and a third is normal (≈0.85); routine passes score
     ≈0.13.
4. **Manners rules.** Waiting agents need a human decision, so they are
   never scored — always their own line, always with sound. And every third
   swallowed result for a workflow gets one quiet "still green, 7th pass in
   a row" line, so nothing vanishes forever.
5. **Calibration.** The cutoffs, α, the floors and the caps are hand-picked
   guesses. Every scored run logs one line to category `notify`
   (`surprise o/r#CI score=1.74 tier=unusual outcome=0.13 duration=1.61`);
   after a few weeks, `log show --predicate 'category == "notify"'` gives
   the real distribution to set them from. Nobody has done this yet.

## Architecture

- `NotificationPlanner` (Core): pure snapshot-diffing state machine, no I/O.
  Runs on every publish (3s agent tick is the hot path) — dictionary work
  only, and `NotificationCoordinator` short-circuits when disabled, so idle
  cost is nil and no new timers or subprocess spawns exist (perf rules 1/5).
- `NotificationCoordinator` (app): sits on the same snapshot callback as
  `SnapshotStore`; resets the planner when notifications get toggled off so
  re-enabling re-primes instead of replaying stale transitions. Loads
  beliefs at init, saves them when the planner reports them dirty (only
  after a finish — no per-tick I/O), and logs each score.
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
- Scoring for agents: a "traffic stopped" analogue (a busy agent whose
  transcript goes silent for far longer than its usual cadence) and a
  per-agent belief about how often it asks. Waiting itself stays unscored.
- Calibrating the tier cutoffs from logged scores (see above).
- Configurable waiting threshold (hardcoded 5 min; `NotificationPlanner`
  takes it as an init parameter, so it's a Settings stepper away).
- macOS authorization status surfaced in Settings ("denied — enable in
  System Settings → Notifications").
