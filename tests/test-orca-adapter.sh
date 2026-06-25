#!/usr/bin/env bash
# Unit tests for skills/orca-agent/scripts/orca-adapter.sh.
#
# Adapters are pure configuration: the one place that knows agent-specific
# details (launch command, readiness marker, optional mode step). These tests
# assert the adapter fields are defined, selectable by agent type, and that the
# schema cleanly expresses "no mode step" (Codex) vs "cycle to auto mode on"
# (Claude). No external test deps. Run: tests/test-orca-adapter.sh
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ADAPTER="$REPO_ROOT/skills/orca-agent/scripts/orca-adapter.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1" >&2
  shift || true
  while (($#)); do printf '      %s\n' "$1" >&2; shift; done
}

# assert that `orca-adapter <args...>` prints exactly <want> and exits 0.
assert_field() {
  local want=$1; shift
  local got rc
  got=$("$ADAPTER" "$@" 2>/dev/null); rc=$?
  if [[ $rc -eq 0 && "$got" == "$want" ]]; then
    pass
  else
    fail "orca-adapter $* -> '$want'" "got (rc=$rc): [$got]"
  fi
}

# assert that `orca-adapter <args...>` fails (non-zero) and prints nothing to stdout.
assert_fails() {
  local desc=$1; shift
  local got rc
  got=$("$ADAPTER" "$@" 2>/dev/null); rc=$?
  if [[ $rc -ne 0 && -z "$got" ]]; then
    pass
  else
    fail "$desc should fail with empty stdout" "rc=$rc stdout=[$got]"
  fi
}

# --- Claude adapter --------------------------------------------------------
assert_field "claude"        claude launch
assert_field "← for agents"  claude ready-marker
assert_field "cycle"         claude mode
assert_field "shift+tab"     claude mode-key
assert_field "auto mode on"  claude mode-target
assert_field "5"             claude mode-max-attempts

# --- Codex adapter ---------------------------------------------------------
assert_field "codex -p yolo" codex launch
assert_field "›"             codex ready-marker
assert_field "none"          codex mode

# Codex has no mode step: asking for mode sub-fields is a usage error, not an
# empty string that spawn logic might silently act on.
assert_fails "codex mode-key (no mode step)"          codex mode-key
assert_fails "codex mode-target (no mode step)"       codex mode-target
assert_fails "codex mode-max-attempts (no mode step)" codex mode-max-attempts

# --- selection + errors ----------------------------------------------------
# Both adapters are discoverable.
list=$("$ADAPTER" list 2>/dev/null)
if grep -qx claude <<<"$list" && grep -qx codex <<<"$list"; then pass
else fail "list names both adapters" "got: [$list]"; fi

assert_fails "unknown agent type"  bogus launch
assert_fails "unknown claude field" claude bogus-field
assert_fails "no args"             # bare invocation
assert_fails "type without field"  claude

# --- summary ---------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
