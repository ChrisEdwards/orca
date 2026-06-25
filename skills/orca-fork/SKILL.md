---
name: orca-fork
description: Fork the current Codex or Claude Code conversation into a new cmux tab, preserving conversation history, then confirm the forked agent instance came up.
---

# orca-fork

Fork an existing provider conversation into a new cmux tab and confirm it came up.

This skill is a **thin conversational wrapper**. All real work lives in the bundled `scripts/orca-fork.sh`, which drives `scripts/orca-cmux.sh` (the cmux seam) and `scripts/orca-fork-adapter.sh` (provider fork config). Do not reimplement cmux control, source selection, command construction, or readiness polling here. Gather inputs, shell out to the bundled fork script, relay the result.

## Prerequisites

Require these external CLIs on `PATH`:

- `cmux`
- `jq`
- `codex` for Codex forks, or `claude` for Claude Code forks

## Inputs to gather from the conversation

- **source conversation** — normally inferred from the current Codex session through `CODEX_THREAD_ID`; otherwise use a provider-specific explicit id:
  - `--codex-thread-id <uuid>`
  - `--claude-session-id <uuid>`
- **prompt** — optional. If provided, it is passed at launch as the first turn in the forked conversation.
- **title** — optional tab title. If omitted, the script derives one.

Do not ask for an agent type separately from the source id. Conversation ids are provider-specific; a Codex thread id cannot be used with Claude Code, and a Claude session id cannot be used with Codex.

## Run it

Fork the current Codex conversation without starting a new turn:

```bash
scripts/orca-fork.sh
```

Fork an explicit Claude session:

```bash
scripts/orca-fork.sh --claude-session-id <uuid>
```

Fork and start a prompt:

```bash
scripts/orca-fork.sh --prompt "Investigate the failing auth tests" --title "fork-auth-tests"
```

Resolve `scripts/orca-fork.sh` relative to this skill directory.

## Report back

`orca-fork` prints `key=value` lines. On success (`status=ok`), tell the human:

- the **provider** — `codex` or `claude`
- the **source conversation id**
- the **fork surface UUID** — hold this in context; it is how you address the tab later
- the **tab name**
- whether a prompt was sent at launch

Example: "Forked the Codex conversation into tab `fork-auth-tests` (surface `CEBB...`). The prompt was sent at launch."

## On failure

A non-zero exit prints `status=error` with an `error=` reason and, when the tab was created, the `surface=` UUID. The fork tab is **left open on purpose** after launch has started. Relay the error and the surface UUID when present so the human can flip to that tab and see what happened. Do not retry blindly, and do not close the tab.

## Boundaries

- Fire-and-confirm only: open the fork, confirm readiness, and stop.
- No monitoring afterward.
- No worker registry is persisted.
- No generic `--agent` or `--conversation-id` interface.
- No recency fallbacks such as `codex fork --last`, `claude --continue --fork-session`, or scanning provider session files.
- If Codex asks to trust the calling workspace before showing the composer, the script selects the "Yes" option so the fork can finish launching in the same workspace the human already invoked Orca from.
- The fork opens in the calling workspace, the one this session was fired from.
