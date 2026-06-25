#!/usr/bin/env bash
# Package tests for the redistributable orca-agent skill.
#
# These tests assert that a copied skill directory contains the executable
# scripts needed to spawn workers. Root bin/ wrappers are tested elsewhere for
# compatibility, but OpenSkills-style installs only carry the skill directory.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
SKILL_DIR="$REPO_ROOT/skills/orca-agent"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }

ok() { local desc=$1; shift; if "$@"; then pass; else fail "$desc"; fi; }
eq() { [[ "$1" == "$2" ]]; }

for script in orca-adapter.sh orca-cmux.sh orca-spawn.sh; do
  path="$SKILL_DIR/scripts/$script"
  ok "$script: exists in skill scripts" test -f "$path"
  ok "$script: is executable" test -x "$path"
  ok "$script: bash syntax is valid" bash -n "$path"
done

list=$("$SKILL_DIR/scripts/orca-adapter.sh" list 2>/dev/null)
ok "bundled adapter lists known agents" eq "$list" $'claude\ncodex'
ok "skill instructions point at bundled spawn script" grep -qF "scripts/orca-spawn.sh" "$SKILL_DIR/SKILL.md"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
