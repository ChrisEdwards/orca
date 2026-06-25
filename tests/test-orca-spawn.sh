#!/usr/bin/env bash
# Integration tests for bin/orca-spawn.
#
# orca-spawn drives the full spawn sequence (resolve workspace, write brief,
# create tab, launch, poll readiness, cycle mode, deliver brief, confirm). These
# tests run the REAL orca-cmux and orca-adapter on top of a stateful fake cmux
# injected via CMUX_BIN. The fake simulates a terminal screen so the polling and
# mode-cycle control flow is exercised deterministically, with no real agents.
#
# No external test deps beyond jq (which orca-spawn itself needs).
# Run: tests/test-orca-spawn.sh
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
SPAWN="$REPO_ROOT/bin/orca-spawn"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

CALLS="$TMP/calls.log"
STATE="$TMP/state"
FAKE="$TMP/cmux"

SURFACE="BE7E2B29-66BA-44B4-BE66-73B85C85C7F3"
WS="90D8E74A-E0EE-4FCB-8F7C-105574F46F01"

# --- stateful fake cmux ----------------------------------------------------
# Logs every invocation to $FAKE_CALLS and simulates a terminal screen via
# $FAKE_SCENARIO plus on-disk state (launched marker, shift+tab counter).
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
sub=${1:-}; shift || true
{ printf '%s' "$sub"; for a in "$@"; do printf '\t%s' "$a"; done; printf '\n'; } >> "$FAKE_CALLS"

keyfile="$FAKE_STATE/keycount"
launched="$FAKE_STATE/launched"
kc=0; [[ -f "$keyfile" ]] && kc=$(cat "$keyfile")

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
    : > "$launched"
    echo "OK surface:43 workspace:9"
    ;;
  send-key)
    key=""; for a in "$@"; do key=$a; done
    [[ "$key" == "shift+tab" ]] && printf '%s' "$((kc + 1))" > "$keyfile"
    echo "OK surface:43 workspace:9"
    ;;
  read-screen)
    case "${FAKE_SCENARIO:-}" in
      claude)
        [[ -f "$launched" ]] || { echo "starting Claude Code..."; exit 0; }
        case $((kc % 4)) in
          0) echo "  ? for shortcuts                                   ← for agents" ;;
          1) echo "  ⏵⏵ accept edits on (shift+tab to cycle) ·         ← for agents" ;;
          2) echo "  ⏸ plan mode on (shift+tab to cycle) ·             ← for agents" ;;
          3) echo "  ⏵⏵ auto mode on (shift+tab to cycle) ·            ← for agents" ;;
        esac
        ;;
      claude-stuck)
        [[ -f "$launched" ]] || { echo "starting Claude Code..."; exit 0; }
        echo "  ? for shortcuts                                   ← for agents"
        ;;
      codex)
        [[ -f "$launched" ]] || { echo "booting codex"; exit 0; }
        printf '› Implement {feature}\n'
        printf 'gpt-5.5 high · %s\n' "$FAKE_CWD"
        ;;
      codex-chevron-only)
        [[ -f "$launched" ]] || { echo "booting codex"; exit 0; }
        printf '› shell prompt, not codex\n'
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
  list-pane-surfaces) echo "* surface:43 $FAKE_SURFACE  worker  [selected]" ;;
  *) echo "OK" ;;
esac
EOF
chmod +x "$FAKE"

# --- assertion helpers -----------------------------------------------------
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }

# ok <desc> <cmd...>  -> pass when cmd exits 0
ok() { local desc=$1; shift; if "$@"; then pass; else fail "$desc"; fi; }
# no <desc> <cmd...>  -> pass when cmd exits non-zero
no() { local desc=$1; shift; if "$@"; then fail "$desc"; else pass; fi; }

SCENARIO=""        # set per test before calling spawn()
POLLS=30
DEFAULT_CWD=""     # the caller workspace dir the fake reports
LAST_OUT=""
LAST_ERR=""
LAST_RC=0

# Run orca-spawn with the fake wired in and intervals zeroed for speed.
spawn() {
  : > "$CALLS"
  rm -rf "$STATE"; mkdir -p "$STATE"
  local errfile="$TMP/stderr"
  LAST_OUT=$(CMUX_BIN="$FAKE" FAKE_CALLS="$CALLS" FAKE_STATE="$STATE" \
    FAKE_SURFACE="$SURFACE" FAKE_WS="$WS" FAKE_CWD="$DEFAULT_CWD" \
    FAKE_SCENARIO="$SCENARIO" \
    ORCA_READY_POLLS="$POLLS" ORCA_POLL_INTERVAL=0 ORCA_MODE_INTERVAL=0 \
    "$SPAWN" "$@" 2>"$errfile")
  LAST_RC=$?
  LAST_ERR=$(cat "$errfile")
}

