---
name: orca-msg
description: Send a follow-up message to an existing Claude Code or Codex agent instance in a cmux surface. Use when the user asks to message, nudge, follow up with, or send context to an already-running Orca agent or pasted cmux surface.
---

# orca-msg

Send a follow-up message to an existing agent instance, confirm it was delivered, and report exactly what was sent.

This skill is a **thin conversational wrapper**. The bundled `scripts/orca-msg.sh` owns target resolution, cmux reads/writes, readiness checks, and submission. The wrapper may interpret the human's request, gather context, ask clarifying questions, and assemble the agent-facing message, but the script sends exact text only.

## Prerequisites

Require these external CLIs on `PATH`:

- `cmux`
- `jq`

## Inputs to gather from the conversation

- **target surface** — either a pasted cmux copy-ids block containing `surface_id`, a stable surface UUID, or a surface descriptor such as "the Claude agent in the aiml-services workspace."
- **message intent** — what the human wants the target agent to receive. This may be literal text or an instruction to assemble context from the current conversation, files, branch, or issue tracker.
- **agent type** — optional. If the target says Claude or Codex, pass `--agent`. Otherwise let the script infer from the target screen.

Use "surface" in Orca-level language. A cmux pane is only a layout container; the surface UUID is the target.

## Compose the message

Treat the user's text as an instruction to you, not necessarily the literal message body. If they ask you to give the target agent "all details of this issue," gather the relevant issue, branch, file, or conversation context first and write a clear agent-facing message.

For short messages, pass the text directly with `--message`.

For long or context-heavy messages, write the assembled message to a temp file outside the repo, leave it in place, and pass `--message-file`. The script will send a short absolute-path instruction to the target.

## Run it

With a pasted copy-ids block saved to a temp file:

```bash
scripts/orca-msg.sh --target-file /tmp/orca-target.txt --message "Please review the decision and report concerns."
```

With a descriptor:

```bash
scripts/orca-msg.sh --target "the Claude agent in the aiml-services workspace" \
  --message-file /tmp/orca-msg.abc123/message.md
```

With a known surface:

```bash
scripts/orca-msg.sh --surface <surface-uuid> --agent codex --message "Continue with the failing test."
```

Resolve `scripts/orca-msg.sh` relative to this skill directory.

## Clarification flow

If `orca-msg` prints `status=needs_clarification`, do not guess. Show the candidate surfaces to the human and ask which one they mean. Then rerun with the chosen `surface=` UUID.

## Report back

`orca-msg` prints `key=value` lines. On success (`status=ok`), tell the human:

- the **target surface UUID**
- the **agent type**
- the **exact message sent**
- the **message file path**, when one was used

Example: "Sent the follow-up to Claude surface `5DE1...`: `Read /tmp/orca-msg.X/message.md and respond to the request it contains.`"

## On failure

A non-zero exit prints `status=error` or `status=needs_clarification` with an `error=` reason. Relay the reason. Do not retry blindly, and do not type into a surface that is blocked on a permission prompt, trust prompt, shell prompt, merge editor, running command, or unknown UI.

## Boundaries

- Message only: no new surface, no new conversation, no monitoring afterward.
- The only durable target is a surface UUID. Positional refs such as `surface:35`, `pane:16`, and `workspace:9` may appear in copied input or candidate displays but are not used for targeting.
- Descriptor search is limited to the caller's current cmux window.
- The script sends only at known Claude or Codex input prompts. It never answers permission or trust prompts.
