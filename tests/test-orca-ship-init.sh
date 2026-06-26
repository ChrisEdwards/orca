#!/usr/bin/env bash
# Behavior tests for orca-ship-init.sh: task-id slugging, collision handling,
# and handoff dir creation. Deterministic and isolated, so this is real TDD
# surface rather than a smoke check.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
INIT="$REPO_ROOT/skills/orca-ship/scripts/orca-ship-init.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }
ok() { local desc=$1; shift; if "$@"; then pass; else fail "$desc"; fi; }
eq() { [[ "$1" == "$2" ]]; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/orca-ship-init-test.XXXXXX")
cleanup() { chmod -R u+w "$TMP" 2>/dev/null; /bin/rm -rf "$TMP"; }
trap cleanup EXIT

ROOT="$TMP/root"

ok "init: script exists" test -f "$INIT"
ok "init: script is executable" test -x "$INIT"
ok "init: bash syntax is valid" bash -n "$INIT"

# --- first run: slugging + dir creation -----------------------------------
out=$("$INIT" --task "Fix the Login Redirect!" --root "$ROOT")
rc=$?
ok "init: succeeds on a valid task" eq "$rc" "0"

task_id=$(grep '^task_id=' <<<"$out" | cut -d= -f2-)
task_dir=$(grep '^task_dir=' <<<"$out" | cut -d= -f2-)
handoff_dir=$(grep '^handoff_dir=' <<<"$out" | cut -d= -f2-)
artifacts_dir=$(grep '^artifacts_dir=' <<<"$out" | cut -d= -f2-)

ok "init: slugs the title to kebab case" eq "$task_id" "fix-the-login-redirect"
ok "init: task_dir is under the root" eq "$task_dir" "$ROOT/fix-the-login-redirect"
ok "init: handoff_dir is task_dir/handoff" eq "$handoff_dir" "$task_dir/handoff"
ok "init: artifacts_dir is task_dir/artifacts" eq "$artifacts_dir" "$task_dir/artifacts"
ok "init: handoff_dir is created" test -d "$handoff_dir"
ok "init: artifacts_dir is created" test -d "$artifacts_dir"

# --- second run with same title: collision suffix -------------------------
out2=$("$INIT" --task "Fix the Login Redirect!" --root "$ROOT")
task_id2=$(grep '^task_id=' <<<"$out2" | cut -d= -f2-)
ok "init: collides to a distinct suffixed id" eq "$task_id2" "fix-the-login-redirect-2"
ok "init: collision run creates its own dir" test -d "$ROOT/fix-the-login-redirect-2/handoff"

# --- degenerate title falls back to 'task' --------------------------------
out3=$("$INIT" --task "!!!" --root "$ROOT")
task_id3=$(grep '^task_id=' <<<"$out3" | cut -d= -f2-)
ok "init: non-alnum title falls back to 'task'" eq "$task_id3" "task"

# --- usage errors ----------------------------------------------------------
"$INIT" >/dev/null 2>&1
ok "init: missing --task exits non-zero" test "$?" -ne 0
"$INIT" --task one --bogus two >/dev/null 2>&1
ok "init: unexpected argument exits non-zero" test "$?" -ne 0

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
