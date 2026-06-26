#!/usr/bin/env bash
#
# orca-spawn - spawn one AI coding worker in a cmux tab (fire and confirm).
#
# Runs the full spawn sequence for a single task: resolve the calling workspace,
# write the brief, open a worker tab, launch the agent, wait for it to come
# ready, put it in the right mode, hand it the brief, and report back. It does
# not monitor the worker afterward and never tears it down.
#
# All surface I/O goes through the bundled orca-cmux script (the cmux seam,
# UUID-only). All agent-specific strings come from the bundled orca-adapter.
# orca-spawn itself only adds the orchestration: workspace resolution,
# brief/.gitignore handling, the readiness poll, and the mode-cycle loop.
#
# Usage:
#   orca-spawn --agent <claude|codex> --task <title> \
#              (--brief <text> | --brief-file <path>) [--cwd <dir>] \
#              [--workspace-name <name> | --workspace-id <uuid>]
#
# Output (stdout, key=value lines):
#   status=ok|error
#   task_id=<kebab slug>
#   workspace=<target workspace UUID>
#   workspace_name=<target workspace name if known>
#   workspace_created=true|false
#   surface=<worker surface UUID>      (once the tab is created)
#   tab=<task id>
#   cwd=<resolved working directory>
#   brief=<relative brief path>
#   error=<reason>                      (on failure)
#
# On any post-launch failure the worker tab is LEFT OPEN (never closed) so the
# human can flip to it and see what happened, and the error names the surface
# UUID. orca-spawn only ever acts on the worker surface, never the orchestrator's.
#
# Requires: jq, and a reachable cmux (CMUX_BIN, default "cmux").
# Facts verified on cmux 0.64.16, Claude Code v2.1.190, Codex v0.142.0.
set -uo pipefail

BIN_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ORCA_CMUX="$BIN_DIR/orca-cmux.sh"
ORCA_ADAPTER="$BIN_DIR/orca-adapter.sh"

# shellcheck source=skills/orca-spawn/scripts/orca-trust-prompt.sh
. "$BIN_DIR/orca-trust-prompt.sh"
# shellcheck source=skills/orca-spawn/scripts/orca-upgrade-prompt.sh
. "$BIN_DIR/orca-upgrade-prompt.sh"

export CMUX_BIN=${CMUX_BIN:-cmux}

# Poll/cycle pacing. Counts not wall-clock, so tests are deterministic.
# ~30 reads at 1s ≈ a 30s readiness budget; the mode cap comes from the adapter.
ORCA_READY_POLLS=${ORCA_READY_POLLS:-30}
ORCA_POLL_INTERVAL=${ORCA_POLL_INTERVAL:-1}
ORCA_MODE_INTERVAL=${ORCA_MODE_INTERVAL:-1}

# State filled in as we go, so spawn_fail can report what exists.
TASK_ID=""
WORKSPACE=""
WORKSPACE_NAME=""
WORKSPACE_CREATED=""
SURFACE=""
CWD=""
BRIEF_REL=""
ORIGIN_SURFACE=""
UUID_RE='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'

die() {
  local msg=$1
  printf 'status=error\n'
  [[ -n "$TASK_ID" ]] && printf 'task_id=%s\n' "$TASK_ID"
  [[ -n "$WORKSPACE" ]] && printf 'workspace=%s\n' "$WORKSPACE"
  [[ -n "$WORKSPACE_NAME" ]] && printf 'workspace_name=%s\n' "$WORKSPACE_NAME"
  [[ -n "$WORKSPACE_CREATED" ]] && printf 'workspace_created=%s\n' "$WORKSPACE_CREATED"
  [[ -n "$SURFACE" ]] && printf 'surface=%s\n' "$SURFACE"
  [[ -n "$CWD" ]] && printf 'cwd=%s\n' "$CWD"
  [[ -n "$BRIEF_REL" ]] && printf 'brief=%s\n' "$BRIEF_REL"
  printf 'error=%s\n' "$msg"
  printf 'orca-spawn: %s\n' "$msg" >&2
  exit 1
}

