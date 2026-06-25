#!/usr/bin/env bash
#
# orca-cmux - the cmux seam for orca.
#
# Wraps the handful of cmux operations orca needs so spawn and workflow logic
# never call cmux directly. This is the single place a future tmux backend would
# be swapped in (PRD user story 10).
#
# Every surface is addressed by its stable UUID, never a positional ref. cmux's
# surface:N / pane:N / tab:N refs drift as surfaces open and close (ADR 0002),
# so this script accepts and returns UUIDs only and refuses refs outright.
#
# The cmux binary is taken from $CMUX_BIN (default "cmux"), which is also the
# seam the tests inject a recording fake through.
#
# Commands:
#   create-tab  --workspace <uuid> [--cwd D]  create a terminal surface, print its UUID
#   send        --surface <uuid> <text>       send literal text (no trailing enter)
#   send-key    --surface <uuid> <key>        send a key (enter, "shift+tab", ...)
#   read-screen --surface <uuid> [--lines N]  read N lines (default 40)
#   close       --surface <uuid>              close the surface
#   list                                      list surfaces (for debugging)
#   identify-json                            print caller identity as JSON
#   list-workspaces-json                      list workspaces in caller window as JSON
#   list-surfaces-json --workspace <uuid>     list workspace surfaces as JSON
set -euo pipefail

CMUX_BIN=${CMUX_BIN:-cmux}

die() { printf 'orca-cmux: %s\n' "$1" >&2; exit 1; }

# Run the real (or injected) cmux with the given argv verbatim.
cmux_exec() { "$CMUX_BIN" "$@"; }

UUID_RE='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'

# require_uuid <label> <value>
# Enforce the ADR 0002 invariant at the boundary: a target must be a stable
# UUID, never a positional ref (surface:N, workspace:N) or bare index.
require_uuid() {
  local label=$1 value=$2
  [[ -n "$value" ]] || die "$label: a UUID is required"
  [[ "$value" =~ $UUID_RE ]] || die \
    "$label: '$value' is not a UUID; positional refs drift (ADR 0002), pass the stable UUID"
}

# need_value <command> <flag> <remaining-arg-count>
need_value() { (($3 >= 2)) || die "$1: $2 needs a value"; }

# create_tab <workspace-uuid> [cwd]
# Creates a plain terminal surface in the given workspace and prints its stable
# surface UUID. Uses --focus false so spawning never steals the human's focus.
create_tab() {
  local ws=$1 cwd=${2:-} out uuid
  local args=(new-surface --type terminal --workspace "$ws")
  [[ -n "$cwd" ]] && args+=(--working-directory "$cwd")
  args+=(--focus false --id-format both)
  out=$(cmux_exec "${args[@]}")
  # Output: "OK surface:N (UUID) pane:N (UUID) workspace:N (UUID)".
  # The first parenthesised value is the surface UUID, the only stable handle.
  uuid=$(printf '%s\n' "$out" \
    | grep -oE '\([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\)' \
    | head -1 | tr -d '()') || true
  [[ -n "$uuid" ]] || die "could not parse a surface UUID from cmux output: $out"
  printf '%s\n' "$uuid"
}

cmd=${1:-}
[[ -n "$cmd" ]] || die "usage: orca-cmux <create-tab|send|send-key|read-screen|close|list|identify-json|list-workspaces-json|list-surfaces-json> [options]"
shift

case "$cmd" in
  create-tab)
    ws=""; cwd=""
    while (($#)); do
      case "$1" in
        --workspace) need_value create-tab --workspace $#; ws=$2; shift 2 ;;
        --cwd)       need_value create-tab --cwd $#;       cwd=$2; shift 2 ;;
        *) die "create-tab: unexpected argument: $1" ;;
      esac
    done
    require_uuid workspace "$ws"
    create_tab "$ws" "$cwd"
    ;;

  send|send-key)
    sfc=""; payload=""; have_payload=0; rest=0
    while (($#)); do
      if ((rest == 0)); then
        case "$1" in
          --surface) need_value "$cmd" --surface $#; sfc=$2; shift 2; continue ;;
          --) rest=1; shift; continue ;;
          -*) die "$cmd: unexpected option: $1" ;;
        esac
      fi
      ((have_payload == 0)) || die "$cmd: too many arguments: $1"
      payload=$1; have_payload=1; shift
    done
    require_uuid surface "$sfc"
    # orca's "send"/"send-key" map 1:1 onto the cmux subcommands of the same name.
    if ((have_payload == 0)); then
      [[ "$cmd" == send ]] && die "send: text argument is required"
      die "send-key: key argument is required"
    fi
    cmux_exec "$cmd" --surface "$sfc" "$payload"
    ;;

  read-screen)
    sfc=""; lines=40
    while (($#)); do
      case "$1" in
        --surface) need_value read-screen --surface $#; sfc=$2; shift 2 ;;
        --lines)   need_value read-screen --lines $#;   lines=$2; shift 2 ;;
        *) die "read-screen: unexpected argument: $1" ;;
      esac
    done
    require_uuid surface "$sfc"
    [[ "$lines" =~ ^[1-9][0-9]*$ ]] || die "read-screen: --lines must be a positive integer, got: $lines"
    cmux_exec read-screen --surface "$sfc" --lines "$lines"
    ;;

  close)
    sfc=""
    while (($#)); do
      case "$1" in
        --surface) need_value close --surface $#; sfc=$2; shift 2 ;;
        *) die "close: unexpected argument: $1" ;;
      esac
    done
    require_uuid surface "$sfc"
    cmux_exec close-surface --surface "$sfc"
    ;;

  list)
    (($# == 0)) || die "list: takes no arguments"
    cmux_exec list-pane-surfaces --id-format both
    ;;

  identify-json)
    (($# == 0)) || die "identify-json: takes no arguments"
    cmux_exec identify --json --id-format both
    ;;

  list-workspaces-json)
    (($# == 0)) || die "list-workspaces-json: takes no arguments"
    cmux_exec list-workspaces --json --id-format both
    ;;

  list-surfaces-json)
    ws=""
    while (($#)); do
      case "$1" in
        --workspace) need_value list-surfaces-json --workspace $#; ws=$2; shift 2 ;;
        *) die "list-surfaces-json: unexpected argument: $1" ;;
      esac
    done
    require_uuid workspace "$ws"
    cmux_exec list-pane-surfaces --workspace "$ws" --json --id-format both
    ;;

  *)
    die "unknown command: $cmd"
    ;;
esac
