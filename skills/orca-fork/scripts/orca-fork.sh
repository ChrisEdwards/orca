#!/usr/bin/env bash
#
# orca-fork - fork a provider conversation into a new cmux tab.
#
# Runs the fire-and-confirm sequence for an existing conversation: resolve the
# calling workspace, choose an exact provider-specific source id, open a terminal
# tab, launch the provider fork command, wait for readiness, and report back.
# It does not monitor the fork afterward and never tears down a launched tab.
#
# Usage:
#   orca-fork [--codex-thread-id UUID | --claude-session-id UUID]
#             [--prompt TEXT | --prompt-file PATH] [--title TITLE]
#
# Output (stdout, key=value lines):
#   status=ok|error
#   provider=codex|claude
#   source_conversation=<provider-specific id>
#   surface=<fork surface UUID>        (once the tab is created)
#   tab=<requested tab name>
#   prompt_sent=true|false
#   error=<reason>                     (on failure)
set -uo pipefail

BIN_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ORCA_CMUX="$BIN_DIR/orca-cmux.sh"
ORCA_ADAPTER="$BIN_DIR/orca-fork-adapter.sh"

# shellcheck source=skills/orca-fork/scripts/orca-trust-prompt.sh
. "$BIN_DIR/orca-trust-prompt.sh"
# shellcheck source=skills/orca-fork/scripts/orca-upgrade-prompt.sh
. "$BIN_DIR/orca-upgrade-prompt.sh"

export CMUX_BIN=${CMUX_BIN:-cmux}

ORCA_READY_POLLS=${ORCA_READY_POLLS:-30}
ORCA_POLL_INTERVAL=${ORCA_POLL_INTERVAL:-1}

UUID_RE='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'

PROVIDER=""
SOURCE_ID=""
SURFACE=""
TAB=""
CWD=""
PROMPT=""
PROMPT_SENT=false
ORIGIN_SURFACE=""

emit_known() {
  [[ -n "$PROVIDER" ]] && printf 'provider=%s\n' "$PROVIDER"
  [[ -n "$SOURCE_ID" ]] && printf 'source_conversation=%s\n' "$SOURCE_ID"
  [[ -n "$SURFACE" ]] && printf 'surface=%s\n' "$SURFACE"
  [[ -n "$TAB" ]] && printf 'tab=%s\n' "$TAB"
  printf 'prompt_sent=%s\n' "$PROMPT_SENT"
}

die() {
  local msg=$1
  printf 'status=error\n'
  emit_known
  printf 'error=%s\n' "$msg"
  printf 'orca-fork: %s\n' "$msg" >&2
  exit 1
}

fork_fail() {
  local msg=$1
  printf 'status=error\n'
  emit_known
  printf 'error=%s\n' "$msg"
  if [[ -n "$SURFACE" ]]; then
    printf 'orca-fork: %s Fork tab left open at surface %s so you can inspect it.\n' \
      "$msg" "$SURFACE" >&2
  else
    printf 'orca-fork: %s\n' "$msg" >&2
  fi
  exit 1
}

need_value() {
  local flag=$1
  shift
  (($# >= 2)) || die "$flag needs a value"
}

slugify() {
  local raw=$1 slug
  slug=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')
  slug=${slug#-}; slug=${slug%-}
  printf '%s\n' "$slug"
}

validate_uuid() {
  local label=$1 value=$2
  [[ "$value" =~ $UUID_RE ]] || die "$label must be a UUID: $value"
}

is_ready() {
  local screen=$1
  case "$PROVIDER" in
    codex)
      grep -qF -- "$ready_marker" <<<"$screen" && grep -qF -- " · " <<<"$screen"
      ;;
    claude)
      grep -qF -- "$ready_marker" <<<"$screen"
      ;;
    *)
      return 1
      ;;
  esac
}

read_fork_screen() {
  local out
  if ! out=$("$ORCA_CMUX" read-screen --surface "$SURFACE" --lines 40 2>&1); then
    out=${out//$'\n'/ }
    fork_fail "failed to read fork screen: $out"
  fi
  printf '%s\n' "$out"
}

resolve_origin_surface() {
  local origin
  origin=$(jq -r '.caller.surface_id // .surface_id // empty' <<<"$identify" 2>/dev/null)
  if [[ "$origin" =~ $UUID_RE ]]; then
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

codex_thread_id=""; claude_session_id=""; title=""
have_codex=0; have_claude=0; have_prompt=0; have_prompt_file=0; prompt_file=""

while (($#)); do
  case "$1" in
    --codex-thread-id)
      need_value --codex-thread-id "$@"
      codex_thread_id=$2; have_codex=1; shift 2
      ;;
    --claude-session-id)
      need_value --claude-session-id "$@"
      claude_session_id=$2; have_claude=1; shift 2
      ;;
    --prompt)
      need_value --prompt "$@"
      PROMPT=$2; have_prompt=1; shift 2
      ;;
    --prompt-file)
      need_value --prompt-file "$@"
      prompt_file=$2; have_prompt_file=1; shift 2
      ;;
    --title)
      need_value --title "$@"
      title=$2; shift 2
      ;;
    --agent|--conversation-id)
      die "$1 is not supported; pass --codex-thread-id or --claude-session-id"
      ;;
    -h|--help)
      die "usage: orca-fork [--codex-thread-id UUID | --claude-session-id UUID] [--prompt TEXT | --prompt-file PATH] [--title TITLE]"
      ;;
    *)
      die "unexpected argument: $1"
      ;;
  esac
done

((have_prompt + have_prompt_file <= 1)) || die "at most one of --prompt or --prompt-file is allowed"
if ((have_prompt_file == 1)); then
  [[ -f "$prompt_file" ]] || die "prompt file not found: $prompt_file"
  PROMPT=$(cat "$prompt_file")
  have_prompt=1
