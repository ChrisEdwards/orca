#!/usr/bin/env bash
#
# orca-msg - send a follow-up message to an existing agent surface.
#
# Resolves a cmux terminal surface by stable UUID, pasted copy-ids block, or a
# conservative human descriptor. It then verifies the surface is at a known
# Claude/Codex input prompt before sending exact text and pressing Enter.
set -uo pipefail

BIN_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ORCA_CMUX="$BIN_DIR/orca-cmux.sh"

export CMUX_BIN=${CMUX_BIN:-cmux}

ORCA_READY_POLLS=${ORCA_READY_POLLS:-5}
ORCA_POLL_INTERVAL=${ORCA_POLL_INTERVAL:-1}

UUID_RE='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'

SURFACE=""
AGENT=""
TARGET=""
TARGET_FILE=""
MESSAGE=""
MESSAGE_FILE=""
MESSAGE_FILE_ABS=""
ORIGIN_SURFACE=""
HAVE_MESSAGE=0
HAVE_MESSAGE_FILE=0

die() {
  local msg=$1
  printf 'status=error\n'
  [[ -n "$SURFACE" ]] && printf 'surface=%s\n' "$SURFACE"
  [[ -n "$AGENT" ]] && printf 'agent=%s\n' "$AGENT"
  [[ -n "$MESSAGE_FILE_ABS" ]] && printf 'message_file=%s\n' "$MESSAGE_FILE_ABS"
  printf 'error=%s\n' "$msg"
  printf 'orca-msg: %s\n' "$msg" >&2
  exit 1
}

need_clarification() {
  local msg=$1 candidates_file=${2:-}
  printf 'status=needs_clarification\n'
  [[ -n "$SURFACE" ]] && printf 'surface=%s\n' "$SURFACE"
  [[ -n "$AGENT" ]] && printf 'agent=%s\n' "$AGENT"
  printf 'error=%s\n' "$msg"
  if [[ -n "$candidates_file" && -s "$candidates_file" ]]; then
    while IFS='|' read -r sfc agent ws title cwd ref; do
      printf 'candidate=surface=%s agent=%s workspace=%s title=%s cwd=%s ref=%s\n' \
        "$sfc" "${agent:-unknown}" "$ws" "$title" "$cwd" "$ref"
    done < "$candidates_file"
  fi
  printf 'orca-msg: %s\n' "$msg" >&2
  exit 2
}

