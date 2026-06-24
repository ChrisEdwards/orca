# Claude Code Shift+Tab mode cycle (empirical)

Verified against Claude Code v2.1.190, Opus 4.8, Claude Enterprise, on cmux 0.64.16, by launching `claude` in a terminal surface and reading the footer after each Shift+Tab.

## Cycle

| Presses from launch | Mode | Footer string |
|---|---|---|
| 0 | default / normal | no indicator, footer shows only `← for agents` |
| 1 | accept edits | `⏵⏵ accept edits on (shift+tab to cycle) · ← for agents` |
| 2 | plan | `⏸ plan mode on (shift+tab to cycle) · ← for agents` |
| 3 | auto | `⏵⏵ auto mode on (shift+tab to cycle) · ← for agents` |
| 4 | wraps to default | no indicator |

Cycle length is 4. The fourth press wraps back to default.

## Notes for the adapter

- Readiness marker is `← for agents`. It appears in every footer state including default, so it is a reliable "input box is up" signal regardless of which mode the worker launched in.
- Target mode is the footer containing `auto mode on`.
- Match on the mode name text, not the glyph. `⏵⏵` is shared by accept-edits and auto.
- Set-mode logic is cycle-until-target. Read the footer, and while it does not contain `auto mode on`, send one Shift+Tab and re-read, up to 5 attempts (cycle length plus one), then fail.
- `bypass permissions` mode is absent here, disabled by enterprise policy. On a machine without that policy the cycle may include it, so do not hardcode a press count.