field() { grep -E "^$1=" <<<"$LAST_OUT" | head -1 | cut -d= -f2-; }
count_shift_tabs() { grep -c $'\tshift+tab$' "$CALLS"; }
calls_have() { grep -qF -- "$1" "$CALLS"; }
calls_have_line() { grep -qxF -- "$1" "$CALLS"; }
called_subcommand() { grep -qE "^$1(\t|$)" "$CALLS"; }
mentions() { grep -qiF "$1" <<<"$LAST_OUT"$'\n'"$LAST_ERR"; }
mentions_err() { grep -qF "$1" <<<"$LAST_ERR"; }
rc_is() { [[ "$LAST_RC" -eq "$1" ]]; }
rc_not() { [[ "$LAST_RC" -ne "$1" ]]; }
eq() { [[ "$1" == "$2" ]]; }

spawn_must_finish() {
  local timeout=$1; shift
  local out="$TMP/timeout.out" err="$TMP/timeout.err" done="$TMP/timeout.done"
  rm -f "$out" "$err" "$done"
  CMUX_BIN="$FAKE" FAKE_CALLS="$CALLS" FAKE_STATE="$STATE" \
    FAKE_SURFACE="$SURFACE" FAKE_WS="$WS" FAKE_CWD="$DEFAULT_CWD" \
    FAKE_SCENARIO="$SCENARIO" \
    ORCA_READY_POLLS="$POLLS" ORCA_POLL_INTERVAL=0 ORCA_MODE_INTERVAL=0 \
    "$SPAWN" "$@" >"$out" 2>"$err" &
  local pid=$!
  (
    sleep "$timeout"
    kill "$pid" 2>/dev/null || true
  ) &
  local watcher=$!
  wait "$pid"
  local rc=$?
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  LAST_OUT=$(cat "$out")
  LAST_ERR=$(cat "$err")
  LAST_RC=$rc
  [[ "$rc" -ne 143 && "$rc" -ne 137 ]]
}

# === Claude happy path =====================================================
WORK="$TMP/repo-claude"; mkdir -p "$WORK"
DEFAULT_CWD="$WORK"; SCENARIO=claude
spawn --agent claude --task "Fix the login bug" --brief "Make login work."

ok  "claude: exits 0"                      rc_is 0
ok  "claude: status=ok"                    eq "$(field status)" ok
ok  "claude: returns the surface UUID"     eq "$(field surface)" "$SURFACE"
ok  "claude: task id is a kebab slug"      eq "$(field task_id)" "fix-the-login-bug"
ok  "claude: tab named from task id"       eq "$(field tab)" "fix-the-login-bug"
ok  "claude: cycles shift+tab to auto (3)" eq "$(count_shift_tabs)" 3
ok  "claude: delivers pointer brief" \
      calls_have "Read .orca/briefs/fix-the-login-bug.md and carry out the task it describes."
ok  "claude: create-tab sets the worker cwd" calls_have $'--working-directory\t'"$WORK"
ok  "claude: launch sends only the agent command" \
      calls_have_line $'send\t--surface\t'"$SURFACE"$'\tclaude'
ok  "claude: brief file written"           test -f "$WORK/.orca/briefs/fix-the-login-bug.md"
ok  "claude: brief file has the brief text" \
      eq "$(cat "$WORK/.orca/briefs/fix-the-login-bug.md")" "Make login work."
ok  "claude: .orca/ is gitignored"         grep -qxF ".orca/" "$WORK/.gitignore"
no  "claude: never closes a surface"       called_subcommand close-surface
ok  "claude: renames the tab"              called_subcommand rename-tab

# === Codex happy path ======================================================
WORK2="$TMP/repo-codex"; mkdir -p "$WORK2"
DEFAULT_CWD="$WORK2"; SCENARIO=codex
spawn --agent codex --task "Add unit tests" --brief "Cover the parser."

ok  "codex: exits 0"                    rc_is 0
ok  "codex: returns the surface UUID"   eq "$(field surface)" "$SURFACE"
ok  "codex: no mode step (0 shift+tab)" eq "$(count_shift_tabs)" 0
ok  "codex: delivers pointer brief" \
      calls_have "Read .orca/briefs/add-unit-tests.md and carry out the task it describes."
ok  "codex: launch sends only codex -p yolo" \
      calls_have_line $'send\t--surface\t'"$SURFACE"$'\tcodex -p yolo'
ok  "codex: brief file written"         test -f "$WORK2/.orca/briefs/add-unit-tests.md"

# === gitignore is not duplicated when already present ======================
WORK3="$TMP/repo-gi"; mkdir -p "$WORK3"
printf '.orca/\nnode_modules/\n' > "$WORK3/.gitignore"
DEFAULT_CWD="$WORK3"; SCENARIO=codex
spawn --agent codex --task "Thing" --brief "x"
ok  "gitignore: .orca/ not duplicated"      eq "$(grep -cxF ".orca/" "$WORK3/.gitignore")" 1
ok  "gitignore: existing entries preserved" grep -qxF "node_modules/" "$WORK3/.gitignore"

# === gitignore append preserves final rule without trailing newline =========
WORK8="$TMP/repo-gi-nonewline"; mkdir -p "$WORK8"
printf 'node_modules' > "$WORK8/.gitignore"
DEFAULT_CWD="$WORK8"; SCENARIO=codex
spawn --agent codex --task "No newline" --brief "x"
ok  "gitignore newline: existing rule preserved" grep -qxF "node_modules" "$WORK8/.gitignore"
ok  "gitignore newline: .orca/ added separately" grep -qxF ".orca/" "$WORK8/.gitignore"