need_value() {
  local flag=$1
  shift
  (($# >= 2)) || die "$flag needs a value"
}

require_uuid_value() {
  local label=$1 value=$2
  [[ -n "$value" ]] || die "$label is required"
  [[ "$value" =~ $UUID_RE ]] || die "$label '$value' is not a UUID; positional refs drift, pass the stable UUID"
}

is_ready() {
  local screen=$1
  case "$agent" in
    codex)
      grep -qF -- "$ready_marker" <<<"$screen" && grep -qF -- " · " <<<"$screen"
      ;;
    *)
      grep -qF -- "$ready_marker" <<<"$screen"
      ;;
  esac
}

read_worker_screen() {
  local out
  if ! out=$("$ORCA_CMUX" read-screen --surface "$SURFACE" --lines 40 2>&1); then
    out=${out//$'\n'/ }
    spawn_fail "failed to read worker screen: $out"
  fi
  printf '%s\n' "$out"
}

resolve_origin_surface() {
  local origin
  origin=$(jq -r '.caller.surface_id // .surface_id // empty' <<<"$identify" 2>/dev/null)
  if [[ "$origin" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    ORIGIN_SURFACE=$origin
  fi
}

append_parent_footer() {
  local message=$1
  while [[ "$message" == *$'\n' ]]; do message=${message%$'\n'}; done
  if [[ -n "$ORIGIN_SURFACE" ]]; then
    printf '%s\n[From the parent agent at surface %s. To reply to the parent, use the orca-msg skill targeting that surface if needed.]' \
      "$message" "$ORIGIN_SURFACE"
  else
    printf '%s\n[From the parent agent; the parent surface was not available. To reply to the parent, ask the human for a target surface_id and use the orca-msg skill if needed.]' \
      "$message"
  fi
}

# Fail after the worker tab exists: leave it open, name the surface, exit 1.
spawn_fail() {
  local msg=$1
  printf 'status=error\n'
  [[ -n "$TASK_ID" ]] && printf 'task_id=%s\n' "$TASK_ID"
  [[ -n "$WORKSPACE" ]] && printf 'workspace=%s\n' "$WORKSPACE"
  [[ -n "$WORKSPACE_NAME" ]] && printf 'workspace_name=%s\n' "$WORKSPACE_NAME"
  [[ -n "$WORKSPACE_CREATED" ]] && printf 'workspace_created=%s\n' "$WORKSPACE_CREATED"
  [[ -n "$SURFACE" ]] && printf 'surface=%s\n' "$SURFACE"
  [[ -n "$CWD" ]] && printf 'cwd=%s\n' "$CWD"
  [[ -n "$BRIEF_REL" ]] && printf 'brief=%s\n' "$BRIEF_REL"
  printf 'error=%s\n' "$msg"
  if [[ -n "$SURFACE" ]]; then
    printf 'orca-spawn: %s Worker tab left open at surface %s so you can inspect it.\n' \
      "$msg" "$SURFACE" >&2
  else
    printf 'orca-spawn: %s\n' "$msg" >&2
  fi
  exit 1
}

# --- parse arguments -------------------------------------------------------
agent=""; task=""; brief=""; brief_file=""; cwd_override=""; workspace_name_selector=""; workspace_id_selector=""
have_brief_text=0; have_brief_file=0
while (($#)); do
  case "$1" in
    --agent)          need_value --agent "$@"; agent=$2; shift 2 ;;
    --task)           need_value --task "$@"; task=$2; shift 2 ;;
    --brief)          need_value --brief "$@"; brief=$2; have_brief_text=1; shift 2 ;;
    --brief-file)     need_value --brief-file "$@"; brief_file=$2; have_brief_file=1; shift 2 ;;
    --cwd)            need_value --cwd "$@"; cwd_override=$2; shift 2 ;;
    --workspace-name) need_value --workspace-name "$@"; workspace_name_selector=$2; shift 2 ;;
    --workspace-id)   need_value --workspace-id "$@"; workspace_id_selector=$2; shift 2 ;;
    -h|--help)        die "usage: orca-spawn --agent <claude|codex> --task <title> (--brief <text>|--brief-file <path>) [--cwd <dir>] [--workspace-name <name>|--workspace-id <uuid>]" ;;
    *) die "unexpected argument: $1" ;;
  esac
