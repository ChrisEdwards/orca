#!/usr/bin/env bash
# Unit tests for skills/orca-fork/scripts/orca-fork-adapter.sh.
#
# The fork adapter owns provider-specific fork command construction and
# readiness markers. These tests keep those strings out of orchestration logic.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ADAPTER="$REPO_ROOT/skills/orca-fork/scripts/orca-fork-adapter.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1" >&2
  shift || true
  while (($#)); do printf '      %s\n' "$1" >&2; shift; done
}

assert_field() {
  local want=$1; shift
  local got rc
  got=$("$ADAPTER" "$@" 2>/dev/null); rc=$?
  if [[ $rc -eq 0 && "$got" == "$want" ]]; then
    pass
  else
    fail "orca-fork-adapter $* -> '$want'" "got (rc=$rc): [$got]"
  fi
}

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

CODEX_ID=019EFC9B-9880-7810-A352-D6427E876693
CLAUDE_ID=3B877D88-C1EC-44FC-8987-AEE00A86CD12

assert_field "›" codex ready-marker
assert_field "← for agents" claude ready-marker

assert_field "codex fork $CODEX_ID" codex launch "$CODEX_ID"
assert_field "claude --resume $CLAUDE_ID --fork-session" claude launch "$CLAUDE_ID"

quoted_prompt=$(printf '%q' "Investigate auth failures")
assert_field "codex fork $CODEX_ID $quoted_prompt" codex launch "$CODEX_ID" "Investigate auth failures"
assert_field "claude --resume $CLAUDE_ID --fork-session $quoted_prompt" claude launch "$CLAUDE_ID" "Investigate auth failures"

multiline_prompt=$'line one\nline two'
quoted_multiline=$(printf '%q' "$multiline_prompt")
assert_field "codex fork $CODEX_ID $quoted_multiline" codex launch "$CODEX_ID" "$multiline_prompt"

list=$("$ADAPTER" list 2>/dev/null)
if grep -qx codex <<<"$list" && grep -qx claude <<<"$list"; then pass
else fail "list names both providers" "got: [$list]"; fi

assert_fails "unknown provider" bogus ready-marker
assert_fails "unknown codex field" codex bogus-field
assert_fails "launch without id" codex launch
assert_fails "ready-marker with extras" claude ready-marker extra
assert_fails "no args"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
