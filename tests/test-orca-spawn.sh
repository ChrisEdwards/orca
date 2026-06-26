#!/usr/bin/env bash
# Integration tests for skills/orca-spawn/scripts/orca-spawn.sh.
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
SPAWN="$REPO_ROOT/skills/orca-spawn/scripts/orca-spawn.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

CALLS="$TMP/calls.log"
STATE="$TMP/state"
FAKE="$TMP/cmux"

SURFACE="BE7E2B29-66BA-44B4-BE66-73B85C85C7F3"
ORIGIN_SURFACE="8AA280A2-FEB8-4733-B750-2681FA2C2985"
WS="90D8E74A-E0EE-4FCB-8F7C-105574F46F01"
WIN="7D14BE4C-2C6A-4E4C-90B1-3B6B12C69D02"
TARGET_WS="6EB41F10-C6EE-4D9E-8F0A-659D9D37E042"
TARGET_WS_2="2E54B129-AEE4-4ED3-AB42-7D7D122D9F4E"
CREATED_WS="CE5E0B0C-71D1-409F-8874-5E99856DB588"

# --- stateful fake cmux ----------------------------------------------------
# Logs every invocation to $FAKE_CALLS and simulates a terminal screen via
# $FAKE_SCENARIO plus on-disk state (launched marker, shift+tab counter).
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
sub=${1:-}; shift || true
{ printf '%s' "$sub"; for a in "$@"; do printf '\t%s' "$a"; done; printf '\n'; } >> "$FAKE_CALLS"

keyfile="$FAKE_STATE/keycount"
launched="$FAKE_STATE/launched"
trust_selected="$FAKE_STATE/trust-selected"
trusted="$FAKE_STATE/trusted"
upgrade_selected="$FAKE_STATE/upgrade-selected"
upgrade_dismissed="$FAKE_STATE/upgrade-dismissed"
kc=0; [[ -f "$keyfile" ]] && kc=$(cat "$keyfile")

