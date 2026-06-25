#!/usr/bin/env bash
# Integration tests for skills/orca-fork/scripts/orca-fork.sh.
#
# These tests run the real fork script, fork adapter, and cmux seam on top of a
# stateful fake cmux. They verify source selection, command construction,
# readiness polling, tab naming, and failure behavior without launching agents.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
FORK="$REPO_ROOT/skills/orca-fork/scripts/orca-fork.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

CALLS="$TMP/calls.log"
STATE="$TMP/state"
FAKE="$TMP/cmux"

SURFACE="BE7E2B29-66BA-44B4-BE66-73B85C85C7F3"
WS="90D8E74A-E0EE-4FCB-8F7C-105574F46F01"
CODEX_ID="019EFC9B-9880-7810-A352-D6427E876693"
CLAUDE_ID="3B877D88-C1EC-44FC-8987-AEE00A86CD12"

cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
sub=${1:-}; shift || true
{ printf '%s' "$sub"; for a in "$@"; do printf '\t%s' "$a"; done; printf '\n'; } >> "$FAKE_CALLS"

launched="$FAKE_STATE/launched"
trust_selected="$FAKE_STATE/trust-selected"
trusted="$FAKE_STATE/trusted"

case "$sub" in
  identify)
    [[ "${FAKE_SCENARIO:-}" == cmux-down ]] && { echo "cmux: daemon not running" >&2; exit 1; }
    printf '{ "caller": { "workspace_id": "%s", "surface_id": "ORCH-SURFACE-UUID" } }\n' "$FAKE_WS"
    ;;
  list-workspaces|workspace)
    printf '{ "workspaces": [ { "id": "%s", "ref": "workspace:9", "current_directory": "%s" } ] }\n' "$FAKE_WS" "$FAKE_CWD"
    ;;
  new-surface)
    echo "OK surface:43 ($FAKE_SURFACE) pane:16 (PANE-UUID) workspace:9 ($FAKE_WS)"
    ;;
  rename-tab) echo "OK" ;;
  send)
    payload=""; for a in "$@"; do payload=$a; done
    [[ "$payload" == "1" ]] && : > "$trust_selected"
    : > "$launched"
    echo "OK surface:43 workspace:9"
    ;;
  send-key)
    key=""; for a in "$@"; do key=$a; done
    [[ "$key" == "enter" && -f "$trust_selected" ]] && : > "$trusted"
    echo "OK surface:43 workspace:9"
    ;;
  read-screen)
    case "${FAKE_SCENARIO:-}" in
      codex)
        [[ -f "$launched" ]] || { echo "booting codex"; exit 0; }
        printf '› Forked conversation\n'
        printf 'gpt-5.5 high · %s\n' "$FAKE_CWD"
        ;;
      codex-chevron-only)
        [[ -f "$launched" ]] || { echo "booting codex"; exit 0; }
        printf '› shell prompt, not codex\n'
        ;;
      codex-trust)
        [[ -f "$launched" ]] || { echo "booting codex"; exit 0; }
        if [[ ! -f "$trusted" ]]; then
          printf '  Do you trust the contents of this directory?\n'
          printf '› 1. Yes, continue\n'
          printf '  2. No, quit\n'
          exit 0
        fi
        printf '› Forked conversation\n'
        printf 'gpt-5.5 high · %s\n' "$FAKE_CWD"
        ;;
      claude)
        [[ -f "$launched" ]] || { echo "starting Claude Code..."; exit 0; }
        echo "  ? for shortcuts                                   ← for agents"
        ;;
      never-ready)
        echo "loading, please wait..."
        ;;
      read-screen-error)
        echo "screen unavailable" >&2
        exit 2
        ;;
      *) echo "no scenario set" ;;
    esac
    ;;
  close-surface) echo "OK" ;;
  list-pane-surfaces) echo "* surface:43 $FAKE_SURFACE  fork  [selected]" ;;
  *) echo "OK" ;;
esac
EOF
chmod +x "$FAKE"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }
ok() { local desc=$1; shift; if "$@"; then pass; else fail "$desc"; fi; }
no() { local desc=$1; shift; if "$@"; then fail "$desc"; else pass; fi; }

