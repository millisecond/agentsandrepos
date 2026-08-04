# Codex CLI agent support in agentsandrepos

**Status: planned, not implemented (as of 2026-08-03).** Deferred because of the
limitations below — revisit when they stop being blockers or stop mattering:

- **No live-status or pid file on Codex's side.** Unlike Claude Code's
  `~/.claude/sessions/<pid>.json`, Codex leaves only rollout transcripts, so
  detection has to be inferred: process scan + join-to-rollout-by-cwd +
  status guessed from transcript events and file mtime. Workable but
  inherently less reliable than Claude detection.
- **"Waiting for approval" is undetectable.** Codex deliberately does not
  persist approval-request events, so a Codex agent blocked on the user looks
  identical to one that's thinking. The app's most valuable signal (the ⏸
  waiting badge/menubar count) can't exist for Codex.
- **Can't verify locally right now.** The machine's Codex install is stale
  (v0.41, last used 2025-09) and predates the current rollout format; testing
  requires upgrading Codex and actually using it.
- **Schema churn risk.** Codex's rollout format already broke once (~0.44
  envelope change); parsers would need fixture upkeep.
- **In-flight conflicts.** The `.claude/worktrees/agent-activity-bars/`
  worktree touches `Agents/` (TranscriptTaskReader, AgentActivityMeter);
  land that first to avoid churn in the same files.

## Context

The menubar app currently detects live **Claude Code** agents by reading `~/.claude/sessions/<pid>.json` (pid/cwd/status) plus per-session transcript JSONL. The user wants **OpenAI Codex CLI** agents to appear as tiles alongside them.

Research findings that shape the design:

- **Codex has no live-status or pid file.** Its only artifacts are rollout transcripts at `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ISO-ts>-<uuid>.jsonl` (default `~/.codex`; uuid = session id) and `history.jsonl`. So detection must be **process-first**: enumerate live `codex` processes (ground truth), then join each to its rollout by cwd.
- Rollout lines (current format) are `{"timestamp","type","payload"}` envelopes: `session_meta` (first line: session id, cwd), `turn_context` (per-turn cwd), `response_item` (user/assistant messages), `event_msg` (`task_started`, `task_complete` w/ `last_agent_message`, `token_count` heartbeats). **Approval requests are deliberately NOT persisted** → no "waiting" state for Codex (user accepted busy/idle-only).
- The local `~/.codex` is stale (v0.41, Sept 2025) and uses an older bare-line format — detect-and-skip old files; manual verification requires upgrading codex.
- The app's agent pipeline is already ~90% provider-neutral (debouncer, tiles, cwd→repo matching, TerminalFocus, summaries, badges, `ignoredAgents`). Exactly these are Claude-specific: `AgentSessionReader` (dir + schema), `TranscriptTaskReader` (path + schema), the single merge point `RefreshEngine.agentsTick()` (~line 389), one `DirectoryWatcher` in AppDelegate, and two hardcoded "Claude Agents" headers.

User decisions: Codex tile title = fixed **"Codex"**; **busy/idle-only** status fidelity is acceptable.

Perf constraint (user memory: "idle CPU is a requirement"): one `sysctl(KERN_PROC_ALL)` per 3s tick is fine; all rollout tail reads must be cached by `(mtime, size)` like `TranscriptTaskReader`; gate everything on `~/.codex/sessions` existing (one `stat` for non-codex users).

Coordination note: an in-progress worktree `.claude/worktrees/agent-activity-bars/` touches `Agents/` (adds AgentActivityMeter, modifies TranscriptTaskReader) — **do not refactor/rename existing Agents/ files**; only add new ones. Another session is actively evolving the Dashboard views (PR tiles, PerfMonitor) — keep UI diffs minimal and re-read files before editing.

## Architecture

```
codex procs (sysctl) ─┐
                      ├─ CodexSessionReader.read() ─→ [AgentSession(provider: .codex)] ─┐
rollout files (stat)  ─┘                                                                ├→ agentDebouncer.apply(...)
~/.claude/sessions ──── AgentSessionReader.read() ─→ [AgentSession(provider: .claude)] ─┘
```

## Steps

### 1. Provider on the model (S)

`Sources/AgentsAndReposCore/Model/AgentSession.swift`:
- `public enum AgentProvider: String, Sendable { case claude, codex }` with a `label`.
- Add `public let provider: AgentProvider` to `AgentSession`, init param defaulted to `.claude` (existing call sites/tests compile unchanged).
- For codex sessions, `displayName` should yield "Codex": pass `name: "Codex"` from the reader (no displayName logic change needed).
- **Footgun:** `withStatus(_:)` / `withTask(_:)` copy helpers in `AgentSessionReader.swift:138-150` must pass `provider: provider` through, or codex sessions silently revert to `.claude` after debounce. Add a test.

