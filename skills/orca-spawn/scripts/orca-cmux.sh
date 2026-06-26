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
#   create-workspace --name <name> --cwd <dir> --window <uuid>  create a workspace, print its UUID
#   send        --surface <uuid> <text>       send literal text (no trailing enter)
#   send-key    --surface <uuid> <key>        send a key (enter, "shift+tab", ...)
#   read-screen --surface <uuid> [--lines N]  read N lines (default 40)
#   close       --surface <uuid>              close the surface
#   close-workspace --workspace <uuid>        close the workspace and all its surfaces
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

parse_first_uuid() {
  local out=$1 uuid
  uuid=$(printf '%s\n' "$out" \
    | grep -oE '\([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\)' \
    | head -1 | tr -d '()') || true
  [[ -n "$uuid" ]] || return 1
  printf '%s\n' "$uuid"
}

# parse_first_ref <output> <noun>
# Pull the first positional ref of the given noun (e.g. "workspace:9") out of a
# line of cmux output. Refs drift over a session, so this is only a stepping
# stone to a UUID, never a target in its own right.
parse_first_ref() {
  local out=$1 noun=$2 ref
  ref=$(printf '%s\n' "$out" | grep -oE "${noun}:[0-9]+" | head -1) || true
  [[ -n "$ref" ]] || return 1
  printf '%s\n' "$ref"
}

# resolve_workspace_uuid <workspace-ref>
# Map a positional workspace ref to its stable UUID by reading the workspace
# list. Newer cmux echoes only the ref when creating a workspace, so this bridges
# back to the UUID-only invariant (ADR 0002) the rest of orca depends on.
resolve_workspace_uuid() {
  local ref=$1 uuid
  uuid=$(cmux_exec list-workspaces --id-format both 2>/dev/null \
    | awk -v ref="$ref" '{ for (i = 1; i <= NF; i++) if ($i == ref) { print $(i + 1); exit } }') || true
  [[ "$uuid" =~ $UUID_RE ]] || return 1
  printf '%s\n' "$uuid"
}

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
  uuid=$(parse_first_uuid "$out") || die "could not parse a surface UUID from cmux output: $out"
  printf '%s\n' "$uuid"
}

create_workspace() {
  local name=$1 cwd=$2 window=$3 out uuid ref
  out=$(cmux_exec new-workspace --name "$name" --cwd "$cwd" --window "$window" --focus false --id-format both)
  # Older cmux printed the new workspace's UUID in parentheses; newer builds emit
  # only its positional ref ("OK workspace:N"), even with --id-format both. Take a
  # directly-parsed UUID when one is present, otherwise resolve the ref through the
  # workspace list so callers always receive a stable UUID.
  if uuid=$(parse_first_uuid "$out"); then
    printf '%s\n' "$uuid"
    return 0
  fi
  ref=$(parse_first_ref "$out" workspace) \
    || die "could not parse a workspace UUID or ref from cmux output: $out"
  uuid=$(resolve_workspace_uuid "$ref") \
    || die "could not resolve created workspace $ref to a UUID from the workspace list"
  printf '%s\n' "$uuid"
}

cmd=${1:-}
[[ -n "$cmd" ]] || die "usage: orca-cmux <create-tab|create-workspace|send|send-key|read-screen|close|close-workspace|list|identify-json|list-workspaces-json|list-surfaces-json> [options]"
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

  create-workspace)
    name=""; cwd=""; window=""
    while (($#)); do
      case "$1" in
        --name)   need_value create-workspace --name $#;   name=$2; shift 2 ;;
        --cwd)    need_value create-workspace --cwd $#;    cwd=$2; shift 2 ;;
        --window) need_value create-workspace --window $#; window=$2; shift 2 ;;
        *) die "create-workspace: unexpected argument: $1" ;;
      esac
    done
    [[ -n "$name" ]] || die "create-workspace: --name is required"
    [[ -n "$cwd" ]] || die "create-workspace: --cwd is required"
    require_uuid window "$window"
    create_workspace "$name" "$cwd" "$window"
    ;;

  send|send-key)
    sfc=""; payload=""; have_payload=0; rest=0
    while (($#)); do
      if ((have_payload == 0 && rest == 0)); then
        case "$1" in
          --surface) need_value "$cmd" --surface $#; sfc=$2; shift 2; continue ;;
          --) rest=1; shift; continue ;;
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

  close-workspace)
    ws=""
    while (($#)); do
      case "$1" in
        --workspace) need_value close-workspace --workspace $#; ws=$2; shift 2 ;;
        *) die "close-workspace: unexpected argument: $1" ;;
      esac
    done
    require_uuid workspace "$ws"
    cmux_exec close-workspace --workspace "$ws"
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