case "$sub" in
  identify)
    [[ "${FAKE_SCENARIO:-}" == cmux-down ]] && { echo "cmux: daemon not running" >&2; exit 1; }
    printf '{ "caller": { "window_id": "%s", "workspace_id": "%s", "surface_id": "%s" } }\n' "$FAKE_WINDOW" "$FAKE_WS" "$FAKE_ORIGIN_SURFACE"
    ;;
  list-workspaces|workspace)
    # Non-JSON table form is used only to resolve a freshly-created workspace ref
    # (cmux no longer prints the UUID on create). Include every fake workspace so
    # the resolver can find whichever ref it just created.
    if [[ "$*" != *"--json"* ]]; then
      printf '  workspace:9 %s  caller\n' "$FAKE_WS"
      printf '  workspace:10 %s  aiml-services\n' "$FAKE_TARGET_WS"
      printf '* workspace:12 %s  new-repo  [selected]\n' "$FAKE_CREATED_WS"
      exit 0
    fi
    case "${FAKE_WORKSPACE_MODE:-default}" in
      existing-name)
        printf '{ "workspaces": ['
        printf '{ "id": "%s", "ref": "workspace:9", "title": "caller", "custom_title": "caller", "current_directory": "%s" },' "$FAKE_WS" "$FAKE_CWD"
        printf '{ "id": "%s", "ref": "workspace:10", "title": "aiml-services", "custom_title": "aiml-services", "current_directory": "%s" }' "$FAKE_TARGET_WS" "$FAKE_TARGET_CWD"
        printf '] }\n'
        ;;
      title-name)
        printf '{ "workspaces": ['
        printf '{ "id": "%s", "ref": "workspace:9", "title": "caller", "custom_title": "caller", "current_directory": "%s" },' "$FAKE_WS" "$FAKE_CWD"
        printf '{ "id": "%s", "ref": "workspace:10", "title": "repo-title", "custom_title": null, "current_directory": "%s" }' "$FAKE_TARGET_WS" "$FAKE_TARGET_CWD"
        printf '] }\n'
        ;;
      duplicate-name)
        printf '{ "workspaces": ['
        printf '{ "id": "%s", "ref": "workspace:10", "title": "aiml-services", "custom_title": "aiml-services", "current_directory": "%s" },' "$FAKE_TARGET_WS" "$FAKE_TARGET_CWD"
        printf '{ "id": "%s", "ref": "workspace:11", "title": "aiml-services", "custom_title": "other", "current_directory": "%s" }' "$FAKE_TARGET_WS_2" "$FAKE_TARGET_CWD"
        printf '] }\n'
        ;;
      missing-name|unknown-id)
        printf '{ "workspaces": [ { "id": "%s", "ref": "workspace:9", "title": "caller", "custom_title": "caller", "current_directory": "%s" } ] }\n' "$FAKE_WS" "$FAKE_CWD"
        ;;
      *)
        printf '{ "workspaces": [ { "id": "%s", "ref": "workspace:9", "current_directory": "%s" } ] }\n' "$FAKE_WS" "$FAKE_CWD"
        ;;
    esac
    ;;
  new-workspace)
    # cmux >= 0.64 echoes only the new workspace's positional ref; the UUID is
    # recovered from the non-JSON workspace list above.
    echo "OK workspace:12"
    ;;
  new-surface)
    echo "OK surface:43 ($FAKE_SURFACE) pane:16 (PANE-UUID) workspace:9 ($FAKE_WS)"
    ;;
  rename-tab) echo "OK" ;;
  events)
    case "${FAKE_EVENT_MODE:-ack}" in
      fail)
        echo "events unavailable" >&2
        exit 7
        ;;
      garbage)
        echo "not-json"
        ;;
      *)
        printf '{"type":"ack","resume":{"latest_seq":%s}}\n' "${FAKE_EVENT_SEQ:-123}"
        ;;
    esac
    ;;
  send)
    payload=""; for a in "$@"; do payload=$a; done
    [[ "$payload" == "1" ]] && : > "$trust_selected"
    expected_upgrade=2
    [[ "${FAKE_SCENARIO:-}" == codex-upgrade-skip-3 ]] && expected_upgrade=3
    [[ "$payload" == "$expected_upgrade" ]] && : > "$upgrade_selected"
    : > "$launched"
    echo "OK surface:43 workspace:9"
    ;;
  send-key)
    key=""; for a in "$@"; do key=$a; done
    [[ "$key" == "shift+tab" ]] && printf '%s' "$((kc + 1))" > "$keyfile"
    [[ "$key" == "enter" && -f "$trust_selected" ]] && : > "$trusted"
    [[ "$key" == "enter" && -f "$upgrade_selected" ]] && : > "$upgrade_dismissed"
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
      claude-trust)
        [[ -f "$launched" ]] || { echo "starting Claude Code..."; exit 0; }
        if [[ ! -f "$trusted" ]]; then
          printf '  Is this a project you trust?\n'
          printf '  1. Yes\n'
          printf '  2. No\n'
          exit 0
        fi
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
      codex-trust)
        [[ -f "$launched" ]] || { echo "booting codex"; exit 0; }
        if [[ ! -f "$trusted" ]]; then
          printf '  Do you trust the contents of this directory?\n'
          printf '› 1. Yes, continue\n'
          printf '  2. No, quit\n'
          exit 0
        fi
        printf '› Implement {feature}\n'
        printf 'gpt-5.5 high · %s\n' "$FAKE_CWD"
        ;;
      codex-upgrade)
        [[ -f "$launched" ]] || { echo "booting codex"; exit 0; }
        if [[ ! -f "$upgrade_dismissed" ]]; then
          printf '  ✨ Update available! 0.142.0 -> 0.142.2\n'
          printf '› 1. Update now\n'
          printf '  2. Skip\n'
          printf '  3. Skip until next version\n'
          exit 0
        fi
        printf '› Implement {feature}\n'
        printf 'gpt-5.5 high · %s\n' "$FAKE_CWD"
        ;;
      codex-upgrade-skip-3)
        [[ -f "$launched" ]] || { echo "booting codex"; exit 0; }
        if [[ ! -f "$upgrade_dismissed" ]]; then
          printf '  ✨ Update available! 0.142.0 -> 0.142.2\n'
          printf '  1. Update now\n'
          printf '  2. Skip until next version\n'
          printf '  3. Skip\n'
          exit 0
        fi
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
WORKSPACE_MODE="default"
POLLS=30
DEFAULT_CWD=""     # the caller workspace dir the fake reports
TARGET_CWD=""
EVENT_MODE="ack"
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
    FAKE_WINDOW="$WIN" FAKE_TARGET_WS="$TARGET_WS" FAKE_TARGET_WS_2="$TARGET_WS_2" \
    FAKE_CREATED_WS="$CREATED_WS" FAKE_TARGET_CWD="$TARGET_CWD" \
    FAKE_ORIGIN_SURFACE="$ORIGIN_SURFACE" \
    FAKE_SCENARIO="$SCENARIO" FAKE_WORKSPACE_MODE="$WORKSPACE_MODE" \
    FAKE_EVENT_MODE="$EVENT_MODE" \
    ORCA_READY_POLLS="$POLLS" ORCA_POLL_INTERVAL=0 ORCA_MODE_INTERVAL=0 \
    "$SPAWN" "$@" 2>"$errfile")
  LAST_RC=$?
  LAST_ERR=$(cat "$errfile")
}