`Sources/AgentsAndReposCore/Presentation/TileState.swift`: add `provider` to `AgentTileState`, set from `agent.provider`.

UI surfacing (keep minimal):
- `DashboardView.swift` + `MenuBuilder.swift`: section header "Claude Agents" → **"Agents"**.
- `AgentTileView.swift`: for `.codex`, append `· codex` to the status line (or a `.caption2` badge) — Claude tiles unchanged.
- `SnapshotCommand.swift`: append ` [codex]` after displayName in CLI rows.
- `main.swift` usage text: "Claude Code agents" → "coding agents (Claude Code, Codex)".

No changes needed: `TerminalFocus` (pid-based), summary keys (`agent:<uuid>:user`), `ignoredAgents` (uuid-keyed), badge/severity logic, cwd→repo matching.

### 2. Process enumeration helpers (S/M)

Extend `Sources/AgentsAndReposCore/Util/ProcessTree.swift` (Util/, avoids the in-flight Agents/ worktree):

```swift
public static func pids(named name: String) -> [pid_t]      // one sysctl(KERN_PROC_ALL), filter p_comm
public static func arguments(of pid: pid_t) -> [String]?    // sysctl(KERN_PROCARGS2): argc, skip exec_path+NULs
public static func currentDirectory(of pid: pid_t) -> String? // proc_pidinfo(PROC_PIDVNODEPATHINFO).pvi_cdir.vip_path
```

Do NOT loop `proc_name` over `proc_listpids` (N syscalls). argv/cwd only run for matched pids (0–3 typically).

### 3. Pure rollout parsers (M)

New `Sources/AgentsAndReposCore/Agents/CodexRollout.swift` — pure functions over strings (pattern: `WorktreeListParser`, `PorcelainV2Parser`):

- `parseFilename(_:) -> (startedAt: Date, uuid: String)?` for `rollout-2026-08-02T10-15-30-<uuid>.jsonl`.
- `meta(fromFirstLine:) -> Meta?` (`sessionId`, `cwd?`); **returns nil for old ≤0.41 bare format** (no `"payload"` key) → whole file skipped.
- `TailScan` accumulator (newest-first lines, cheap `contains` pre-filters like TranscriptTaskReader):
  - user slot: `response_item` message role=="user", text from `payload.content[].text`, **rejecting** `<user_instructions>`/`<environment_context>` synthetic messages.
  - agent slot: newest of assistant `response_item` text OR `task_complete.last_agent_message`.
  - latest `turn_context.cwd` (first seen scanning backwards).
  - newest `task_started`/`turn_started` and `task_complete`/`turn_complete`/`turn_aborted` timestamps.
  - Produces `Tail { task: AgentTask, latestCwd, lastTaskStarted, lastTaskEnded }`.
- `inferStatus(tail:mtime:now:) -> AgentSession.Status`:
  ```
  if started != nil && (ended == nil || started > ended):
      return now - started < 1h ? .busy : .idle    # 1h demotion, parity with Claude
  if ended != nil: return .idle                     # completion write refreshed mtime — don't fake busy
  if now - mtime < 10s: return .busy                # no markers scanned (cap hit / new file)
  return .idle
  ```
  Never `.waiting` (not detectable). Markers give clean edges, so the existing `AgentStatusDebouncer` needs no changes.

### 4. Shared backwards tail scanner (S)

New `Sources/AgentsAndReposCore/Agents/TailScanner.swift`: extract the ~30-line chunked backwards file walk (256KB chunks, 4MB cap, carry-over fragment — see `TranscriptTaskReader.swift:85-114`) as a generic `scanBackwards(path:take:)`. **Leave `TranscriptTaskReader` itself untouched** (worktree conflict risk); migrate it later. Reuse/duplicate its 4-line `clean()` (collapse whitespace, 200-char cap).

### 5. CodexSessionReader (M)

New `Sources/AgentsAndReposCore/Agents/CodexSessionReader.swift`:

