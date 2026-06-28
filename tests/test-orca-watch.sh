#!/usr/bin/env bash
# Integration tests for skills/orca-watch/scripts/orca-watch.sh.
#
# orca-watch resolves a surface to a cmux hook session, then subscribes to cmux
# lifecycle events. This test injects cmux through CMUX_BIN and keeps "cmux" off
# PATH so the event subscriber must honor the injected binary to see hook frames.
#
# No external test deps beyond jq and python3 (which orca-watch itself needs).
# Run: tests/test-orca-watch.sh
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
WATCH="$REPO_ROOT/skills/orca-watch/scripts/orca-watch.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

CALLS="$TMP/calls.log"
FAKE_DIR="$TMP/not-on-path"
FAKE="$FAKE_DIR/fake-cmux"
HOME_DIR="$TMP/home"
PATH_DIR="$TMP/path"

SURFACE="BE7E2B29-66BA-44B4-BE66-73B85C85C7F3"
SURFACE_LOWER="be7e2b29-66ba-44b4-be66-73b85c85c7f3"
CLAUDE_SESSION="session-123"
CODEX_SESSION="codex-session-777"

mkdir -p "$FAKE_DIR" "$HOME_DIR/.cmuxterm" "$PATH_DIR"

PYTHON3=$(python3 -c 'import sys; print(sys.executable)')
DATE_BIN=$(command -v date)
BASH_BIN=$(command -v bash)
SLEEP_BIN=$(command -v sleep)
ln -s "$PYTHON3" "$PATH_DIR/python3"
ln -s "$BASH_BIN" "$PATH_DIR/bash"
ln -s "$SLEEP_BIN" "$PATH_DIR/sleep"
cat > "$PATH_DIR/date" <<EOF
#!/bin/bash
if [[ "\${1:-}" == "+%s" && -n "\${FAKE_DATE_STATE:-}" ]]; then
  if [[ -r "\$FAKE_DATE_STATE" ]]; then
    IFS= read -r current < "\$FAKE_DATE_STATE"
  else
    current=\${FAKE_DATE_START:-1000}
  fi
  printf '%s\n' "\$current"
  step=\${FAKE_DATE_STEP:-1}
  printf '%s\n' "\$((current + step))" > "\$FAKE_DATE_STATE"
else
  exec "$DATE_BIN" "\$@"
fi
EOF
chmod +x "$PATH_DIR/date"

cat > "$FAKE" <<'EOF'
#!/bin/bash
sub=${1:-}; shift || true
{
  printf '%s' "$sub"
  for a in "$@"; do printf '\t%s' "$a"; done
  printf '\n'
} >> "$FAKE_CALLS"

case "$sub" in
  events)
    case "${FAKE_MODE:-stop}" in
      stop)
        printf '{"type":"ack","resume":{"latest_seq":40}}\n'
        printf '{"type":"event","name":"agent.hook.Stop","payload":{"session_id":"claude-other"},"seq":41}\n'
        printf '{"type":"event","name":"agent.hook.Stop","payload":{"session_id":"%s","cwd":"/tmp/project","workspace_id":"workspace-123"},"seq":42}\n' "$FAKE_TARGET"
        ;;
      notification)
        printf '{"type":"event","name":"agent.hook.Notification","payload":{"session_id":"%s","cwd":"/tmp/project","workspace_id":"workspace-123"},"seq":50}\n' "$FAKE_TARGET"
        ;;
      permission)
        printf '{"type":"event","name":"agent.hook.PermissionRequest","payload":{"session_id":"%s","cwd":"/tmp/project","workspace_id":"workspace-123"},"seq":51}\n' "$FAKE_TARGET"
        ;;
      question)
        printf '{"type":"event","name":"agent.hook.AskUserQuestion","payload":{"session_id":"%s","cwd":"/tmp/project","workspace_id":"workspace-123"},"seq":52}\n' "$FAKE_TARGET"
        ;;
      timeout)
        printf '{"type":"event","name":"agent.hook.Stop","payload":{"session_id":"claude-other"},"seq":60}\n'
        exec python3 - <<'PY'