SCENARIO=codex
POLLS=30
DEFAULT_CWD=""
LAST_OUT=""
LAST_ERR=""
LAST_RC=0
AUTO_CODEX=""
AUTO_CLAUDE=""

fork_run() {
  : > "$CALLS"
  rm -rf "$STATE"; mkdir -p "$STATE"
  local errfile="$TMP/stderr"
  # Pin both provider auto-source vars so the runner's real environment (these
  # tests run inside a Claude Code session, which exports CLAUDE_CODE_SESSION_ID)
  # can never leak into the script under test.
  LAST_OUT=$(CMUX_BIN="$FAKE" FAKE_CALLS="$CALLS" FAKE_STATE="$STATE" \
    FAKE_SURFACE="$SURFACE" FAKE_WS="$WS" FAKE_CWD="$DEFAULT_CWD" \
    FAKE_SCENARIO="$SCENARIO" ORCA_READY_POLLS="$POLLS" ORCA_POLL_INTERVAL=0 \
    CODEX_THREAD_ID="$AUTO_CODEX" CLAUDE_CODE_SESSION_ID="$AUTO_CLAUDE" \
    "$FORK" "$@" 2>"$errfile")
  LAST_RC=$?
  LAST_ERR=$(cat "$errfile")
}

field() { grep -E "^$1=" <<<"$LAST_OUT" | head -1 | cut -d= -f2-; }
calls_have() { grep -qF -- "$1" "$CALLS"; }
calls_have_line() { grep -qxF -- "$1" "$CALLS"; }
called_subcommand() { grep -qE "^$1(\t|$)" "$CALLS"; }
mentions() { grep -qiF -- "$1" <<<"$LAST_OUT"$'\n'"$LAST_ERR"; }
mentions_err() { grep -qF -- "$1" <<<"$LAST_ERR"; }
rc_is() { [[ "$LAST_RC" -eq "$1" ]]; }
rc_not() { [[ "$LAST_RC" -ne "$1" ]]; }
eq() { [[ "$1" == "$2" ]]; }

# === Codex auto source, open-only =========================================
WORK="$TMP/repo-codex"; mkdir -p "$WORK"
DEFAULT_CWD="$WORK"; SCENARIO=codex; AUTO_CODEX="$CODEX_ID"
fork_run

ok  "codex auto: exits 0"                    rc_is 0
ok  "codex auto: status=ok"                  eq "$(field status)" ok
ok  "codex auto: provider=codex"             eq "$(field provider)" codex
ok  "codex auto: source conversation"        eq "$(field source_conversation)" "$CODEX_ID"
ok  "codex auto: returns surface UUID"       eq "$(field surface)" "$SURFACE"
ok  "codex auto: default tab name"           eq "$(field tab)" "fork-codex"
ok  "codex auto: no prompt sent"             eq "$(field prompt_sent)" false
ok  "codex auto: create-tab sets cwd"        calls_have $'--working-directory\t'"$WORK"
ok  "codex auto: launch command"             calls_have_line $'send\t--surface\t'"$SURFACE"$'\tcodex fork '"$CODEX_ID"
ok  "codex auto: enter after command"        calls_have_line $'send-key\t--surface\t'"$SURFACE"$'\tenter'
ok  "codex auto: renames the tab"            calls_have_line $'rename-tab\t--surface\t'"$SURFACE"$'\tfork-codex'
no  "codex auto: never closes surface"       called_subcommand close-surface

# === Codex explicit source with prompt =====================================
WORK2="$TMP/repo-codex-explicit"; mkdir -p "$WORK2"
DEFAULT_CWD="$WORK2"; SCENARIO=codex; AUTO_CODEX=""
fork_run --codex-thread-id "$CODEX_ID" --prompt "Investigate auth failures" --title "Auth Fork"

quoted_prompt=$(printf '%q' "Investigate auth failures")
ok  "codex explicit: exits 0"              rc_is 0
ok  "codex explicit: prompt sent"          eq "$(field prompt_sent)" true
ok  "codex explicit: title slug used"      eq "$(field tab)" "auth-fork"
ok  "codex explicit: prompt at launch" \
      calls_have_line $'send\t--surface\t'"$SURFACE"$'\tcodex fork '"$CODEX_ID $quoted_prompt"

