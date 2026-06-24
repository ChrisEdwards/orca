# Codex readiness (empirical)

Verified against OpenAI Codex v0.142.0, launched with `codex -p yolo`, on cmux 0.64.16, in a terminal surface at cwd `~/projects/oss/orca`.

## Launch and mode

- Launch command is `codex -p yolo`. The `yolo` profile bakes in the approval posture, the banner shows `permissions: YOLO mode`. There is no Shift+Tab mode cycle for Codex, the mode is set at launch, not post-launch.
- Banner box on launch:
  ```
  >_ OpenAI Codex (v0.142.0)
  model:       gpt-5.5 high   /model to change
  directory:   ~/projects/oss/orca
  permissions: YOLO mode
  ```

## Readiness marker

- The input box renders a leading chevron `›` with a dimmed placeholder such as `Implement {feature}`. The `›` chevron is the most stable readiness signal, it marks the editable input line and is independent of model or cwd.
- A footer line directly under the input shows `<model> · <cwd>`, for example `gpt-5.5 high · ~/projects/oss/orca`. Useful as a secondary signal, but model and cwd vary, so match the ` · ` pattern or the cwd orca already knows rather than a fixed string.
- Codex booted to ready within about a second in this test.

## Notes for the adapter

- The Codex adapter needs no mode step. launch_command is `codex -p yolo`, the readiness marker is the `›` input chevron, then deliver the brief.
- Non-blocking MCP startup warnings can appear above the input (for example an atlassian OAuth failure). They do not block readiness, so key the readiness check on the input chevron, not on the absence of warnings.