done
[[ -n "$agent" ]] || die "--agent is required"
[[ -n "$task" ]]  || die "--task is required"
((have_brief_text + have_brief_file == 1)) || die "exactly one of --brief or --brief-file is required"
[[ -z "$workspace_name_selector" || -z "$workspace_id_selector" ]] || die "at most one workspace selector may be supplied"
[[ -z "$workspace_id_selector" ]] || require_uuid_value "--workspace-id" "$workspace_id_selector"

# --- adapter selection (validates the agent type) --------------------------
launch=$("$ORCA_ADAPTER" "$agent" launch 2>/dev/null) \
  || die "unknown agent type: $agent (known: $("$ORCA_ADAPTER" list | paste -sd, -))"
ready_marker=$("$ORCA_ADAPTER" "$agent" ready-marker)
mode=$("$ORCA_ADAPTER" "$agent" mode)

# --- brief content ---------------------------------------------------------
if [[ -n "$brief_file" ]]; then
  [[ -f "$brief_file" ]] || die "brief file not found: $brief_file"
  brief=$(cat "$brief_file")
fi

# --- 1. resolve the target workspace UUID and directory --------------------
identify=$(CMUX_QUIET=1 "$ORCA_CMUX" identify-json 2>/dev/null) \
  || die "cannot reach cmux (is it running, and are we inside a cmux terminal?)"
ws=$(jq -r '.caller.workspace_id // empty' <<<"$identify" 2>/dev/null)
[[ -n "$ws" ]] || die "could not resolve the calling workspace UUID from cmux identify"
window=$(jq -r '.caller.window_id // .window_id // empty' <<<"$identify" 2>/dev/null)
resolve_origin_surface

workspaces=$(CMUX_QUIET=1 "$ORCA_CMUX" list-workspaces-json 2>/dev/null) \
  || die "could not list cmux workspaces"

caller_cwd=$(jq -r --arg ws "$ws" \
  '(.workspaces // .items // [])[]? | select(.id==$ws) | .current_directory // empty' \
  <<<"$workspaces" 2>/dev/null | head -1)
caller_name=$(jq -r --arg ws "$ws" \
  '(.workspaces // .items // [])[]? | select(.id==$ws) | if (.custom_title // "") != "" then .custom_title else (.title // "") end' \
  <<<"$workspaces" 2>/dev/null | head -1)

WORKSPACE_CREATED=false

if [[ -n "$workspace_name_selector" ]]; then
  match_count=$(jq -r --arg name "$workspace_name_selector" \
    '[ (.workspaces // .items // [])[]? | select((.custom_title // "") == $name or (.title // "") == $name) ] | length' \
    <<<"$workspaces" 2>/dev/null)
  [[ "$match_count" =~ ^[0-9]+$ ]] || die "could not parse cmux workspace list"
  if ((match_count > 1)); then
    die "workspace name '$workspace_name_selector' is ambiguous; use --workspace-id with a stable workspace UUID"
  elif ((match_count == 1)); then
    WORKSPACE=$(jq -r --arg name "$workspace_name_selector" \
      '[ (.workspaces // .items // [])[]? | select((.custom_title // "") == $name or (.title // "") == $name) ][0].id' \
      <<<"$workspaces")
    WORKSPACE_NAME=$(jq -r --arg name "$workspace_name_selector" \
      '[ (.workspaces // .items // [])[]? | select((.custom_title // "") == $name or (.title // "") == $name) ][0] | if (.custom_title // "") == $name then (.custom_title // "") else (.title // "") end' \
      <<<"$workspaces")
    workspace_cwd=$(jq -r --arg name "$workspace_name_selector" \
      '[ (.workspaces // .items // [])[]? | select((.custom_title // "") == $name or (.title // "") == $name) ][0].current_directory // empty' \
      <<<"$workspaces")
    CWD=${cwd_override:-$workspace_cwd}
  else
    WORKSPACE_NAME=$workspace_name_selector
    CWD=${cwd_override:-$caller_cwd}
    [[ -n "$CWD" ]] || CWD=$PWD
    [[ -d "$CWD" ]] || die "working directory does not exist: $CWD"
    [[ -n "$window" ]] || die "could not resolve the calling window UUID from cmux identify"
    require_uuid_value "window" "$window"
    WORKSPACE=$("$ORCA_CMUX" create-workspace --name "$workspace_name_selector" --cwd "$CWD" --window "$window" 2>/dev/null) \
      || die "could not create target workspace '$workspace_name_selector'"
    [[ -n "$WORKSPACE" ]] || die "create-workspace returned no workspace UUID"
    WORKSPACE_CREATED=true
  fi