need_value() {
  local flag=$1
  shift
  (($# >= 2)) || die "$flag needs a value"
}

require_uuid() {
  local label=$1 value=$2
  [[ -n "$value" ]] || die "$label: a UUID is required"
  [[ "$value" =~ $UUID_RE ]] || die "$label: '$value' is not a UUID; positional refs drift, pass the stable UUID"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

contains_lc() {
  local haystack=$1 needle=$2
  [[ -n "$needle" ]] || return 1
  case "$haystack" in
    *"$needle"*) return 0 ;;
    *) return 1 ;;
  esac
}

basename_lc() {
  local value=$1
  value=${value%/}
  value=${value##*/}
  lower "$value"
}

absolute_path() {
  local path=$1 dir base
  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
    return 0
  fi
  dir=$(dirname "$path")
  base=$(basename "$path")
  (cd "$dir" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$base")
}

agent_hint_from_text() {
  local text_lc
  text_lc=$(lower "$1")
  if contains_lc "$text_lc" "claude"; then
    printf 'claude\n'
  elif contains_lc "$text_lc" "codex"; then
    printf 'codex\n'
  fi
}

extract_surface_id() {
  sed -nE 's/^surface_id=([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})$/\1/p' <<<"$1" | head -1
}

active_screen_region() {
  awk '
    {
      sub(/\r$/, "")
      if ($0 ~ /[^[:space:]]/) {
        lines[++n] = $0
      }
    }
    END {
      start = n - 5
      if (start < 1) start = 1
      for (i = start; i <= n; i++) print lines[i]
    }
  ' <<<"$1"
}

live_input_region() {
  awk '
    {
      sub(/\r$/, "")
      if ($0 ~ /[^[:space:]]/) {
        lines[++n] = $0
      }
    }
    END {
      start = n - 1
      if (start < 1) start = 1
      for (i = start; i <= n; i++) print lines[i]
    }
  ' <<<"$1"
}

last_non_empty_line() {
  awk '
    {
      sub(/\r$/, "")
      if ($0 ~ /[^[:space:]]/) {
        line = $0
      }
    }
    END {
      if (line != "") print line
    }
  ' <<<"$1"
}

is_blocked_screen() {
  local region
  region=$(active_screen_region "$1")
  grep -qiE 'merge editor|resolve conflicts' <<<"$region" && return 0
  grep -qiE '(^|[[:space:]])[0-9]+[.)][[:space:]]*(yes|no|allow|deny|continue|quit|approve|reject)($|[^[:alpha:]])' <<<"$region" && return 0
  grep -qiE '(do you trust|is this a project you trust|trust the contents|do you want to allow|allow( this)? (command|tool|tool execution)|permission (to|required|needed))[^?]{0,120}\?' <<<"$region"
}

is_shell_prompt_screen() {
  local line
  line=$(last_non_empty_line "$1")
  case "$line" in
    *'← for agents'*|*'›'*) return 1 ;;
  esac
  if grep -Eq '^[[:space:]]*([$%#]|>|❯|➜)[[:space:]]*$' <<<"$line"; then
    return 0
  fi
  if grep -Eq '^[[:space:]]*[^[:space:]]+@[^[:space:]]+.*[[:space:]]([$%#]|>|❯|➜)[[:space:]]*$' <<<"$line"; then
    return 0
  fi
  if grep -Eq '^[[:space:]]*(/|~|\.{1,2}/)[^[:cntrl:]]*([$%#]|>|❯|➜)[[:space:]]*$' <<<"$line"; then
    return 0
  fi
  if grep -Eq '^[[:space:]]*[^[:space:]]+[[:space:]]+(~|/|\.{1,2}/)[^[:cntrl:]]*([$%#]|>|❯|➜)[[:space:]]*$' <<<"$line"; then
    return 0
  fi
  return 1
}

is_busy_screen() {
  local region
  region=$(active_screen_region "$1")
  grep -qiE '(esc|ctrl-c|ctrl\+c|control-c).{0,40}interrupt|interrupt.{0,40}(esc|ctrl-c|ctrl\+c|control-c)|running command|executing command|working\.\.\.|thinking\.\.\.|streaming response' <<<"$region"
}

claude_screen_ready() {
  local line
  line=$(last_non_empty_line "$1")
  grep -qF '← for agents' <<<"$line"
}

codex_screen_ready() {
  local live line count first second
  live=$(live_input_region "$1")
  count=0
  first=""
  second=""
  while IFS= read -r line; do
    count=$((count + 1))
    if [[ "$count" -eq 1 ]]; then
      first=$line
    elif [[ "$count" -eq 2 ]]; then
      second=$line
    fi
  done <<<"$live"
  [[ "$count" -eq 2 ]] || return 1
  [[ "$first" == *'›'* && "$second" == *' · '* ]]
}

infer_agent_from_screen() {
  local screen=$1 region
  is_blocked_screen "$screen" && return 0
  is_shell_prompt_screen "$screen" && return 0
  is_busy_screen "$screen" && return 0
  if claude_screen_ready "$screen"; then
    printf 'claude\n'
  elif codex_screen_ready "$screen"; then
    printf 'codex\n'
  else
    region=$(active_screen_region "$screen")
    if grep -qiF 'Claude Code' <<<"$region"; then
      printf 'claude\n'
    elif grep -qiF 'OpenAI Codex' <<<"$region"; then
      printf 'codex\n'
    fi
  fi
}

screen_is_ready() {
  local screen=$1 agent=$2
  is_blocked_screen "$screen" && return 2
  is_shell_prompt_screen "$screen" && return 2
  is_busy_screen "$screen" && return 2
  case "$agent" in
    claude) claude_screen_ready "$screen" ;;
    codex) codex_screen_ready "$screen" ;;
    *) return 1 ;;
  esac
}