- `defaultHome` = `$CODEX_HOME` env ?? `~/.codex`.
- Impure `read(home:now:) -> [AgentSession]`:
  1. `stat(home + "/sessions")` absent → `[]` (cheap gate).
  2. `ProcessTree.pids(named: "codex")`; per pid read argv: keep TUI (no subcommand) / `exec` / `resume`; **exclude** `mcp-server`, `app-server`, `mcp`, `login`, `logout`, `completion`, `apply`, `proto`. `kind = subcmd == "exec" ? "bg" : "interactive"`. cwd via `currentDirectory(of:)`; startedAt via existing `AgentSessionReader.processStartTime`.
  3. No agent procs → `[]` (skip all file work; dead sessions never tile — process-gated, unlike Claude).
  4. Enumerate `rollout-*.jsonl` in **today's + yesterday's** date dirs (computed from `now` — self-heals midnight rollover). Per file: parseFilename → stat (mtime > 24h old → skip) → cached meta (first line immutable, cache forever; old-format skip cached too) → tail via TailScanner, cached by `(mtime, size)` in an NSLock'd static dict (TranscriptTaskReader pattern). Known limitation (comment it): a still-running session started >2 days ago lives in an older date dir and won't match.
  5. Pure `match(processes:rollouts:now:)`.
- `match` (unit-tested): effective rollout cwd = `latestCwd ?? metaCwd`; compare against process cwd raw AND symlink-resolved (`/tmp` vs `/private/tmp`). Sort procs by startedAt desc, rollouts by mtime desc; greedy — each proc claims the newest unclaimed matching rollout. Matched → `AgentSession(pid:, sessionId: uuid, cwd: procCwd, name: "Codex", kind:, status: inferStatus(...), startedAt: rollout ts, updatedAt: mtime, task:, provider: .codex)`. Unmatched proc → degraded tile with stable `sessionId: "codex-pid-<pid>"`, `status: .unknown("no session file")` (visible beats invisible). Unmatched rollouts → dropped.

### 6. Engine wire-up (S)

`RefreshEngine.swift` `agentsTick()` (~line 389) becomes:

```swift
sessions = agentDebouncer.apply(AgentSessionReader.read() + CodexSessionReader.read())
```

Everything downstream (sort, cwd→repo/worktree matching, otherAgents, badges, snapshot CLI, kick paths) inherits codex sessions for free. **No new DirectoryWatcher** — codex writes into date-nested dirs (kqueue watcher is single-dir), and with no waiting state the 3s poll latency is fine.

### 7. Explicit non-goals

- `isClaudeManaged` worktree heuristic: unchanged (codex doesn't auto-create worktrees).
- No new config keys — auto-detect via `~/.codex/sessions` existence; per-agent Ignore covers opt-out.
- No old-format (≤0.41) rollout support — skipped cleanly.

### 8. Tests (M)

New `CodexRolloutTests.swift` (inline string fixtures): filename parse (happy/malformed); meta new-format vs old-format-nil; tail scan (user prompt found, synthetic `<user_instructions>`/`<environment_context>` skipped, assistant text, `last_agent_message` wins when newer, `userSpokeLast`, latest turn_context cwd); `inferStatus` all four branches.

New `CodexSessionReaderTests.swift` (pure `match`): proc+rollout join incl. `exec`→bg kind; symlinked cwd; two procs one cwd (no double-claim); unmatched proc → `codex-pid-N` unknown tile; unmatched rollout dropped.

Extend: `AgentSessionReaderTests` — `withStatus`/`withTask` preserve `provider`; `AgentStatusDebouncerTests` — mixed-provider hold; `TileStateTests` — `AgentTileState.provider`.

## Verification

1. `swift test` (unsandboxed — sandbox breaks xcrun cache).
2. Upgrade codex (`brew install codex` or `npm i -g @openai/codex` — local install is stale 0.41).
3. Manual matrix: run `codex` TUI in a repo under `~/Projects` → tile titled "Codex" in the Agents section, busy while generating, idle at prompt, summaries populate from rollout tail; `codex exec "..."` → `(bg)` tile that vanishes on exit; `codex mcp-server` → no tile; tile tap focuses the terminal; quitting codex removes the tile next tick; old 2025-09 rollouts produce nothing. Check via `swift run agentsandrepos snapshot` (shows `[codex]` rows) and the popover.
4. Rebuild release + restart the running app (`.build/arm64-apple-macosx/release/agentsandrepos`).

## Effort

Overall **M (~1–2 days)**. Order: 1 → 2 → 3+4 → 5 → 6 → 8. Steps 3–5 fully testable before engine wire-up.

Main risk: Codex rollout schema churn (broke once at ~0.44). Mitigation: lenient decoding, pure parsers behind trivially updatable fixtures, old-format files skipped not misparsed.
