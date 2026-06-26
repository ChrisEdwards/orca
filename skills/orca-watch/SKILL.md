---
name: orca-watch
description: Wait for one already-spawned Claude Code or Codex worker to finish its turn or pause for attention, by parking on the cmux event stream rather than polling its screen. Use when the orchestrator needs to follow a worker to completion, detect that a worker went idle or needs input, or turn a fire-and-confirm spawn into fire-and-follow.
---

# orca-watch

Block until one worker signals turn-end or attention-needed, then report which.

This skill is a **thin conversational wrapper**. All real work lives in the bundled `scripts/orca-watch.sh`. It subscribes to the cmux event stream (`agent.hook.*` frames), resolves the worker's surface UUID to its session via the cmux session store, and returns the first matching transition. It does not poll `read-screen`. Do not reimplement detection logic here.

## Prerequisites

- `cmux` and `python3` on `PATH`.
- The cmux agent hook integration active for the worker's agent type. Claude Code is auto-injected by the cmux Claude wrapper; Codex needs `cmux hooks setup codex` once.

## Inputs to gather

- **surface** — the worker surface UUID, captured when the worker was spawned. This is the durable handle (never a positional ref).
- **agent** — `claude` or `codex`. Selects the session store and event prefix.
- **after** — optional event seq to resume from. Pass the spawn-time `latest_seq` so a fast worker that finishes before the watch attaches is never missed.
- **timeout** — optional seconds before giving up. `0` (default) waits forever; prefer a bound so a stuck worker does not park the orchestrator indefinitely.

## Run it

```bash
scripts/orca-watch.sh --surface <uuid> --agent <claude|codex> [--after <seq>] [--timeout <secs>]
```

For anything that may run a while, launch it as a background command so the orchestrator is free between turns and is notified when the worker transitions.

## Report back

On the first transition it prints one JSON line and exits 0:

```json
{"event":"turn_end","hook":"Stop","agent":"claude","surface":"50E9…","session_id":"claude-…","cwd":"…","workspace_id":"…","seq":23749}
```

- `event: turn_end` (`hook: Stop`) — the worker finished its turn and is idle. The orchestrator may collect results or advance the workflow.
- `event: attention` — the worker paused on `Notification`, `PermissionRequest`, or `AskUserQuestion`. Tell the human to flip to the worker's tab, or message the worker.

Exit codes: `0` matched, `3` timeout (`{"event":"timeout"}`), `4` stream closed first, `2` usage or resolve error.

## Boundaries

- Follows one worker. It does not spawn, message, or close a worker, and it does not act on the transition. The orchestrator decides what happens next.
- Attribution is by session, not surface, because `agent.hook.*` frames carry `surface_id: null`. The surface-to-session bridge is the cmux session store. If the store has no session for the surface yet, the worker has not started or hooks are off; `orca-watch` fails loudly rather than guessing.
- Screen reading against the adapter `ready-marker` is the fallback when hook integration is disabled. See `docs/research/cmux-completion-detection.md`.