import time
time.sleep(5)
PY
        ;;
      timeout_after_resolve)
        python3 - <<'PY'
import time
time.sleep(20)
PY
        ;;
      stream_closed)
        printf '{"type":"ack","resume":{"latest_seq":70}}\n'
        printf '{"type":"event","name":"agent.hook.Stop","payload":{"session_id":"claude-other"},"seq":71}\n'
        ;;
      noisy)
        printf '{"type":"ack","resume":{"latest_seq":80}}\n'
        printf '\n'
        printf 'not-json\n'
        printf '{"type":"heartbeat","seq":81}\n'
        printf '{"type":"event","name":"system.notice","payload":{"session_id":"%s"},"seq":82}\n' "$FAKE_TARGET"
        printf '{"type":"event","name":"agent.hook.Stop","payload":{"session_id":"claude-other"},"seq":83}\n'
        printf '{"type":"event","name":"agent.hook.Stop","payload":{"session_id":"%s","cwd":"/tmp/noisy","workspace_id":"workspace-noisy"},"seq":84}\n' "$FAKE_TARGET"
        ;;
      *)
        echo "unexpected FAKE_MODE: $FAKE_MODE" >&2
        exit 8
        ;;
    esac
    ;;
  *)
    echo "unexpected fake cmux subcommand: $sub" >&2
    exit 7
    ;;
