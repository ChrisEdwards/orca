# cmux completion detection (Slice 1 spike)

Verified on cmux 0.64.17, Claude Code v2.1.x, Codex v0.142.x.

## Question

Can a single Claude Code orchestrator session reliably detect a worker's
turn-end and attention-needed transitions without polling `read-screen` in a
loop and burning its own context window?

## Answer

Yes. cmux forwards every agent lifecycle hook onto a reconnectable event
stream, and turn-end is a single unified event across both adapters. The
orchestrator parks on a socket read (server-side blocking), so waiting costs no
tokens and no polling.

## How turn-end and attention surface

cmux's Claude wrapper auto-injects Claude Code hooks; `cmux hooks setup codex`
installs the Codex equivalents. Both forward hooks onto the event stream as
`agent.hook.<HookName>` frames. Mining the recorded log
(`~/.cmuxterm/events.jsonl`) shows the real vocabulary:

| Signal | Event name | Source verified |
| --- | --- | --- |
| Turn-end (worker finished, idle) | `agent.hook.Stop` | claude, codex |
| Needs input / notification | `agent.hook.Notification` | claude |
| Needs permission | `agent.hook.PermissionRequest` | claude, codex |
| Asking a question | `agent.hook.AskUserQuestion` | claude |
| Worker's own sub-agent ended | `agent.hook.SubagentStop` | claude (ignore for worker turn-end) |

`agent.hook.Stop` is emitted by both Claude and Codex on turn-end, so one event
name covers both adapters.

## Attribution to a specific worker

This is the one sharp edge. `agent.hook.*` frames carry `surface_id: null`.
They do carry `payload.workspace_id`, `payload.cwd`, and
`payload.session_id`. Because Orca places multiple worker tabs in one workspace
and they may share a repo cwd, neither workspace nor cwd uniquely identifies a
worker. Attribution must go through `session_id`.

The bridge is the session store `~/.cmuxterm/<source>-hook-sessions.json`, whose
`activeSessionsBySurface` maps a surface UUID to its `sessionId`. Formats differ
by one prefix:

- store `sessionId`: bare UUID, e.g. `ce045992-...`
- event `payload.session_id`: `<source>-<uuid>`, e.g. `claude-ce045992-...` /
  `codex-019eff79-...`

So `event.payload.session_id == "<agent>-" + store.sessionId`. The orchestrator
already holds the worker's surface UUID from spawn (ADR 0002), resolves it to a
sessionId via the store, then filters the stream for that session. The store is
populated by the `SessionStart` hook, which fires before the worker reaches its
ready marker, so by the time `orca-spawn` finishes the mapping is present.

`cmux notify`-created `notification.created` frames DO carry `surface_id`, but
those are a separate path from agent lifecycle hooks and are not the turn-end
signal.

## Race-free waiting

The subscription ack frame reports `latest_seq`. Capturing that at spawn time
and subscribing with `--after <seq>` (or `--cursor-file`) replays anything that
fired between spawn and subscribe, so a fast worker that finishes before the
watcher attaches is never missed. Verified: a `cmux notify` fired after
subscribe was delivered live, and the cursor file advanced to the last seq.

## Consequence for Orca

The detection primitive is `orca-watch --surface <uuid> --agent <type>`:
subscribe to `cmux events` filtered to the hook events above, resolve the
target session via the store, and return the first matching transition as one
JSON line (`turn_end` or `attention`). This is the seam that turns
fire-and-confirm into fire-and-follow (Slice 2) and lets a workflow advance
steps automatically (Slice 3). Screen-reading against adapter `ready-marker`
patterns remains the fallback when hook integration is disabled.

## Smoke test (manual)

Verified `skills/orca-watch/scripts/orca-watch.sh` against live cmux 0.64.17:

1. Usage and validation: missing surface, bad `--agent`, and non-numeric
   `--timeout` each fail with exit 2 and a clear message.
2. Resolve + subscribe + timeout: watching the orchestrator's own surface with
   `--timeout 4` resolved the session, subscribed, and exited 3 with
   `{"event":"timeout"}` after ~4s.
3. Turn-end end to end: a background watch of the orchestrator's own surface
   caught the orchestrator's own `agent.hook.Stop` at end of turn and exited 0
   with `{"event":"turn_end","hook":"Stop","session_id":"claude-93243d32-...",
   "cwd":".../orca","seq":23749}`. Surface-to-session resolution and attribution
   confirmed correct.

Not yet exercised live: a Codex worker turn-end (same `agent.hook.Stop` path,
verified only from the recorded event log) and the `attention` classification
(`Notification` / `PermissionRequest` / `AskUserQuestion`). Both are covered
when Slice 2 folds `orca-watch` into `orca-spawn` and runs real workers.