field() { grep -E "^$1=" <<<"$LAST_OUT" | head -1 | cut -d= -f2-; }
field_absent() { ! grep -qE "^$1=" <<<"$LAST_OUT"; }
count_shift_tabs() { grep -c $'\tshift+tab$' "$CALLS"; }
count_enter_keys() { grep -c $'\tenter$' "$CALLS"; }
calls_have() { grep -qF -- "$1" "$CALLS"; }
calls_have_line() { grep -qxF -- "$1" "$CALLS"; }
called_subcommand() { grep -qE "^$1(\t|$)" "$CALLS"; }
first_call_line() {
  local pattern=$1 line
  line=$(grep -nF -- "$pattern" "$CALLS" | head -1 | cut -d: -f1)
  [[ -n "$line" ]] || return 1
  printf '%s' "$line"
}
last_call_line() {
  local pattern=$1 line
  line=$(grep -nF -- "$pattern" "$CALLS" | tail -1 | cut -d: -f1)
  [[ -n "$line" ]] || return 1
  printf '%s' "$line"
}
call_between() {
  local before=$1 middle=$2 after=$3 before_line middle_line after_line
  before_line=$(last_call_line "$before") || return 1
  middle_line=$(first_call_line "$middle") || return 1
  after_line=$(first_call_line "$after") || return 1
  [[ "$before_line" -lt "$middle_line" && "$middle_line" -lt "$after_line" ]]
}
mentions() { grep -qiF -- "$1" <<<"$LAST_OUT"$'\n'"$LAST_ERR"; }
mentions_err() { grep -qF "$1" <<<"$LAST_ERR"; }
rc_is() { [[ "$LAST_RC" -eq "$1" ]]; }
rc_not() { [[ "$LAST_RC" -ne "$1" ]]; }
eq() { [[ "$1" == "$2" ]]; }

with_parent_footer() {
  printf '%s\n[From the parent agent at surface %s. To reply to the parent, use the orca-msg skill targeting that surface if needed.]' "$1" "$ORIGIN_SURFACE"
}

