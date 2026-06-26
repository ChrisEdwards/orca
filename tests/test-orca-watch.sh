#!/usr/bin/env bash
# Integration tests for skills/orca-watch/scripts/orca-watch.sh.
#
# orca-watch resolves a surface to a cmux hook session, then subscribes to cmux
# lifecycle events. This test injects cmux through CMUX_BIN and keeps "cmux" off
# PATH so the event subscriber must honor the injected binary to see the Stop
# frame.
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
SESSION="session-123"
TARGET="claude-$SESSION"

mkdir -p "$FAKE_DIR" "$HOME_DIR/.cmuxterm" "$PATH_DIR"

PYTHON3=$(python3 -c 'import sys; print(sys.executable)')
DATE_BIN=$(command -v date)
BASH_BIN=$(command -v bash)
ln -s "$PYTHON3" "$PATH_DIR/python3"
ln -s "$DATE_BIN" "$PATH_DIR/date"
ln -s "$BASH_BIN" "$PATH_DIR/bash"

cat > "$HOME_DIR/.cmuxterm/claude-hook-sessions.json" <<EOF
{
  "activeSessionsBySurface": {
    "$SURFACE": {
      "sessionId": "$SESSION"
    }
  }
}
EOF

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
    printf '{"type":"ack","resume":{"latest_seq":40}}\n'
    printf '{"type":"event","name":"agent.hook.Stop","payload":{"session_id":"claude-other"},"seq":41}\n'
    printf '{"type":"event","name":"agent.hook.Stop","payload":{"session_id":"%s","cwd":"/tmp/project","workspace_id":"workspace-123"},"seq":42}\n' "$FAKE_TARGET"
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

assert_jq() {
  local desc="$1" expr="$2" json="$3"
  if jq -e "$expr" >/dev/null <<<"$json"; then
    pass
  else
    fail "$desc" "json: $json"
  fi
}

OUT=""
ERR=""
RC=0
run_watch() {
  local errfile="$TMP/stderr"
  : > "$CALLS"
  OUT=$(HOME="$HOME_DIR" PATH="$PATH_DIR" CMUX_BIN="$FAKE" \
    FAKE_CALLS="$CALLS" FAKE_TARGET="$TARGET" \
    "$WATCH" --surface "$SURFACE" --agent claude --after 40 --timeout 5 2>"$errfile")
  RC=$?
  ERR=$(cat "$errfile")
}

run_watch

assert_eq "watch exits successfully after matching Stop event" "0" "$RC"
assert_jq "watch reports a turn_end for the resolved session" \
  '.event == "turn_end" and .hook == "Stop" and .agent == "claude" and .surface == "'"$SURFACE"'" and .session_id == "'"$TARGET"'" and .cwd == "/tmp/project" and .workspace_id == "workspace-123" and .seq == 42' \
  "$OUT"
assert_eq "event stream is opened through the CMUX_BIN fake" \
  "$(printf '%s\n' "events	--no-heartbeat	--name	agent.hook.Stop	--name	agent.hook.Notification	--name	agent.hook.PermissionRequest	--name	agent.hook.AskUserQuestion	--after	40")" \
  "$(cat "$CALLS")"

if ((FAIL > 0)); then
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL" >&2
  [[ -n "$ERR" ]] && printf '\nstderr:\n%s\n' "$ERR" >&2
  [[ -n "$OUT" ]] && printf '\nstdout:\n%s\n' "$OUT" >&2
  exit 1
fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
