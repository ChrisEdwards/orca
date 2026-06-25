# Orca first deliverable, spawn a worker (fire and confirm)

Date 2026-06-24. Status accepted, ready for implementation.

## Goal

Let the human tell their Claude Code orchestrator session "spawn a Claude (or Codex) worker on this task in this repo" and have orca open a new terminal tab in the current workspace, launch the agent, get it into the right mode, hand it a task brief, and confirm it took. One ad-hoc task, one worker, no monitoring afterward. This is user story 13 in `docs/prd-v1.md` and the bottom-up first slice the PRD calls for.

## Scope

In scope
- A thin `orca-agent` skill the orchestrator invokes by conversation.
- A small cmux-interface helper script wrapping the primitives orca needs, all UUID-based.
- An `orca-spawn` routine that runs launch, readiness, mode, brief, and confirm.
- Two inline adapters, Claude Code and Codex.
- Brief delivery through a file in `.orca/briefs/`.

Out of scope for this deliverable
- Completion detection, monitoring, and attention-needed signalling. Feasible later through cmux's lifecycle store (`~/.cmuxterm/claude-hook-sessions.json`) and event log (`events.jsonl`), but not built now.
- Teardown of finished workers.
- Multi-task management, workflows, persisted worker state, and tmux support.

## Key decisions

- Plain terminal surfaces, never the native agentSession surface. See ADR 0001. The agentSession surface rejects `read-screen` and `send`/`send-key` and renders blank, so it cannot host orca's keystroke-and-read control model.
- Every surface is targeted by its stable UUID, captured at creation. See ADR 0002. The `surface:N` refs are positional and drift as surfaces open and close, which already closed the orchestrator's own surface once during research.
- The worker is a new tab in the calling workspace, the workspace the orchestrator was fired from, not a new or fixed workspace. See the `Calling workspace` term in `CONTEXT.md`.
- Marker strings live in the adapter definition, not in control logic, so a cmux or agent version bump that changes footer text is a config edit.

## The spawn sequence

For one task, the orchestrator (through the skill and `orca-spawn`) does this in order.

1. Resolve the calling workspace UUID (`cmux identify --json --id-format both`) and the working directory. Default the cwd to the calling workspace's directory, allow an explicit override.
2. Generate a task id, a kebab slug from the task title.
3. Write the brief to `<cwd>/.orca/briefs/<task-id>.md`. Ensure `.orca/` is listed in `<cwd>/.gitignore`, adding it if missing.
4. Create the worker tab with `cmux new-surface --type terminal --workspace <calling-workspace-uuid> --working-directory <cwd> --focus false --id-format both` and capture the worker surface UUID from the parenthesised value. Every later command targets this UUID.
5. Launch the agent with the adapter's launch command, `cmux send --surface <uuid> "<launch>"` then `cmux send-key --surface <uuid> enter`.
6. Poll `cmux read-screen --surface <uuid> --lines 40` until the adapter's readiness marker appears, with a timeout.
7. If the adapter has a mode step, cycle it. For Claude, while the footer does not contain `auto mode on`, send `cmux send-key --surface <uuid> "shift+tab"` and re-read, up to five attempts, then fail. For Codex there is no mode step.
8. Deliver the brief, `cmux send --surface <uuid> "Read .orca/briefs/<task-id>.md and carry out the task it describes."` then `cmux send-key --surface <uuid> enter`.
9. Return to the orchestrator the task id, the worker surface UUID, and the tab name.

## Adapters

Two adapters, inline as a per-agent function or case block for now, extractable to a config file later. Facts verified on cmux 0.64.16, Claude Code v2.1.190, Codex v0.142.0. See `docs/research/claude-mode-cycle.md` and `docs/research/codex-readiness.md`.

| Field | Claude | Codex |
|---|---|---|
| launch command | `claude` | `codex -p yolo` |
| readiness marker | `← for agents` (present in every footer state) | `›` input chevron |
| mode step | cycle Shift+Tab until footer contains `auto mode on`, match the name not the glyph, max five attempts | none, yolo profile sets the approval posture at launch |
| brief delivery | file pointer | file pointer |

## Components

- **cmux-interface helper script.** Wraps create-tab, send, send-key, read-screen, close, and list. Accepts and returns UUIDs. This is the seam a future tmux backend would replace.
- **orca-spawn routine.** Runs the spawn sequence above using the interface helper and the adapters. Owns the brief file and `.gitignore` handling.
- **Inline adapters.** Claude and Codex definitions as described.
- **orca-agent skill.** The thin conversational surface. The orchestrator invokes it with an agent type, a task, and an optional cwd, and it calls `orca-spawn`.

## Return contract

`orca-spawn` returns, and the skill reports back, the task id, the worker surface UUID, and the tab name. Nothing is persisted to track the worker. The orchestrator holds the UUID in its own conversation context.

## Error handling

On any failure, `orca-spawn` emits `status=error` and an `error=` reason. After the worker tab exists (for example, readiness marker never appears within the timeout, mode never reaches `auto mode on` within five attempts, or the agent binary is missing), the error includes the worker surface UUID and leaves the tab open so the human can flip to it and see what happened. Orca does not close the tab on post-launch failure, that would destroy the evidence. Pre-launch failures such as invalid arguments or unreachable cmux fail before creating a tab.

## Defaults

- The tab name is set from the task id at spawn. cmux may later replace it with its own AI-generated title, which is fine.
- The worker cwd defaults to the calling workspace's directory, with an optional override.

## Verification

Modules are validated by running them against real cmux and real agents, per the PRD's testing notes. The acceptance check is a manual end-to-end run for both agents, spawn a Claude worker and confirm it reaches `auto mode on` and receives the brief, then spawn a Codex worker and confirm it reaches ready and receives the brief. The cmux-interface helper can also be unit-checked by asserting it emits the right cmux commands for given inputs.

## References

- `docs/prd-v1.md`, user story 13 and the bottom-up build order.
- `CONTEXT.md`, the glossary, especially Orchestrator, Worker, Calling workspace, Tab, Spawn, Fire and confirm.
- `docs/adr/0001-plain-terminal-surfaces.md`.
- `docs/adr/0002-target-surfaces-by-uuid.md`.
- `docs/research/claude-mode-cycle.md` and `docs/research/codex-readiness.md`.