# === Codex trust prompt is answered before readiness =======================
WORK_TRUST="$TMP/repo-codex-trust"; mkdir -p "$WORK_TRUST"
DEFAULT_CWD="$WORK_TRUST"; SCENARIO=codex-trust; AUTO_CODEX="$CODEX_ID"
fork_run --title "Trust Fork"

ok  "codex trust: exits 0"                rc_is 0
ok  "codex trust: answered yes"           calls_have_line $'send\t--surface\t'"$SURFACE"$'\t1'
ok  "codex trust: submitted answer"       calls_have_line $'send-key\t--surface\t'"$SURFACE"$'\tenter'
ok  "codex trust: tab name"               eq "$(field tab)" "trust-fork"

# === Claude explicit source ===============================================
WORK3="$TMP/repo-claude"; mkdir -p "$WORK3"
DEFAULT_CWD="$WORK3"; SCENARIO=claude; AUTO_CODEX=""
fork_run --claude-session-id "$CLAUDE_ID"

ok  "claude explicit: exits 0"              rc_is 0
ok  "claude explicit: provider=claude"      eq "$(field provider)" claude
ok  "claude explicit: default tab name"     eq "$(field tab)" "fork-claude"
ok  "claude explicit: launch command" \
      calls_have_line $'send\t--surface\t'"$SURFACE"$'\tclaude --resume '"$CLAUDE_ID"$' --fork-session'

# === Claude auto source via CLAUDE_CODE_SESSION_ID =========================
WORK_CLAUDE_AUTO="$TMP/repo-claude-auto"; mkdir -p "$WORK_CLAUDE_AUTO"
DEFAULT_CWD="$WORK_CLAUDE_AUTO"; SCENARIO=claude; AUTO_CODEX=""; AUTO_CLAUDE="$CLAUDE_ID"
fork_run
AUTO_CLAUDE=""

ok  "claude auto: exits 0"                   rc_is 0
ok  "claude auto: status=ok"                 eq "$(field status)" ok
ok  "claude auto: provider=claude"           eq "$(field provider)" claude
ok  "claude auto: source conversation"       eq "$(field source_conversation)" "$CLAUDE_ID"
ok  "claude auto: default tab name"          eq "$(field tab)" "fork-claude"
ok  "claude auto: no prompt sent"            eq "$(field prompt_sent)" false
ok  "claude auto: launch command" \
      calls_have_line $'send\t--surface\t'"$SURFACE"$'\tclaude --resume '"$CLAUDE_ID"$' --fork-session'

# === Explicit flag wins over a present auto env var ========================
DEFAULT_CWD="$WORK"; SCENARIO=codex; AUTO_CODEX=""; AUTO_CLAUDE="$CLAUDE_ID"
fork_run --codex-thread-id "$CODEX_ID"
AUTO_CLAUDE=""
ok  "explicit wins: exits 0"                 rc_is 0
ok  "explicit wins: provider=codex"          eq "$(field provider)" codex
ok  "explicit wins: source is codex id"      eq "$(field source_conversation)" "$CODEX_ID"

# === Both auto env sources present is ambiguous ============================
DEFAULT_CWD="$WORK"; SCENARIO=codex; AUTO_CODEX="$CODEX_ID"; AUTO_CLAUDE="$CLAUDE_ID"
fork_run
AUTO_CLAUDE=""
ok  "both auto: exits non-zero"              rc_not 0
ok  "both auto: status=error"                eq "$(field status)" error
ok  "both auto: actionable"                  mentions "--claude-session-id"
no  "both auto: no tab created"              called_subcommand new-surface

# === Prompt file supports multiline prompt-at-launch =======================
PROMPT_FILE="$TMP/prompt.md"
printf 'line one\nline two\n' > "$PROMPT_FILE"
multiline=$(cat "$PROMPT_FILE")
quoted_multiline=$(printf '%q' "$multiline")
DEFAULT_CWD="$WORK2"; SCENARIO=codex; AUTO_CODEX=""
fork_run --codex-thread-id "$CODEX_ID" --prompt-file "$PROMPT_FILE"
ok  "prompt file: exits 0"                  rc_is 0
ok  "prompt file: prompt sent"              eq "$(field prompt_sent)" true
ok  "prompt file: command is shell quoted" \
      calls_have_line $'send\t--surface\t'"$SURFACE"$'\tcodex fork '"$CODEX_ID $quoted_multiline"

