---
name: orca-agent
description: Spawn one AI coding worker (Claude Code or Codex) in a new cmux tab for a single ad-hoc task, then confirm it came up, reached the right mode, and received its brief (fire and confirm). Use when the user asks to spawn, launch, kick off, or hand off a Claude or Codex worker on a task in a repo, run a one-off task in its own tab, or start an agent without defining a full workflow.
---

# orca-agent

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
- **cwd** — optional. Defaults to the calling workspace's directory. Pass `--cwd` only to override.

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

Resolve `scripts/orca-spawn.sh` relative to this skill directory.

## Report back

`orca-spawn` prints `key=value` lines. On success (`status=ok`), tell the human:

- the **task id**
- the **worker surface UUID** — hold this in context; it is how you address the worker later
- the **tab name**

Example: "Spawned a Codex worker for `fix-login-redirect` in tab `fix-login-redirect` (surface `CEBB…`). It reached ready and has the brief."

## On failure

A non-zero exit prints `status=error` with an `error=` reason and, when the tab was created, the `surface=` UUID. The worker tab is **left open on purpose** after launch has started. Relay the error and the surface UUID when present so the human can flip to that tab and see what happened. Do not retry blindly, and do not close the tab.

## Boundaries

- One task, one worker, no monitoring afterward. This is fire and confirm.
- No worker registry or monitoring state is persisted. Brief files are written under `.orca/briefs/`, and `orca-spawn` ensures `.orca/` is gitignored.
- The worker opens in the calling workspace, the one this session was fired from.
- If Claude asks to trust the worker cwd before showing its input box, `orca-spawn` selects the Yes option and continues waiting for readiness.