read_target_screen() {
  local out
  if ! out=$("$ORCA_CMUX" read-screen --surface "$1" --lines 40 2>&1); then
    out=${out//$'\n'/ }
    die "failed to read target screen: $out"
  fi
  printf '%s\n' "$out"
}

resolve_origin_surface() {
  local identify origin
  if ! identify=$("$ORCA_CMUX" identify-json 2>/dev/null); then
    return 0
  fi
  origin=$(jq -r '.caller.surface_id // .surface_id // empty' <<<"$identify" 2>/dev/null)
  if [[ "$origin" =~ $UUID_RE ]]; then
    ORIGIN_SURFACE=$origin
  fi
}

append_reply_footer() {
  local message=$1
  while [[ "$message" == *$'\n' ]]; do message=${message%$'\n'}; done
  if [[ -n "$ORIGIN_SURFACE" ]]; then
    printf '%s\n[From the agent at surface %s. To reply, use the orca-msg skill targeting that surface if needed.]' \
      "$message" "$ORIGIN_SURFACE"
  else
    printf '%s\n[From an Orca message sender; the origin surface was not available. To reply, ask the human for a target surface_id and use the orca-msg skill if needed.]' \
      "$message"
  fi
}

workspace_matches() {
  local desc_lc=$1 title=$2 custom=$3 cwd=$4
  local title_lc custom_lc cwd_lc base_lc
  title_lc=$(lower "$title")
  custom_lc=$(lower "$custom")
  cwd_lc=$(lower "$cwd")
  base_lc=$(basename_lc "$cwd")
  contains_lc "$desc_lc" "$title_lc" && return 0
  contains_lc "$desc_lc" "$custom_lc" && return 0
  contains_lc "$desc_lc" "$base_lc" && return 0
  contains_lc "$desc_lc" "$cwd_lc" && return 0
  return 1
}

resolve_descriptor() {
  local descriptor=$1 desc_lc hint workspaces workspace_rows selected_ws selected_count
  local candidates all_candidates candidate_count sfc detected screen
  desc_lc=$(lower "$descriptor")
  hint=${AGENT:-$(agent_hint_from_text "$descriptor")}

  workspaces=$(mktemp "${TMPDIR:-/tmp}/orca-msg-workspaces.XXXXXX") || die "could not create temp file"
  workspace_rows=$(mktemp "${TMPDIR:-/tmp}/orca-msg-workspace-rows.XXXXXX") || die "could not create temp file"
  selected_ws=$(mktemp "${TMPDIR:-/tmp}/orca-msg-selected-workspaces.XXXXXX") || die "could not create temp file"
  candidates=$(mktemp "${TMPDIR:-/tmp}/orca-msg-candidates.XXXXXX") || die "could not create temp file"
  all_candidates=$(mktemp "${TMPDIR:-/tmp}/orca-msg-all-candidates.XXXXXX") || die "could not create temp file"

  if ! "$ORCA_CMUX" list-workspaces-json > "$workspaces" 2>/dev/null; then
    die "could not list cmux workspaces"
  fi

  jq -r '(.workspaces // .items // [])[] | [.id, (.ref // ""), (.title // ""), (.custom_title // ""), (.current_directory // "")] | @tsv' \
    "$workspaces" > "$workspace_rows" 2>/dev/null || die "could not parse cmux workspace list"

  selected_count=0
  while IFS=$'\t' read -r ws_id ws_ref ws_title ws_custom ws_cwd; do
    [[ -n "$ws_id" ]] || continue
    if workspace_matches "$desc_lc" "$ws_title" "$ws_custom" "$ws_cwd"; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$ws_id" "$ws_ref" "$ws_title" "$ws_custom" "$ws_cwd" >> "$selected_ws"
      selected_count=$((selected_count + 1))
    fi
  done < "$workspace_rows"

  if ((selected_count == 0)); then
    cp "$workspace_rows" "$selected_ws"
  fi

  while IFS=$'\t' read -r ws_id ws_ref ws_title ws_custom ws_cwd; do
    [[ -n "$ws_id" ]] || continue
    surfaces_json=$(mktemp "${TMPDIR:-/tmp}/orca-msg-surfaces.XXXXXX") || die "could not create temp file"
    if ! "$ORCA_CMUX" list-surfaces-json --workspace "$ws_id" > "$surfaces_json" 2>/dev/null; then
      rm -f "$surfaces_json"
      continue
    fi
    jq -r '(.surfaces // .pane_surfaces // .items // [])[] | [.id, (.ref // ""), (.kind // ""), (.cwd // ""), (.shell // ""), (.title // .name // "")] | @tsv' \
      "$surfaces_json" 2>/dev/null |
      while IFS=$'\t' read -r surface_id surface_ref kind cwd shell title; do
        [[ "$kind" == terminal || -z "$kind" ]] || continue
        [[ "$surface_id" =~ $UUID_RE ]] || continue
        screen=$(read_target_screen "$surface_id")
        detected=$(infer_agent_from_screen "$screen")
        printf '%s|%s|%s|%s|%s|%s\n' "$surface_id" "$detected" "${ws_title:-$ws_custom}" "$title" "$cwd" "$surface_ref" >> "$all_candidates"
        if [[ -n "$hint" && -n "$detected" && "$detected" != "$hint" ]]; then
          continue
        fi
        printf '%s|%s|%s|%s|%s|%s\n' "$surface_id" "${detected:-$hint}" "${ws_title:-$ws_custom}" "$title" "$cwd" "$surface_ref" >> "$candidates"
      done
    rm -f "$surfaces_json"
  done < "$selected_ws"

  candidate_count=$(grep -c '^' "$candidates" 2>/dev/null || true)
  if ((candidate_count == 0)); then
    need_clarification "could not resolve target surface from descriptor" "$all_candidates"
  fi
  if ((candidate_count > 1)); then
    need_clarification "target descriptor is ambiguous; choose one surface" "$candidates"
  fi

  IFS='|' read -r sfc detected _rest < "$candidates"
  SURFACE=$sfc
  [[ -n "$AGENT" ]] || AGENT=${detected:-$hint}
}

# --- parse arguments -------------------------------------------------------
while (($#)); do
  case "$1" in
    --surface)      need_value --surface "$@";      SURFACE=$2; shift 2 ;;
    --target)       need_value --target "$@";       TARGET=$2; shift 2 ;;
    --target-file)  need_value --target-file "$@";  TARGET_FILE=$2; shift 2 ;;
    --agent)        need_value --agent "$@";        AGENT=$2; shift 2 ;;
    --message)      need_value --message "$@";      MESSAGE=$2; HAVE_MESSAGE=1; shift 2 ;;
    --message-file) need_value --message-file "$@"; MESSAGE_FILE=$2; HAVE_MESSAGE_FILE=1; shift 2 ;;
    -h|--help)
      die "usage: orca-msg (--surface UUID | --target TEXT | --target-file PATH) [--agent claude|codex] (--message TEXT | --message-file PATH)"
      ;;
    *) die "unexpected argument: $1" ;;
  esac