# === Source selection failures before tab creation =========================
DEFAULT_CWD="$WORK"; SCENARIO=codex; AUTO_CODEX=""
fork_run
ok  "missing source: exits non-zero"       rc_not 0
ok  "missing source: status=error"         eq "$(field status)" error
ok  "missing source: actionable"           mentions "--codex-thread-id"
no  "missing source: no tab created"       called_subcommand new-surface

DEFAULT_CWD="$WORK"; SCENARIO=codex; AUTO_CODEX=""
fork_run --codex-thread-id "$CODEX_ID" --claude-session-id "$CLAUDE_ID"
ok  "multiple explicit: exits non-zero"    rc_not 0
ok  "multiple explicit: explains source"   mentions "only one"
no  "multiple explicit: no tab created"    called_subcommand new-surface

DEFAULT_CWD="$WORK"; SCENARIO=codex; AUTO_CODEX=""
fork_run --agent codex --codex-thread-id "$CODEX_ID"
ok  "agent flag: exits non-zero"           rc_not 0
ok  "agent flag: rejected"                 mentions "not supported"
no  "agent flag: no tab created"           called_subcommand new-surface

DEFAULT_CWD="$WORK"; SCENARIO=codex; AUTO_CODEX=""
fork_run --conversation-id "$CODEX_ID"
ok  "generic conversation flag: exits non-zero" rc_not 0
ok  "generic conversation flag: rejected"       mentions "not supported"
no  "generic conversation flag: no tab created" called_subcommand new-surface

DEFAULT_CWD="$WORK"; SCENARIO=codex; AUTO_CODEX=""
fork_run --codex-thread-id not-a-uuid
ok  "bad uuid: exits non-zero"             rc_not 0
ok  "bad uuid: rejected"                   mentions "must be a UUID"
no  "bad uuid: no tab created"             called_subcommand new-surface

# === Readiness failures leave tab open =====================================
WORK4="$TMP/repo-fail"; mkdir -p "$WORK4"
DEFAULT_CWD="$WORK4"; SCENARIO=never-ready; AUTO_CODEX="$CODEX_ID"; POLLS=3
fork_run
POLLS=30
ok  "readiness fail: exits non-zero"       rc_not 0
ok  "readiness fail: status=error"         eq "$(field status)" error
ok  "readiness fail: reports surface"      eq "$(field surface)" "$SURFACE"
ok  "readiness fail: mentions readiness"   mentions readiness
ok  "readiness fail: stderr names surface" mentions_err "$SURFACE"
no  "readiness fail: tab left open"        called_subcommand close-surface

WORK5="$TMP/repo-chevron"; mkdir -p "$WORK5"
DEFAULT_CWD="$WORK5"; SCENARIO=codex-chevron-only; AUTO_CODEX="$CODEX_ID"; POLLS=3
fork_run
POLLS=30
ok  "codex chevron-only: exits non-zero"   rc_not 0
ok  "codex chevron-only: status=error"     eq "$(field status)" error
ok  "codex chevron-only: mentions ready"   mentions readiness

WORK6="$TMP/repo-read-error"; mkdir -p "$WORK6"
DEFAULT_CWD="$WORK6"; SCENARIO=read-screen-error; AUTO_CODEX="$CODEX_ID"
fork_run
ok  "read-screen error: exits non-zero"    rc_not 0
ok  "read-screen error: status=error"      eq "$(field status)" error
ok  "read-screen error: reports read"      mentions "failed to read fork screen"

# === cmux unreachable fails before tab creation ============================
DEFAULT_CWD="$WORK"; SCENARIO=cmux-down; AUTO_CODEX="$CODEX_ID"
fork_run
ok  "cmux down: exits non-zero"            rc_not 0
no  "cmux down: no tab created"            called_subcommand new-surface

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