spawn_must_finish() {
  local timeout=$1; shift
  local out="$TMP/timeout.out" err="$TMP/timeout.err" done="$TMP/timeout.done"
  rm -f "$out" "$err" "$done"
    CMUX_BIN="$FAKE" FAKE_CALLS="$CALLS" FAKE_STATE="$STATE" \
    FAKE_SURFACE="$SURFACE" FAKE_WS="$WS" FAKE_CWD="$DEFAULT_CWD" \
    FAKE_WINDOW="$WIN" FAKE_TARGET_WS="$TARGET_WS" FAKE_TARGET_WS_2="$TARGET_WS_2" \
    FAKE_CREATED_WS="$CREATED_WS" FAKE_TARGET_CWD="$TARGET_CWD" \
    FAKE_ORIGIN_SURFACE="$ORIGIN_SURFACE" \
    FAKE_SCENARIO="$SCENARIO" FAKE_WORKSPACE_MODE="$WORKSPACE_MODE" \
    FAKE_EVENT_MODE="$EVENT_MODE" \
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
ok  "claude: reports caller workspace"     eq "$(field workspace)" "$WS"
ok  "claude: reports workspace not created" eq "$(field workspace_created)" false
ok  "claude: task id is a kebab slug"      eq "$(field task_id)" "fix-the-login-bug"
ok  "claude: tab named from task id"       eq "$(field tab)" "fix-the-login-bug"
ok  "claude: reports after_seq from events ack" eq "$(field after_seq)" 123
ok  "claude: cycles shift+tab to auto (3)" eq "$(count_shift_tabs)" 3
ok  "claude: delivers pointer brief" \
      calls_have "$(with_parent_footer "Read .orca/briefs/fix-the-login-bug.md and carry out the task it describes.")"
ok  "claude: captures event anchor after readiness and before brief delivery" \
      call_between "read-screen" $'events\t--no-heartbeat' $'send\t--surface\t'"$SURFACE"$'\tRead .orca/briefs/fix-the-login-bug.md and carry out the task it describes.'
ok  "claude: create-tab sets the worker cwd" calls_have $'--working-directory\t'"$WORK"
ok  "claude: launch sends only the agent command" \
      calls_have_line $'send\t--surface\t'"$SURFACE"$'\tclaude'
ok  "claude: brief file written"           test -f "$WORK/.orca/briefs/fix-the-login-bug.md"
ok  "claude: brief file has the brief text" \
      eq "$(cat "$WORK/.orca/briefs/fix-the-login-bug.md")" "Make login work."
ok  "claude: .orca/ is gitignored"         grep -qxF ".orca/" "$WORK/.gitignore"
no  "claude: never closes a surface"       called_subcommand close-surface
ok  "claude: renames the tab"              called_subcommand rename-tab

# === Claude trust prompt is answered before readiness =====================
WORK_TRUST="$TMP/repo-claude-trust"; mkdir -p "$WORK_TRUST"
DEFAULT_CWD="$WORK_TRUST"; SCENARIO=claude-trust
spawn --agent claude --task "Trust this repo" --brief "Proceed after trust."

ok  "claude trust: exits 0"                rc_is 0
ok  "claude trust: status=ok"              eq "$(field status)" ok
ok  "claude trust: answered yes"           calls_have_line $'send\t--surface\t'"$SURFACE"$'\t1'
ok  "claude trust: submitted answer"       eq "$(count_enter_keys)" 3
ok  "claude trust: reaches auto mode"      eq "$(count_shift_tabs)" 3
ok  "claude trust: delivers pointer brief" \
      calls_have "$(with_parent_footer "Read .orca/briefs/trust-this-repo.md and carry out the task it describes.")"

# === Codex happy path ======================================================
WORK2="$TMP/repo-codex"; mkdir -p "$WORK2"
DEFAULT_CWD="$WORK2"; SCENARIO=codex
spawn --agent codex --task "Add unit tests" --brief "Cover the parser."

ok  "codex: exits 0"                    rc_is 0
ok  "codex: returns the surface UUID"   eq "$(field surface)" "$SURFACE"
ok  "codex: reports after_seq from events ack" eq "$(field after_seq)" 123
ok  "codex: no mode step (0 shift+tab)" eq "$(count_shift_tabs)" 0
ok  "codex: delivers pointer brief" \
      calls_have "$(with_parent_footer "Read .orca/briefs/add-unit-tests.md and carry out the task it describes.")"
ok  "codex: captures event anchor after readiness and before brief delivery" \
      call_between "read-screen" $'events\t--no-heartbeat' $'send\t--surface\t'"$SURFACE"$'\tRead .orca/briefs/add-unit-tests.md and carry out the task it describes.'
ok  "codex: launch sends only codex -p yolo" \
      calls_have_line $'send\t--surface\t'"$SURFACE"$'\tcodex -p yolo'
ok  "codex: brief file written"         test -f "$WORK2/.orca/briefs/add-unit-tests.md"

# === Event anchor fallback is best effort =================================
WORK_EVENT_FALLBACK="$TMP/repo-event-fallback"; mkdir -p "$WORK_EVENT_FALLBACK"
DEFAULT_CWD="$WORK_EVENT_FALLBACK"; SCENARIO=codex; EVENT_MODE=garbage
spawn --agent codex --task "Event fallback" --brief "Proceed without an anchor."
EVENT_MODE=ack

ok  "event fallback: exits 0"                 rc_is 0
ok  "event fallback: status=ok"               eq "$(field status)" ok
ok  "event fallback: attempted event anchor"  calls_have_line $'events\t--no-heartbeat'
ok  "event fallback: omits after_seq"         field_absent after_seq
ok  "event fallback: still delivers pointer brief" \
      calls_have "$(with_parent_footer "Read .orca/briefs/event-fallback.md and carry out the task it describes.")"

# === Codex trust prompt is answered before readiness ======================
WORK_CODEX_TRUST="$TMP/repo-codex-trust"; mkdir -p "$WORK_CODEX_TRUST"
DEFAULT_CWD="$WORK_CODEX_TRUST"; SCENARIO=codex-trust
spawn --agent codex --task "Trust codex repo" --brief "Proceed after trust."

ok  "codex trust: exits 0"                rc_is 0
ok  "codex trust: status=ok"              eq "$(field status)" ok
ok  "codex trust: answered yes"           calls_have_line $'send\t--surface\t'"$SURFACE"$'\t1'
ok  "codex trust: submitted answer"       eq "$(count_enter_keys)" 3
ok  "codex trust: no mode step"           eq "$(count_shift_tabs)" 0
ok  "codex trust: delivers pointer brief" \
      calls_have "$(with_parent_footer "Read .orca/briefs/trust-codex-repo.md and carry out the task it describes.")"

# === Codex upgrade prompt is dismissed before readiness ====================
WORK_CODEX_UPGRADE="$TMP/repo-codex-upgrade"; mkdir -p "$WORK_CODEX_UPGRADE"
DEFAULT_CWD="$WORK_CODEX_UPGRADE"; SCENARIO=codex-upgrade
spawn --agent codex --task "Upgrade test task" --brief "Proceed after upgrade."

ok  "codex upgrade: exits 0"                rc_is 0
ok  "codex upgrade: status=ok"              eq "$(field status)" ok
ok  "codex upgrade: sent skip (2)"          calls_have_line $'send\t--surface\t'"$SURFACE"$'\t2'
ok  "codex upgrade: submitted answer"       eq "$(count_enter_keys)" 3
ok  "codex upgrade: no mode step"           eq "$(count_shift_tabs)" 0
ok  "codex upgrade: delivers pointer brief" \
      calls_have "$(with_parent_footer "Read .orca/briefs/upgrade-test-task.md and carry out the task it describes.")"

# === Codex upgrade prompt sends option 3 when plain Skip is third ==========
WORK_CODEX_UPGRADE_3="$TMP/repo-codex-upgrade-3"; mkdir -p "$WORK_CODEX_UPGRADE_3"
DEFAULT_CWD="$WORK_CODEX_UPGRADE_3"; SCENARIO=codex-upgrade-skip-3
spawn --agent codex --task "Upgrade skip three" --brief "Proceed after upgrade."

ok  "codex upgrade 3: exits 0"                rc_is 0
ok  "codex upgrade 3: status=ok"              eq "$(field status)" ok
ok  "codex upgrade 3: sent skip (3)"          calls_have_line $'send\t--surface\t'"$SURFACE"$'\t3'
no  "codex upgrade 3: did not send skip (2)"  calls_have_line $'send\t--surface\t'"$SURFACE"$'\t2'
ok  "codex upgrade 3: submitted answer"       eq "$(count_enter_keys)" 3
ok  "codex upgrade 3: no mode step"           eq "$(count_shift_tabs)" 0
ok  "codex upgrade 3: delivers pointer brief" \
      calls_have "$(with_parent_footer "Read .orca/briefs/upgrade-skip-three.md and carry out the task it describes.")"

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

# === Existing target workspace by custom title =============================
WORK_TARGET="$TMP/repo-target"; mkdir -p "$WORK_TARGET"
WORK_CALLER="$TMP/repo-caller"; mkdir -p "$WORK_CALLER"
DEFAULT_CWD="$WORK_CALLER"; TARGET_CWD="$WORK_TARGET"; WORKSPACE_MODE=existing-name; SCENARIO=codex
spawn --agent codex --task "Review target" --brief "Review it." --workspace-name "aiml-services"
WORKSPACE_MODE=default

ok  "workspace name: exits 0"                    rc_is 0
ok  "workspace name: reports target workspace"   eq "$(field workspace)" "$TARGET_WS"
ok  "workspace name: reports matched name"       eq "$(field workspace_name)" "aiml-services"
ok  "workspace name: reports not created"        eq "$(field workspace_created)" false
ok  "workspace name: worker created in target"   calls_have_line $'new-surface\t--type\tterminal\t--workspace\t'"$TARGET_WS"$'\t--working-directory\t'"$WORK_TARGET"$'\t--focus\tfalse\t--id-format\tboth'
ok  "workspace name: brief written under target cwd" test -f "$WORK_TARGET/.orca/briefs/review-target.md"
no  "workspace name: no workspace created"       called_subcommand new-workspace

# === Existing target workspace by title fallback ===========================
WORK_TITLE="$TMP/repo-title"; mkdir -p "$WORK_TITLE"
DEFAULT_CWD="$WORK_CALLER"; TARGET_CWD="$WORK_TITLE"; WORKSPACE_MODE=title-name; SCENARIO=codex
spawn --agent codex --task "Title match" --brief "Use title." --workspace-name "repo-title"
WORKSPACE_MODE=default

ok  "workspace title: reports target workspace" eq "$(field workspace)" "$TARGET_WS"
ok  "workspace title: reports matched title"    eq "$(field workspace_name)" "repo-title"
ok  "workspace title: brief written under title cwd" test -f "$WORK_TITLE/.orca/briefs/title-match.md"

# === Existing target workspace honours explicit cwd ========================
WORK_OVERRIDE="$TMP/repo-override"; mkdir -p "$WORK_OVERRIDE"
DEFAULT_CWD="$WORK_CALLER"; TARGET_CWD="$WORK_TARGET"; WORKSPACE_MODE=existing-name; SCENARIO=codex
spawn --agent codex --task "Override cwd" --brief "Override." --workspace-name "aiml-services" --cwd "$WORK_OVERRIDE"
WORKSPACE_MODE=default

ok  "workspace name cwd: reports target workspace" eq "$(field workspace)" "$TARGET_WS"
ok  "workspace name cwd: reports override cwd"     eq "$(field cwd)" "$WORK_OVERRIDE"
ok  "workspace name cwd: worker uses override cwd" calls_have_line $'new-surface\t--type\tterminal\t--workspace\t'"$TARGET_WS"$'\t--working-directory\t'"$WORK_OVERRIDE"$'\t--focus\tfalse\t--id-format\tboth'
ok  "workspace name cwd: brief written under override" test -f "$WORK_OVERRIDE/.orca/briefs/override-cwd.md"

# === Duplicate exact target workspace names fail before mutation ===========
DEFAULT_CWD="$WORK_CALLER"; TARGET_CWD="$WORK_TARGET"; WORKSPACE_MODE=duplicate-name; SCENARIO=codex
spawn --agent codex --task "Ambiguous" --brief "x" --workspace-name "aiml-services"
WORKSPACE_MODE=default

ok  "workspace duplicate: exits non-zero"       rc_not 0
ok  "workspace duplicate: status=error"         eq "$(field status)" error
ok  "workspace duplicate: mentions ambiguous"   mentions "ambiguous"
ok  "workspace duplicate: suggests workspace id" mentions "--workspace-id"
no  "workspace duplicate: no workspace created" called_subcommand new-workspace
no  "workspace duplicate: no worker surface"    called_subcommand new-surface

# === Missing target workspace is created then worker spawned there =========
WORK_CREATED="$TMP/repo-created"; mkdir -p "$WORK_CREATED"
DEFAULT_CWD="$WORK_CREATED"; TARGET_CWD=""; WORKSPACE_MODE=missing-name; SCENARIO=codex
spawn --agent codex --task "Create workspace" --brief "Create it." --workspace-name "new-repo"
WORKSPACE_MODE=default

ok  "workspace create: exits 0"                  rc_is 0
ok  "workspace create: reports created workspace" eq "$(field workspace)" "$CREATED_WS"
ok  "workspace create: reports name"             eq "$(field workspace_name)" "new-repo"
ok  "workspace create: reports created true"     eq "$(field workspace_created)" true
ok  "workspace create: creates no-focus workspace" calls_have_line $'new-workspace\t--name\tnew-repo\t--cwd\t'"$WORK_CREATED"$'\t--window\t'"$WIN"$'\t--focus\tfalse\t--id-format\tboth'
ok  "workspace create: worker uses created workspace" calls_have_line $'new-surface\t--type\tterminal\t--workspace\t'"$CREATED_WS"$'\t--working-directory\t'"$WORK_CREATED"$'\t--focus\tfalse\t--id-format\tboth'

# === Workspace UUID target =================================================
WORK_UUID="$TMP/repo-uuid"; mkdir -p "$WORK_UUID"
DEFAULT_CWD="$WORK_CALLER"; TARGET_CWD="$WORK_UUID"; WORKSPACE_MODE=existing-name; SCENARIO=codex
spawn --agent codex --task "UUID target" --brief "Use UUID." --workspace-id "$TARGET_WS"
WORKSPACE_MODE=default

ok  "workspace id: exits 0"                 rc_is 0
ok  "workspace id: reports target workspace" eq "$(field workspace)" "$TARGET_WS"
ok  "workspace id: reports target name"      eq "$(field workspace_name)" "aiml-services"
ok  "workspace id: reports not created"      eq "$(field workspace_created)" false
ok  "workspace id: worker created in target" calls_have_line $'new-surface\t--type\tterminal\t--workspace\t'"$TARGET_WS"$'\t--working-directory\t'"$WORK_UUID"$'\t--focus\tfalse\t--id-format\tboth'

# === Workspace selector validation happens before mutation =================
DEFAULT_CWD="$WORK_CALLER"; TARGET_CWD="$WORK_UUID"; WORKSPACE_MODE=existing-name; SCENARIO=codex
spawn --agent codex --task "Both selectors" --brief "x" --workspace-name "aiml-services" --workspace-id "$TARGET_WS"
ok  "workspace both selectors: exits non-zero" rc_not 0
ok  "workspace both selectors: explains choice" mentions "at most one"
no  "workspace both selectors: no workspace created" called_subcommand new-workspace
no  "workspace both selectors: no worker surface" called_subcommand new-surface

DEFAULT_CWD="$WORK_CALLER"; TARGET_CWD="$WORK_UUID"; WORKSPACE_MODE=existing-name; SCENARIO=codex
spawn --agent codex --task "Bad workspace id" --brief "x" --workspace-id workspace:3
ok  "workspace id ref: exits non-zero"       rc_not 0
ok  "workspace id ref: rejects positional ref" mentions "not a UUID"
no  "workspace id ref: no workspace created" called_subcommand new-workspace
no  "workspace id ref: no worker surface"    called_subcommand new-surface

UNKNOWN_WS="11111111-2222-4333-8444-555555555555"
DEFAULT_CWD="$WORK_CALLER"; TARGET_CWD="$WORK_UUID"; WORKSPACE_MODE=unknown-id; SCENARIO=codex
spawn --agent codex --task "Unknown workspace" --brief "x" --workspace-id "$UNKNOWN_WS"
WORKSPACE_MODE=default
ok  "workspace id unknown: exits non-zero"    rc_not 0
ok  "workspace id unknown: mentions not found" mentions "not found"
no  "workspace id unknown: no workspace created" called_subcommand new-workspace
no  "workspace id unknown: no worker surface" called_subcommand new-surface

MISSING_CWD="$TMP/missing-cwd"
DEFAULT_CWD="$WORK_CALLER"; TARGET_CWD="$MISSING_CWD"; WORKSPACE_MODE=existing-name; SCENARIO=codex
spawn --agent codex --task "Missing cwd" --brief "x" --workspace-name "aiml-services"
WORKSPACE_MODE=default
ok  "workspace missing cwd: exits non-zero" rc_not 0
ok  "workspace missing cwd: explains cwd" mentions "working directory does not exist"
no  "workspace missing cwd: no workspace created" called_subcommand new-workspace
no  "workspace missing cwd: no worker surface" called_subcommand new-surface

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