done

[[ "$AGENT" == "" || "$AGENT" == claude || "$AGENT" == codex ]] || die "--agent must be claude or codex"
((HAVE_MESSAGE + HAVE_MESSAGE_FILE == 1)) || die "exactly one of --message or --message-file is required"

if [[ -n "$TARGET_FILE" ]]; then
  [[ -f "$TARGET_FILE" ]] || die "target file not found: $TARGET_FILE"
  TARGET=$(cat "$TARGET_FILE")
fi

if [[ -z "$SURFACE" ]]; then
  if [[ -z "$TARGET" ]]; then
    die "one of --surface, --target, or --target-file is required"
  fi

  copied_surface=$(extract_surface_id "$TARGET")
  if [[ -n "$copied_surface" ]]; then
    SURFACE=$copied_surface
  elif [[ "$TARGET" =~ $UUID_RE ]]; then
    SURFACE=$TARGET
  elif grep -qE '(^|[[:space:]])(surface_ref|pane_ref|workspace_ref)=' <<<"$TARGET"; then
    need_clarification "pasted cmux ids did not include a stable surface_id"
  else
    resolve_descriptor "$TARGET"
  fi
fi
require_uuid surface "$SURFACE"

if ((HAVE_MESSAGE_FILE)); then
  [[ -f "$MESSAGE_FILE" ]] || die "message file not found: $MESSAGE_FILE"
  MESSAGE_FILE_ABS=$(absolute_path "$MESSAGE_FILE") || die "could not resolve message file path: $MESSAGE_FILE"
  MESSAGE="Read $MESSAGE_FILE_ABS and respond to the request it contains."
fi

resolve_origin_surface
MESSAGE=$(append_reply_footer "$MESSAGE")

# --- readiness -------------------------------------------------------------
ready=0
for ((p = 0; p < ORCA_READY_POLLS; p++)); do
  screen=$(read_target_screen "$SURFACE")
  if is_blocked_screen "$screen"; then
    die "target surface is not ready for a message; it appears to be blocked on a prompt"
  fi
  if [[ -z "$AGENT" ]]; then
    AGENT=$(infer_agent_from_screen "$screen")
  fi
  if [[ -z "$AGENT" ]]; then
    need_clarification "could not determine whether the target surface is Claude or Codex"
  fi
  if screen_is_ready "$screen" "$AGENT"; then
    ready=1
    break
  fi
  sleep "$ORCA_POLL_INTERVAL"
done
((ready == 1)) || die "target surface is not ready for a message"

# --- send ------------------------------------------------------------------
"$ORCA_CMUX" send --surface "$SURFACE" "$MESSAGE" >/dev/null \
  || die "failed to send message"
"$ORCA_CMUX" send-key --surface "$SURFACE" enter >/dev/null \
  || die "failed to submit message"

printf 'status=ok\n'
printf 'surface=%s\n' "$SURFACE"
printf 'agent=%s\n' "$AGENT"
[[ -n "$MESSAGE_FILE_ABS" ]] && printf 'message_file=%s\n' "$MESSAGE_FILE_ABS"
printf 'message_sent=%s\n' "$MESSAGE"