elif [[ -n "$workspace_id_selector" ]]; then
  match_count=$(jq -r --arg ws "$workspace_id_selector" \
    '[ (.workspaces // .items // [])[]? | select(.id==$ws) ] | length' \
    <<<"$workspaces" 2>/dev/null)
  [[ "$match_count" =~ ^[0-9]+$ ]] || die "could not parse cmux workspace list"
  ((match_count == 1)) || die "workspace id not found in caller window: $workspace_id_selector"
  WORKSPACE=$workspace_id_selector
  WORKSPACE_NAME=$(jq -r --arg ws "$workspace_id_selector" \
    '[ (.workspaces // .items // [])[]? | select(.id==$ws) ][0] | if (.custom_title // "") != "" then .custom_title else (.title // "") end' \
    <<<"$workspaces")
  workspace_cwd=$(jq -r --arg ws "$workspace_id_selector" \
    '[ (.workspaces // .items // [])[]? | select(.id==$ws) ][0].current_directory // empty' \
    <<<"$workspaces")
  CWD=${cwd_override:-$workspace_cwd}
else
  WORKSPACE=$ws
  WORKSPACE_NAME=$caller_name
  CWD=${cwd_override:-$caller_cwd}
  [[ -n "$CWD" ]] || CWD=$PWD
fi
[[ -d "$CWD" ]] || die "working directory does not exist: $CWD"