# === task id collision handling ============================================
DEFAULT_CWD="$WORK"; SCENARIO=claude
spawn --agent claude --task "Fix the login bug" --brief "second one"
ok  "collision: second task id gets -2 suffix" eq "$(field task_id)" "fix-the-login-bug-2"
ok  "collision: second brief file exists"      test -f "$WORK/.orca/briefs/fix-the-login-bug-2.md"
ok  "collision: original brief untouched" \
      eq "$(cat "$WORK/.orca/briefs/fix-the-login-bug.md")" "Make login work."

# === default cwd resolves to the caller workspace directory ================
WORK4="$TMP/repo-default"; mkdir -p "$WORK4"
DEFAULT_CWD="$WORK4"; SCENARIO=codex
spawn --agent codex --task "Default cwd" --brief "y"   # no --cwd
ok  "default cwd: brief written under caller workspace dir" \
      test -f "$WORK4/.orca/briefs/default-cwd.md"

# === Codex readiness requires more than a bare chevron ======================
WORK7="$TMP/repo-codex-chevron"; mkdir -p "$WORK7"
DEFAULT_CWD="$WORK7"; SCENARIO=codex-chevron-only; POLLS=3
spawn --agent codex --task "Chevron only" --brief "z"
POLLS=30
ok  "codex chevron-only: exits non-zero"       rc_not 0
ok  "codex chevron-only: status=error"         eq "$(field status)" error
ok  "codex chevron-only: error mentions ready" mentions readiness

# === forced readiness failure leaves the tab open =========================
WORK5="$TMP/repo-fail"; mkdir -p "$WORK5"
DEFAULT_CWD="$WORK5"; SCENARIO=never-ready; POLLS=3
spawn --agent claude --task "Never ready" --brief "z"
POLLS=30
ok  "readiness fail: exits non-zero"          rc_not 0
ok  "readiness fail: status=error"            eq "$(field status)" error
ok  "readiness fail: reports surface UUID"    eq "$(field surface)" "$SURFACE"
ok  "readiness fail: error mentions readiness" mentions readiness
ok  "readiness fail: stderr names the surface UUID" mentions_err "$SURFACE"
no  "readiness fail: tab left open (no close)" called_subcommand close-surface

# === read-screen errors are reported directly ==============================
WORK9="$TMP/repo-read-error"; mkdir -p "$WORK9"
DEFAULT_CWD="$WORK9"; SCENARIO=read-screen-error
spawn --agent claude --task "Read error" --brief "z"
ok  "read-screen error: exits non-zero"       rc_not 0
ok  "read-screen error: status=error"         eq "$(field status)" error
ok  "read-screen error: reports read failure" mentions "failed to read worker screen"

# === forced mode failure leaves the tab open ==============================
WORK6="$TMP/repo-stuck"; mkdir -p "$WORK6"
DEFAULT_CWD="$WORK6"; SCENARIO=claude-stuck
spawn --agent claude --task "Stuck mode" --brief "z"
ok  "mode fail: exits non-zero"              rc_not 0
ok  "mode fail: reports surface UUID"        eq "$(field surface)" "$SURFACE"
ok  "mode fail: stops after 5 attempts"      eq "$(count_shift_tabs)" 5
ok  "mode fail: error mentions auto mode on" mentions "auto mode on"
no  "mode fail: tab left open (no close)"    called_subcommand close-surface

# === unknown agent type fails before creating a tab ========================
DEFAULT_CWD="$WORK"; SCENARIO=claude
spawn --agent bogus --task "X" --brief "y"
ok  "unknown agent: exits non-zero"        rc_not 0
ok  "unknown agent: status=error"          eq "$(field status)" error
no  "unknown agent: no tab created"        called_subcommand new-surface
ok  "unknown agent: error names the agent" mentions bogus

# === missing option values fail instead of hanging =========================
DEFAULT_CWD="$WORK"; SCENARIO=claude
ok  "missing option value: command finishes" spawn_must_finish 1 --agent
ok  "missing option value: exits non-zero"   rc_not 0
ok  "missing option value: status=error"     eq "$(field status)" error

# === brief inputs are mutually exclusive ===================================
BRIEF_FILE="$TMP/brief-file.md"
printf 'from file\n' > "$BRIEF_FILE"
DEFAULT_CWD="$WORK"; SCENARIO=claude
spawn --agent claude --task "Two briefs" --brief "inline" --brief-file "$BRIEF_FILE"
ok  "two briefs: exits non-zero"   rc_not 0
ok  "two briefs: status=error"     eq "$(field status)" error
no  "two briefs: no tab created"   called_subcommand new-surface
ok  "two briefs: explains choice"  mentions "exactly one"

# === cmux unreachable fails before creating a tab ==========================
DEFAULT_CWD="$WORK"; SCENARIO=cmux-down
spawn --agent claude --task "X" --brief "y"
ok  "cmux down: exits non-zero" rc_not 0
no  "cmux down: no tab created" called_subcommand new-surface

# --- summary ---------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