esac
EOF
chmod +x "$FAKE"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1" >&2
  shift || true
  while (($#)); do printf '      %s\n' "$1" >&2; shift; done
}

assert_eq() {
  local desc="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    pass
  else
    fail "$desc" "want: [$want]" "got:  [$got]"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    pass
  else
    fail "$desc" "missing: [$needle]" "in:      [$haystack]"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    fail "$desc" "unexpected: [$needle]" "in:          [$haystack]"
  else
    pass
  fi
}

assert_jq() {
  local desc="$1" expr="$2" json="$3"
  if jq -e "$expr" >/dev/null <<<"$json"; then
    pass
  else
    fail "$desc" "json: $json"
  fi
}

reset_store() {
  rm -rf "$HOME_DIR/.cmuxterm"
  mkdir -p "$HOME_DIR/.cmuxterm"
}

write_claude_store() {
  local surface="$1" session="$2"
  reset_store
  cat > "$HOME_DIR/.cmuxterm/claude-hook-sessions.json" <<EOF
{
  "activeSessionsBySurface": {
    "$surface": {
      "sessionId": "$session"
    }
  }
}
EOF
}

write_codex_store() {
  local surface="$1" session="$2"
  reset_store
  cat > "$HOME_DIR/.cmuxterm/codex-hook-sessions.json" <<EOF
{
  "sessions": {
    "$session": {
      "surfaceId": "$surface",
      "sessionId": "$session"
    }
  }
}
EOF
}

write_empty_store() {
  local agent="$1"
  reset_store
  printf '{"sessions": {}, "activeSessionsBySurface": {}}\n' > "$HOME_DIR/.cmuxterm/${agent}-hook-sessions.json"
}

OUT=""
ERR=""
RC=0
MODE="stop"
TARGET=""
RESOLVE_SECS=""
DATE_STATE=""
DATE_STEP=""
run_watch() {
  local agent="$1" surface="$2" timeout="$3" after="${4:-}"
  local errfile="$TMP/stderr"
  local args=(--surface "$surface" --agent "$agent" --timeout "$timeout")
  if [[ -n "$after" ]]; then
    args+=(--after "$after")
  fi

  : > "$CALLS"
  OUT=$(HOME="$HOME_DIR" PATH="$PATH_DIR" CMUX_BIN="$FAKE" \
    FAKE_CALLS="$CALLS" FAKE_TARGET="$TARGET" FAKE_MODE="$MODE" \
    ORCA_WATCH_RESOLVE_SECS="$RESOLVE_SECS" \
    FAKE_DATE_STATE="$DATE_STATE" FAKE_DATE_STEP="$DATE_STEP" \
    "$WATCH" "${args[@]}" 2>"$errfile")
  RC=$?
  ERR=$(cat "$errfile")
}

write_claude_store "$SURFACE" "$CLAUDE_SESSION"
TARGET="claude-$CLAUDE_SESSION"
MODE="stop"
RESOLVE_SECS=""
run_watch claude "$SURFACE" 5 40

assert_eq "watch exits successfully after matching Claude Stop event" "0" "$RC"
assert_jq "Claude Stop reports turn_end for the resolved session" \
  '.event == "turn_end" and .hook == "Stop" and .agent == "claude" and .surface == "'"$SURFACE"'" and .session_id == "'"$TARGET"'" and .cwd == "/tmp/project" and .workspace_id == "workspace-123" and .seq == 42' \
  "$OUT"
assert_jq "unrelated session frame before the match is skipped" \
  '.session_id == "'"$TARGET"'" and .seq == 42' \
  "$OUT"
assert_eq "event stream is opened through the CMUX_BIN fake with --after" \
  "$(printf '%s\n' "events	--no-heartbeat	--name	agent.hook.Stop	--name	agent.hook.Notification	--name	agent.hook.PermissionRequest	--name	agent.hook.AskUserQuestion	--after	40")" \
  "$(cat "$CALLS")"

write_codex_store "$SURFACE" "$CODEX_SESSION"
TARGET="codex-$CODEX_SESSION"
MODE="stop"
run_watch codex "$SURFACE_LOWER" 5

assert_eq "watch exits successfully after matching Codex Stop event" "0" "$RC"
assert_jq "Codex store resolves by case-insensitive surface reverse scan" \
  '.event == "turn_end" and .hook == "Stop" and .agent == "codex" and .surface == "'"$SURFACE_LOWER"'" and .session_id == "'"$TARGET"'" and .seq == 42' \
  "$OUT"
assert_not_contains "--after is omitted from cmux argv when not requested" "--after" "$(cat "$CALLS")"

write_claude_store "$SURFACE" "$CLAUDE_SESSION"
TARGET="claude-$CLAUDE_SESSION"
for spec in \
  "notification Notification 50" \
  "permission PermissionRequest 51" \
  "question AskUserQuestion 52"
do
  set -- $spec
  MODE="$1"
  hook="$2"
  seq="$3"
  run_watch claude "$SURFACE" 5
  assert_eq "watch exits successfully for $hook attention" "0" "$RC"
  assert_jq "$hook reports attention for the resolved session" \
    '.event == "attention" and .hook == "'"$hook"'" and .agent == "claude" and .surface == "'"$SURFACE"'" and .session_id == "'"$TARGET"'" and .seq == '"$seq" \
    "$OUT"
done

MODE="timeout"
run_watch claude "$SURFACE" 1
assert_eq "timeout exits with code 3 when no relevant frame arrives" "3" "$RC"
assert_jq "timeout reports timeout JSON" \
  '.event == "timeout" and .agent == "claude" and .surface == "'"$SURFACE"'"' \
  "$OUT"

MODE="stream_closed"
run_watch claude "$SURFACE" 5
assert_eq "stream closed exits with code 4 before a match" "4" "$RC"
assert_jq "stream closed reports stream_closed JSON" \
  '.event == "stream_closed" and .agent == "claude" and .surface == "'"$SURFACE"'"' \
  "$OUT"

MODE="noisy"
run_watch claude "$SURFACE" 5
assert_eq "noisy stream still exits successfully after matching Stop" "0" "$RC"
assert_jq "non-event, malformed, blank, and unrelated frames are ignored" \
  '.event == "turn_end" and .hook == "Stop" and .agent == "claude" and .surface == "'"$SURFACE"'" and .session_id == "'"$TARGET"'" and .cwd == "/tmp/noisy" and .workspace_id == "workspace-noisy" and .seq == 84' \
  "$OUT"

reset_store
MODE="stop"
run_watch claude "$SURFACE" 5
assert_eq "missing store exits with code 2" "2" "$RC"
assert_contains "missing store reports a clear resolve error" "no session store for claude" "$ERR"

reset_store
printf '{not-json\n' > "$HOME_DIR/.cmuxterm/claude-hook-sessions.json"
RESOLVE_SECS="0"
run_watch claude "$SURFACE" 5
assert_eq "malformed store exits with code 2" "2" "$RC"
assert_contains "malformed store reports unresolved surface" "could not resolve a session for surface $SURFACE" "$ERR"

write_empty_store codex
TARGET="codex-$CODEX_SESSION"
MODE="stop"
RESOLVE_SECS="2"
run_watch codex "$SURFACE" 1
assert_eq "Codex unresolved session is bounded by the overall timeout" "3" "$RC"
assert_jq "Codex unresolved session reports timeout JSON" \
  '.event == "timeout" and .agent == "codex" and .surface == "'"$SURFACE"'"' \
  "$OUT"
assert_eq "Codex unresolved timeout does not subscribe before resolving a session" "" "$(cat "$CALLS")"

write_empty_store codex
TARGET="codex-$CODEX_SESSION"
MODE="stop"
RESOLVE_SECS=""
run_watch codex "$SURFACE" 1 90
assert_eq "Codex default unresolved session is bounded by the overall timeout" "3" "$RC"
assert_jq "Codex default unresolved session reports timeout JSON" \
  '.event == "timeout" and .agent == "codex" and .surface == "'"$SURFACE"'"' \
  "$OUT"

write_empty_store codex
TARGET="codex-$CODEX_SESSION"
MODE="timeout_after_resolve"
RESOLVE_SECS=""
DATE_STATE="$TMP/date-state"
DATE_STEP="31"
printf '1000\n' > "$DATE_STATE"
(
  sleep 0.1
  write_codex_store "$SURFACE" "$CODEX_SESSION"
) &
writer_pid=$!
run_watch codex "$SURFACE" 40 90
wait "$writer_pid"
assert_eq "Codex default timeout subtracts elapsed resolve time before subscribing" "3" "$RC"
assert_jq "Codex late resolve reports timeout when no event arrives in the remaining window" \
  '.event == "timeout" and .agent == "codex" and .surface == "'"$SURFACE"'"' \
  "$OUT"
DATE_STATE=""
DATE_STEP=""

write_empty_store codex
TARGET="codex-$CODEX_SESSION"
MODE="stop"
RESOLVE_SECS=""
DATE_STATE="$TMP/date-state"
DATE_STEP="31"
printf '1000\n' > "$DATE_STATE"
(
  sleep 0.1
  write_codex_store "$SURFACE" "$CODEX_SESSION"
) &
writer_pid=$!
run_watch codex "$SURFACE" 100 90
wait "$writer_pid"
assert_eq "Codex default resolve follows a session registered after the old 30s window" "0" "$RC"
assert_jq "Codex delayed registration reports the replayed Stop event" \
  '.event == "turn_end" and .agent == "codex" and .surface == "'"$SURFACE"'" and .session_id == "'"$TARGET"'" and .seq == 42' \
  "$OUT"
DATE_STATE=""
DATE_STEP=""

if ((FAIL > 0)); then
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL" >&2
  [[ -n "$ERR" ]] && printf '\nstderr:\n%s\n' "$ERR" >&2
  [[ -n "$OUT" ]] && printf '\nstdout:\n%s\n' "$OUT" >&2
  exit 1
fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
