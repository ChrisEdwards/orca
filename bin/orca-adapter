#!/usr/bin/env bash
#
# orca-adapter - per-agent-type configuration for orca.
#
# An adapter is the ONLY place that knows agent-specific details: how to launch
# the agent, how to tell it is ready, and the optional post-launch mode step.
# orca-spawn queries these fields so no marker string is ever hardcoded into
# control logic. A cmux or agent version bump that changes footer text is then a
# one-line edit here, which is the whole reason this seam exists.
#
# Usage:
#   orca-adapter list                 list known agent types
#   orca-adapter <type> <field>       print one field for an agent type
#
# Fields:
#   launch              launch command (typed into a fresh terminal surface)
#   ready-marker        substring that means the input box is up
#   mode                "cycle" if there is a post-launch mode step, else "none"
#   mode-key            key to send each cycle      (only when mode == cycle)
#   mode-target         substring that means the target mode is reached  (")
#   mode-max-attempts   cycle attempt cap before failing                 (")
#
# The schema expresses an OPTIONAL mode step: Claude cycles Shift+Tab until the
# footer says "auto mode on", Codex has no mode step (the yolo profile sets its
# posture at launch). Asking for a mode sub-field on an agent without a mode step
# is a usage error, never a silent empty value.
#
# Facts verified on cmux 0.64.16, Claude Code v2.1.190, Codex v0.142.0.
# See docs/research/claude-mode-cycle.md and docs/research/codex-readiness.md.
set -euo pipefail

die() { printf 'orca-adapter: %s\n' "$1" >&2; exit 1; }

usage() {
  die "usage: orca-adapter list | orca-adapter <claude|codex> <launch|ready-marker|mode|mode-key|mode-target|mode-max-attempts>"
}

cmd=${1:-}
[[ -n "$cmd" ]] || usage

if [[ "$cmd" == list ]]; then
  (($# == 1)) || die "list: takes no arguments"
  printf '%s\n' claude codex
  exit 0
fi

type=$cmd
field=${2:-}
[[ -n "$field" ]] || usage
(($# == 2)) || die "$type: unexpected extra arguments after '$field'"

case "$type" in
  claude)
    case "$field" in
      launch)            v="claude" ;;
      ready-marker)      v="← for agents" ;;
      mode)              v="cycle" ;;
      mode-key)          v="shift+tab" ;;
      mode-target)       v="auto mode on" ;;
      mode-max-attempts) v="5" ;;
      *) die "claude: no such field: $field" ;;
    esac
    ;;
  codex)
    case "$field" in
      launch)            v="codex -p yolo" ;;
      ready-marker)      v="›" ;;
      mode)              v="none" ;;
      mode-key|mode-target|mode-max-attempts)
        die "codex: no mode step, field '$field' is not available" ;;
      *) die "codex: no such field: $field" ;;
    esac
    ;;
  *)
    die "unknown agent type: $type"
    ;;
esac

printf '%s\n' "$v"
