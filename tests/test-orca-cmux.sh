#!/usr/bin/env bash
# Unit tests for skills/orca-agent/scripts/orca-cmux.sh.
#
# These tests assert COMMAND CONSTRUCTION: orca-cmux must emit the right cmux
# argv for given inputs, without ever talking to a real cmux. We inject a fake
# cmux via CMUX_BIN that records its argv and prints canned output, so every
# assertion checks the exact arguments orca-cmux built.
#
# No external test deps (no bats). Run: tests/test-orca-cmux.sh
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ORCA_CMUX="$REPO_ROOT/skills/orca-agent/scripts/orca-cmux.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

CALL_LOG="$TMP/calls.log"

# --- fake cmux -------------------------------------------------------------
# Records each invocation's argv to $CMUX_CALL_LOG (one "ARG\t<value>" line per
# argument, "CALL" marking each invocation) and prints output shaped like the
# real cmux 0.64.16 so the parser under test has something realistic to chew on.
FAKE="$TMP/cmux"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
{
  printf 'CALL\n'
  for a in "$@"; do printf 'ARG\t%s\n' "$a"; done
} >> "$CMUX_CALL_LOG"
case "$1" in
  new-surface)
    echo "OK surface:43 (${FAKE_SURFACE_UUID:-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}) pane:16 (PPPPPPPP-0000-0000-0000-000000000000) workspace:9 (WWWWWWWW-0000-0000-0000-000000000000)"
    ;;
  read-screen|capture-pane)
    printf 'line one\nline two\n'
    ;;
  list-pane-surfaces)
    echo "* surface:35 5DE180A2-FEB8-4733-A750-2681FA2C2982  marker  [selected]"
    ;;
  *)
    echo "OK surface:43 workspace:9"
    ;;
esac
EOF
chmod +x "$FAKE"

# --- assertion helpers -----------------------------------------------------
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1" >&2
  shift || true
  while (($#)); do printf '      %s\n' "$1" >&2; shift; done
}

WS=90D8E74A-E0EE-4FCB-8F7C-105574F46F01
SFC=595D95B0-7C06-4767-BF6C-7E424D91FB8C

# Run orca-cmux with the fake cmux wired in. Resets the call log first.
orca() {
  : > "$CALL_LOG"
  CMUX_BIN="$FAKE" CMUX_CALL_LOG="$CALL_LOG" FAKE_SURFACE_UUID="$SFC" \
    "$ORCA_CMUX" "$@"
}

# The argv of the most recent cmux invocation, one arg per line.
recorded_args() { cut -f2- < "$CALL_LOG" | grep -v '^CALL$' || true; }

assert_args() {
  local desc="$1"; shift
  local expected actual
  expected=$(printf '%s\n' "$@")
  actual=$(recorded_args)
  if [[ "$expected" == "$actual" ]]; then
    pass
  else
    fail "$desc" "expected argv:" "$expected" "actual argv:" "$actual"
  fi
}

assert_eq() {
  local desc="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then pass; else
    fail "$desc" "want: [$want]" "got:  [$got]"
  fi
}

assert_no_cmux_call() {
  local desc="$1"
  if grep -q '^CALL$' "$CALL_LOG" 2>/dev/null; then
    fail "$desc" "expected no cmux invocation, but one was recorded"
  else
    pass
  fi
}

# --- tests -----------------------------------------------------------------

# create-tab builds the verified new-surface command and returns the surface UUID.
out=$(orca create-tab --workspace "$WS")
assert_args "create-tab emits verified new-surface command" \
  new-surface --type terminal --workspace "$WS" --focus false --id-format both
assert_eq "create-tab returns parsed surface UUID" "$SFC" "$out"

# create-tab can set the terminal working directory without shell-quoting tricks.
orca create-tab --workspace "$WS" --cwd "/tmp/project with spaces" >/dev/null
assert_args "create-tab passes cwd as working-directory" \
  new-surface --type terminal --workspace "$WS" --working-directory "/tmp/project with spaces" --focus false --id-format both

# send emits the verified send command, text addressed by surface UUID.
orca send --surface "$SFC" "echo hello" >/dev/null
assert_args "send emits verified send command" \
  send --surface "$SFC" "echo hello"

# send preserves text with spaces as a single argument (quoting survives the seam).
orca send --surface "$SFC" "claude --some flag" >/dev/null
assert_args "send keeps spaced text as one argv element" \
  send --surface "$SFC" "claude --some flag"

# send-key emits the verified send-key command; the literal "shift+tab" passes through.
orca send-key --surface "$SFC" "shift+tab" >/dev/null
assert_args "send-key emits verified send-key command" \
  send-key --surface "$SFC" "shift+tab"

# read-screen defaults to 40 lines and streams cmux output back.
rs=$(orca read-screen --surface "$SFC")
assert_args "read-screen defaults to 40 lines" \
  read-screen --surface "$SFC" --lines 40
assert_eq "read-screen streams cmux output" $'line one\nline two' "$rs"

# read-screen honours an explicit --lines value.
orca read-screen --surface "$SFC" --lines 12 >/dev/null
assert_args "read-screen honours --lines" \
  read-screen --surface "$SFC" --lines 12

# close maps to close-surface, addressed by UUID.
orca close --surface "$SFC" >/dev/null
assert_args "close emits close-surface command" \
  close-surface --surface "$SFC"

# list maps to list-pane-surfaces with both id forms (for debugging).
orca list >/dev/null
assert_args "list emits list-pane-surfaces command" \
  list-pane-surfaces --id-format both

# --- UUID-only invariant (ADR 0002) ----------------------------------------
# Positional refs must be refused at the boundary, before any cmux call, so a
# drifted ref can never reach a stored or deferred action.
if orca send --surface surface:5 "hi" 2>/dev/null; then
  fail "send must reject a positional ref"
else
  pass
fi
assert_no_cmux_call "send rejects ref before touching cmux"

if orca close --surface 5 2>/dev/null; then
  fail "close must reject a bare index"
else
  pass
fi
assert_no_cmux_call "close rejects index before touching cmux"

if orca create-tab --workspace workspace:9 2>/dev/null; then
  fail "create-tab must reject a workspace ref"
else
  pass
fi
assert_no_cmux_call "create-tab rejects workspace ref before touching cmux"

# --- error handling --------------------------------------------------------
if orca send --surface "$SFC" 2>/dev/null; then
  fail "send must require text"
else
  pass
fi

if orca send "echo hi" 2>/dev/null; then
  fail "send must require --surface"
else
  pass
fi

if orca read-screen --surface "$SFC" --lines abc 2>/dev/null; then
  fail "read-screen must reject non-numeric --lines"
else
  pass
fi
assert_no_cmux_call "read-screen rejects bad --lines before touching cmux"

if orca bogus-command 2>/dev/null; then
  fail "unknown command must fail"
else
  pass
fi

# create-tab fails loudly if cmux output carries no UUID (rather than returning
# a ref or empty handle that would later act on the wrong surface).
NOUUID="$TMP/cmux-nouuid"
cat > "$NOUUID" <<'EOF'
#!/usr/bin/env bash
echo "OK surface:43 pane:16 workspace:9"
EOF
chmod +x "$NOUUID"
if CMUX_BIN="$NOUUID" CMUX_CALL_LOG="$CALL_LOG" "$ORCA_CMUX" create-tab --workspace "$WS" 2>/dev/null; then
  fail "create-tab must fail when cmux output has no UUID"
else
  pass
fi

# --- summary ---------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
