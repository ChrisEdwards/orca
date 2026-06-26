---
name: orca-spawn
description: Spawn one AI coding worker (Claude Code or Codex) in a new cmux tab for a single ad-hoc task, then confirm it came up, reached the right mode, and received its brief (fire and confirm). Use when the user asks to spawn, launch, kick off, or hand off a Claude or Codex worker on a task in a repo, run a one-off task in its own tab, or start an agent without defining a full workflow.
---

# orca-spawn

Spawn one worker for one task, confirm it took, and report back.

This skill is a **thin conversational wrapper**. All real work lives in the bundled `scripts/orca-spawn.sh`, which drives `scripts/orca-cmux.sh` (the cmux seam) and `scripts/orca-adapter.sh` (per-agent config). Do not reimplement launch, readiness, mode-cycling, or screen-reading logic here. Gather inputs, shell out to the bundled spawn script, relay the result.

## Prerequisites

Require these external CLIs on `PATH`:

- `cmux`
- `jq`
- `claude` for Claude workers, or `codex` for Codex workers

## Inputs to gather from the conversation

- **agent type** — `claude` or `codex`. Ask if the user did not say.
- **task** — a short title (becomes the tab name and task id) plus the work to do.
- **brief** — a self-contained description of the task. The worker starts fresh with no conversation history, so include what to do, any constraints, and how it will know it is done. Construct this from the user's request.
- **cwd** — optional worker working directory. Defaults from the selected target workspace's directory. Pass `--cwd` only to override.
- **target workspace** — optional. Use at most one:
  - `--workspace-name <name>` selects an exact `custom_title` or `title` match in the caller's current cmux window, or creates a missing named workspace there.
  - `--workspace-id <uuid>` selects an existing workspace by stable UUID in the caller's current cmux window. Never pass positional refs such as `workspace:3`.

Workspace selection answers where the worker appears. `--cwd` answers where the worker process starts and where the brief is written; it may differ from target workspace metadata.

## Worker artifacts and handoffs

For worker findings, default to the worker's final response in its tab. Do not ask the worker to write reports, findings, logs, status files, or handoff files anywhere in the repo where they can be checked in.

If a durable handoff or artifact is genuinely useful, put it outside the repo under `${TMPDIR:-/tmp}/orca/<task-id>/`, and report the absolute path back to the human. The `.orca/briefs/` directory is only for Orca's internal brief delivery and is gitignored by `orca-spawn`; `.orca-*` files are different paths and are not covered by that rule.

## Run it

Single-line brief:

```bash
scripts/orca-spawn.sh --agent <claude|codex> --task "<title>" --brief "<brief text>"
```

Multi-line brief (preferred for anything non-trivial): write the brief to a file, then point at it:

```bash
scripts/orca-spawn.sh --agent claude --task "Fix the login redirect" \
  --brief-file /tmp/brief.md --cwd ~/projects/app
```

Target an existing or newly created workspace by exact name:

```bash
scripts/orca-spawn.sh --agent codex --task "Review PR 123" \
  --brief-file /tmp/review.md --workspace-name aiml-services --cwd ~/projects/aiml-services
```

Target a known existing workspace by UUID:

```bash
scripts/orca-spawn.sh --agent codex --task "Run parser tests" \
  --brief-file /tmp/brief.md --workspace-id 90D8E74A-E0EE-4FCB-8F7C-105574F46F01
```

Resolve `scripts/orca-spawn.sh` relative to this skill directory.

## Report back

`orca-spawn` prints `key=value` lines. On success (`status=ok`), tell the human:

- the **task id**
- the **target workspace UUID**
- whether the workspace was created
- the **worker surface UUID** — hold this in context; it is how you address the worker later
- the **tab name**
- the **after_seq** anchor — hold this too; pass it to `orca-watch --after` so following the worker is race-free

Example: "Spawned a Codex worker for `fix-login-redirect` in workspace `90D8…` in tab `fix-login-redirect` (surface `CEBB…`). It reached ready and has the brief."

## Fire and follow

`orca-spawn` itself stops at fire and confirm. To follow the worker to its first turn-end or attention pause, compose it with the `orca-watch` skill, which parks on the cmux event stream instead of polling the worker's screen.

After a successful spawn, take the reported `surface` and `after_seq` and start a watch, preferably as a background command so this session stays free until the worker transitions:

```bash
# (orca-watch lives in its own skill; resolve its script from that skill dir)
orca-watch.sh --surface <surface UUID> --agent <claude|codex> --after <after_seq> --timeout <secs>
```

It prints one JSON line on the first transition: `event: turn_end` (worker finished its turn) or `event: attention` (worker is waiting on a notification, permission, or question). Use that to collect results, message the worker, or tell the human to flip to its tab. Passing `--after` the spawn anchor guarantees a fast worker that finishes before the watch attaches is not missed.

## On failure

A non-zero exit prints `status=error` with an `error=` reason and, when the tab was created, the `surface=` UUID. The worker tab is **left open on purpose** after launch has started. Relay the error and the surface UUID when present so the human can flip to that tab and see what happened. Do not retry blindly, and do not close the tab.

## Boundaries

- One task, one worker. `orca-spawn` itself stops at fire and confirm and never monitors or tears down the worker; following it to completion is the separate `orca-watch` skill (see Fire and follow above).
- No worker registry or monitoring state is persisted. Brief files are written under `.orca/briefs/`, and `orca-spawn` ensures `.orca/` is gitignored.
- With no workspace selector, the worker opens in the calling workspace, the one this session was fired from.
- `orca-spawn` owns only cmux workspace routing and worker launch mechanics. It may select or create a target workspace, but it does not parse PR URLs, discover repositories, clone repositories, fetch branches, create working directories, or construct review-specific briefs.
- If the human asks raw `orca-spawn` to review a PR link without a concrete local `cwd` and workspace selector, gather those inputs or explain that PR URL resolution belongs in a higher-level review skill.
- If Claude asks to trust the worker cwd before showing its input box, `orca-spawn` selects the Yes option and continues waiting for readiness.
