#!/usr/bin/env bash
# Tests for hooks/pre-commit — script copy-parity enforcement.
#
# Each test spins up an isolated git repo with a skills/ layout so the hook's
# git commands operate on controlled state. No external test deps.
# Run: tests/test-hook-pre-commit.sh
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
HOOK="$REPO_ROOT/hooks/pre-commit"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1" >&2
  shift || true
  while (($#)); do printf '      %s\n' "$1" >&2; shift; done
}

# Create a minimal git repo for hook testing; print its path.
make_repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  printf '%s' "$dir"
}

cleanup() { rm -rf "$1"; }

# assert_hook_passes <desc> <repo>
# Expect the hook to exit 0 when run in <repo>.
assert_hook_passes() {
  local desc=$1 repo=$2 rc
  (cd "$repo" && bash "$HOOK" 2>/dev/null); rc=$?
  if [[ $rc -eq 0 ]]; then pass
  else fail "$desc: expected exit 0, got $rc"
  fi
}

# assert_hook_fails <desc> <repo>
# Expect the hook to exit non-zero. Captures combined stdout+stderr into $HOOK_OUT.
HOOK_OUT=""
assert_hook_fails() {
  local desc=$1 repo=$2 rc
  HOOK_OUT=$(cd "$repo" && bash "$HOOK" 2>&1) && rc=0 || rc=$?
  if [[ $rc -ne 0 ]]; then pass
  else fail "$desc: expected non-zero exit, got 0"
  fi
}

# assert_out_has <desc> <pattern>
# Check that $HOOK_OUT contains <pattern> (grep regex).
assert_out_has() {
  local desc=$1 pattern=$2
  if printf '%s' "$HOOK_OUT" | grep -q "$pattern"; then pass
  else fail "$desc" "pattern: [$pattern]" "output: [$HOOK_OUT]"
  fi
}

# assert_out_lacks <desc> <pattern>
# Check that $HOOK_OUT does NOT contain <pattern> (grep regex).
assert_out_lacks() {
  local desc=$1 pattern=$2
  if ! printf '%s' "$HOOK_OUT" | grep -q "$pattern"; then pass
  else fail "$desc" "should not match: [$pattern]" "output: [$HOOK_OUT]"
  fi
}

# ----------------------------------------------------------------
# 1. No staged files in skills/*/scripts/ → passes silently
# ----------------------------------------------------------------
repo=$(make_repo)
mkdir -p "$repo/other"
printf 'hello\n' > "$repo/other/readme.txt"
(cd "$repo" && git add other/readme.txt)
assert_hook_passes "no skill scripts staged" "$repo"
cleanup "$repo"

# ----------------------------------------------------------------
# 2. Script exists in only one skill → passes (nothing to compare)
# ----------------------------------------------------------------
repo=$(make_repo)
mkdir -p "$repo/skills/orca-spawn/scripts"
printf '#!/bin/bash\necho hi\n' > "$repo/skills/orca-spawn/scripts/unique.sh"
(cd "$repo" && git add skills/orca-spawn/scripts/unique.sh)
assert_hook_passes "staged script has no peer copies" "$repo"
cleanup "$repo"

# ----------------------------------------------------------------
# 3. All copies of a shared script staged identically → passes
# ----------------------------------------------------------------
repo=$(make_repo)
for skill in orca-spawn orca-fork orca-msg; do
  mkdir -p "$repo/skills/$skill/scripts"
  printf '#!/bin/bash\necho shared\n' > "$repo/skills/$skill/scripts/shared.sh"
done
(cd "$repo" && git add \
  skills/orca-spawn/scripts/shared.sh \
  skills/orca-fork/scripts/shared.sh \
  skills/orca-msg/scripts/shared.sh)
assert_hook_passes "identical copies all staged" "$repo"
cleanup "$repo"

# ----------------------------------------------------------------
# 4. One copy staged (divergent), peers at HEAD → fails with cp commands
# ----------------------------------------------------------------
repo=$(make_repo)
for skill in orca-spawn orca-fork orca-msg; do
  mkdir -p "$repo/skills/$skill/scripts"
  printf '#!/bin/bash\necho original\n' > "$repo/skills/$skill/scripts/shared.sh"
done
(cd "$repo" && git add . && git commit -q -m "init")
printf '#!/bin/bash\necho modified\n' > "$repo/skills/orca-spawn/scripts/shared.sh"
(cd "$repo" && git add skills/orca-spawn/scripts/shared.sh)

assert_hook_fails "one staged copy diverges from peers" "$repo"
assert_out_has  "error names the diverging script"       "shared\.sh"
assert_out_has  "error marks the staged copy"            "<- staged"
assert_out_has  "error includes copy-parity reminder"    "shared by copying"
assert_out_has  "error provides cp command"              "cp skills/orca-spawn/scripts/shared.sh"
assert_out_has  "cp targets orca-fork peer"              "skills/orca-fork/scripts/shared.sh"
assert_out_has  "cp targets orca-msg peer"               "skills/orca-msg/scripts/shared.sh"
cleanup "$repo"

# ----------------------------------------------------------------
# 5. Multiple copies staged with different content → fails, no cp commands
# ----------------------------------------------------------------
repo=$(make_repo)
for skill in orca-spawn orca-fork orca-msg; do
  mkdir -p "$repo/skills/$skill/scripts"
  printf '#!/bin/bash\necho original\n' > "$repo/skills/$skill/scripts/shared.sh"
done
(cd "$repo" && git add . && git commit -q -m "init")
printf '#!/bin/bash\necho v2\n' > "$repo/skills/orca-spawn/scripts/shared.sh"
printf '#!/bin/bash\necho v3\n' > "$repo/skills/orca-fork/scripts/shared.sh"
(cd "$repo" && git add \
  skills/orca-spawn/scripts/shared.sh \
  skills/orca-fork/scripts/shared.sh)

assert_hook_fails "multiple staged copies differ" "$repo"
assert_out_lacks  "no cp commands when source is ambiguous" "^    cp "
cleanup "$repo"

# ----------------------------------------------------------------
# Summary
# ----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
