#!/usr/bin/env bash
#
# orca-fork-adapter - provider-specific configuration for orca-fork.
#
# Forking is provider-specific: Codex forks a thread, Claude Code forks a
# session. This adapter owns those command shapes and readiness markers so the
# orchestration script does not duplicate provider strings.
#
# Usage:
#   orca-fork-adapter list
#   orca-fork-adapter <codex|claude> ready-marker
#   orca-fork-adapter <codex|claude> launch <conversation-id> [prompt]
set -euo pipefail

die() { printf 'orca-fork-adapter: %s\n' "$1" >&2; exit 1; }

usage() {
  die "usage: orca-fork-adapter list | orca-fork-adapter <codex|claude> <ready-marker|launch> [conversation-id] [prompt]"
}

shell_quote() {
  printf '%q' "$1"
}

launch_cmd() {
  local provider=$1 id=$2 prompt=${3-}
  [[ -n "$id" ]] || die "$provider launch: conversation id is required"

  case "$provider" in
    codex)
      printf 'codex fork %s' "$(shell_quote "$id")"
      ;;
    claude)
      printf 'claude --resume %s --fork-session' "$(shell_quote "$id")"
      ;;
    *) die "unknown provider: $provider" ;;
  esac

  if [[ -n "$prompt" ]]; then
    printf ' %s' "$(shell_quote "$prompt")"
  fi
  printf '\n'
}

cmd=${1:-}
[[ -n "$cmd" ]] || usage

if [[ "$cmd" == list ]]; then
  (($# == 1)) || die "list: takes no arguments"
  printf '%s\n' codex claude
  exit 0
fi

provider=$cmd
field=${2:-}
[[ -n "$field" ]] || usage

case "$provider" in
  codex)
    case "$field" in
      ready-marker)
        (($# == 2)) || die "codex ready-marker: takes no extra arguments"
        printf '›\n'
        ;;
      launch)
        (($# == 3 || $# == 4)) || die "codex launch: needs conversation id and optional prompt"
        launch_cmd codex "$3" "${4-}"
        ;;
      *) die "codex: no such field: $field" ;;
    esac
    ;;
  claude)
    case "$field" in
      ready-marker)
        (($# == 2)) || die "claude ready-marker: takes no extra arguments"
        printf '← for agents\n'
        ;;
      launch)
        (($# == 3 || $# == 4)) || die "claude launch: needs conversation id and optional prompt"
        launch_cmd claude "$3" "${4-}"
        ;;
      *) die "claude: no such field: $field" ;;
    esac
    ;;
  *)
    die "unknown provider: $provider"
    ;;
esac