fi
[[ -n "$PROMPT" ]] && PROMPT_SENT=true

((have_codex + have_claude <= 1)) || die "pass only one provider-specific source id"

if ((have_codex == 1)); then
  PROVIDER=codex
  SOURCE_ID=$codex_thread_id
elif ((have_claude == 1)); then
  PROVIDER=claude
  SOURCE_ID=$claude_session_id
else
  # Auto-detect the calling conversation from the provider's own process-local
  # environment variable. Each provider exports its current conversation id into
  # the shell it spawns, so this is an exact source, not a recency guess: Codex
  # sets CODEX_THREAD_ID, Claude Code sets CLAUDE_CODE_SESSION_ID. CLAUDE_CODE_SESSION_ID
  # is undocumented but verified on Claude Code 2.1.191; downstream UUID validation
  # guards a malformed value, and `claude --resume` itself rejects an id that is not
  # resolvable from this workspace. Only trust these from the main loop: a subagent's
  # shell may carry the subagent's own id, so do not invoke orca-fork from inside one.
  auto_codex=${CODEX_THREAD_ID:-}
  auto_claude=${CLAUDE_CODE_SESSION_ID:-}
  if [[ -n "$auto_codex" && -n "$auto_claude" ]]; then
    die "both CODEX_THREAD_ID and CLAUDE_CODE_SESSION_ID are set; pass --codex-thread-id or --claude-session-id to choose the source"
  elif [[ -n "$auto_codex" ]]; then
    PROVIDER=codex
    SOURCE_ID=$auto_codex
  elif [[ -n "$auto_claude" ]]; then
    PROVIDER=claude
    SOURCE_ID=$auto_claude
  else
    die "no exact source conversation id found; pass --codex-thread-id or --claude-session-id"
  fi
fi

validate_uuid "$PROVIDER source id" "$SOURCE_ID"

if [[ -n "$title" ]]; then
  TAB=$(slugify "$title")
elif [[ -n "$PROMPT" ]]; then
  TAB="fork-$(slugify "$PROMPT")"
else
  TAB="fork-$PROVIDER"
fi
TAB=${TAB:0:48}
TAB=${TAB%-}
[[ -n "$TAB" ]] || TAB="fork-$PROVIDER"

identify=$(CMUX_QUIET=1 "$CMUX_BIN" identify --json --id-format both 2>/dev/null) \
  || die "cannot reach cmux (is it running, and are we inside a cmux terminal?)"
ws=$(jq -r '.caller.workspace_id // empty' <<<"$identify" 2>/dev/null)
[[ -n "$ws" ]] || die "could not resolve the calling workspace UUID from cmux identify"
resolve_origin_surface

if [[ -n "$PROMPT" ]]; then
  PROMPT=$(append_parent_footer "$PROMPT")
fi

launch=$("$ORCA_ADAPTER" "$PROVIDER" launch "$SOURCE_ID" "$PROMPT" 2>/dev/null) \
  || die "could not build fork command for $PROVIDER"
ready_marker=$("$ORCA_ADAPTER" "$PROVIDER" ready-marker 2>/dev/null) \
  || die "could not resolve readiness marker for $PROVIDER"

CWD=$(CMUX_QUIET=1 "$CMUX_BIN" list-workspaces --json --id-format both 2>/dev/null \
  | jq -r --arg ws "$ws" '.workspaces[]? | select(.id==$ws) | .current_directory // empty' 2>/dev/null)
[[ -n "$CWD" ]] || CWD=$PWD
[[ -d "$CWD" ]] || die "working directory does not exist: $CWD"

SURFACE=$("$ORCA_CMUX" create-tab --workspace "$ws" --cwd "$CWD" 2>/dev/null) \
  || die "could not create the fork tab (cmux unreachable?)"
[[ -n "$SURFACE" ]] || die "create-tab returned no surface UUID"

"$CMUX_BIN" rename-tab --surface "$SURFACE" "$TAB" >/dev/null 2>&1 || true

"$ORCA_CMUX" send --surface "$SURFACE" "$launch" >/dev/null \
  || fork_fail "failed to send the fork command"
"$ORCA_CMUX" send-key --surface "$SURFACE" enter >/dev/null \
  || fork_fail "failed to send enter after fork command"

ready=0
for ((p = 0; p < ORCA_READY_POLLS; p++)); do
  screen=$(read_fork_screen)
  if orca_maybe_accept_trust_prompt "$screen" "$SURFACE"; then
    sleep "$ORCA_POLL_INTERVAL"
    continue
  else
    trust_rc=$?
    case "$trust_rc" in
      1) ;;
      2) fork_fail "failed to answer the trust prompt" ;;
      3) fork_fail "failed to submit the trust prompt answer" ;;
      *) fork_fail "failed to handle the trust prompt" ;;
    esac
  fi
  if orca_maybe_dismiss_upgrade_prompt "$screen" "$SURFACE"; then
    sleep "$ORCA_POLL_INTERVAL"
    continue
  else
    upgrade_rc=$?
    case "$upgrade_rc" in
      1) ;;
      2) fork_fail "failed to answer the upgrade prompt" ;;
      3) fork_fail "failed to submit the upgrade prompt answer" ;;
      *) fork_fail "failed to handle the upgrade prompt" ;;
    esac
  fi
  if is_ready "$screen"; then ready=1; break; fi
  sleep "$ORCA_POLL_INTERVAL"
done
((ready == 1)) || fork_fail "readiness marker '$ready_marker' never appeared (fork did not come ready)."

printf 'status=ok\n'
emit_known