# --- 2. task id (kebab slug, collision-suffixed) ---------------------------
slug=$(printf '%s' "$task" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')
slug=${slug#-}; slug=${slug%-}
[[ -n "$slug" ]] || slug=task

briefs_dir="$CWD/.orca/briefs"
mkdir -p "$briefs_dir" || die "could not create $briefs_dir"
TASK_ID=$slug
n=2
while true; do
  BRIEF_REL=".orca/briefs/$TASK_ID.md"
  brief_path="$CWD/$BRIEF_REL"
  if [[ -e "$brief_path" ]]; then
    TASK_ID="$slug-$n"; n=$((n + 1))
    continue
  fi
  if ( set -o noclobber; printf '%s\n' "$brief" > "$brief_path" ) 2>/dev/null; then
    break
  fi
  [[ -e "$brief_path" ]] || die "could not write brief to $brief_path"
  TASK_ID="$slug-$n"; n=$((n + 1))
done

# --- 3. write the brief and ensure .orca/ is gitignored --------------------
gitignore="$CWD/.gitignore"
if [[ -f "$gitignore" ]]; then
  if ! grep -qE '^\.orca/?$' "$gitignore"; then
    [[ -s "$gitignore" && $(tail -c 1 "$gitignore") != $'\n' ]] && printf '\n' >> "$gitignore"
    printf '.orca/\n' >> "$gitignore"
  fi
else
  printf '.orca/\n' > "$gitignore"
fi

# --- 4. create the worker tab (every later op targets this UUID) -----------
SURFACE=$("$ORCA_CMUX" create-tab --workspace "$WORKSPACE" --cwd "$CWD" 2>/dev/null) \
  || die "could not create the worker tab (cmux unreachable?)"
[[ -n "$SURFACE" ]] || die "create-tab returned no surface UUID"

# Name the tab from the task id (cmux may later replace it with its own title).
"$CMUX_BIN" rename-tab --surface "$SURFACE" "$TASK_ID" >/dev/null 2>&1 || true

# --- 5. launch the agent in the worker cwd ---------------------------------
"$ORCA_CMUX" send --surface "$SURFACE" "$launch" >/dev/null \
  || spawn_fail "failed to send the launch command"
"$ORCA_CMUX" send-key --surface "$SURFACE" enter >/dev/null \
  || spawn_fail "failed to send enter after launch"

# --- 6. poll until the readiness marker appears ----------------------------
ready=0
for ((p = 0; p < ORCA_READY_POLLS; p++)); do
  screen=$(read_worker_screen)
  if orca_maybe_accept_trust_prompt "$screen" "$SURFACE"; then
    sleep "$ORCA_POLL_INTERVAL"
    continue
  else
    trust_rc=$?
    case "$trust_rc" in
      1) ;;
      2) spawn_fail "failed to answer the trust prompt" ;;
      3) spawn_fail "failed to submit the trust prompt answer" ;;
      *) spawn_fail "failed to handle the trust prompt" ;;
    esac
  fi
  if orca_maybe_dismiss_upgrade_prompt "$screen" "$SURFACE"; then
    sleep "$ORCA_POLL_INTERVAL"
    continue
  else
    upgrade_rc=$?
    case "$upgrade_rc" in
      1) ;;
      2) spawn_fail "failed to answer the upgrade prompt" ;;
      3) spawn_fail "failed to submit the upgrade prompt answer" ;;
      *) spawn_fail "failed to handle the upgrade prompt" ;;
    esac
  fi
  if is_ready "$screen"; then ready=1; break; fi
  sleep "$ORCA_POLL_INTERVAL"
done
((ready == 1)) || spawn_fail "readiness marker '$ready_marker' never appeared (agent did not come up)."

# --- 7. mode step (optional; cycle until the target marker appears) --------
if [[ "$mode" == cycle ]]; then
  mode_key=$("$ORCA_ADAPTER" "$agent" mode-key)
  mode_target=$("$ORCA_ADAPTER" "$agent" mode-target)
  mode_max=$("$ORCA_ADAPTER" "$agent" mode-max-attempts)
  attempts=0
  while true; do
    screen=$(read_worker_screen)
    if grep -qF -- "$mode_target" <<<"$screen"; then break; fi
    if ((attempts >= mode_max)); then
      spawn_fail "mode never reached '$mode_target' after $mode_max attempts."
    fi
    "$ORCA_CMUX" send-key --surface "$SURFACE" "$mode_key" >/dev/null \
      || spawn_fail "failed to send the mode key '$mode_key'"
    attempts=$((attempts + 1))
    sleep "$ORCA_MODE_INTERVAL"
  done
fi

# --- 8. deliver the brief by pointer ---------------------------------------
delivery=$(append_parent_footer "Read $BRIEF_REL and carry out the task it describes.")
"$ORCA_CMUX" send --surface "$SURFACE" "$delivery" >/dev/null \
  || spawn_fail "failed to deliver the brief"
"$ORCA_CMUX" send-key --surface "$SURFACE" enter >/dev/null \
  || spawn_fail "failed to send enter after the brief"

# --- 9. report back --------------------------------------------------------
printf 'status=ok\n'
printf 'task_id=%s\n' "$TASK_ID"
printf 'workspace=%s\n' "$WORKSPACE"
printf 'workspace_name=%s\n' "$WORKSPACE_NAME"
printf 'workspace_created=%s\n' "$WORKSPACE_CREATED"
printf 'surface=%s\n' "$SURFACE"
printf 'tab=%s\n' "$TASK_ID"
printf 'cwd=%s\n' "$CWD"
printf 'brief=%s\n' "$BRIEF_REL"
