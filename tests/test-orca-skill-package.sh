#!/usr/bin/env bash
# Package tests for the redistributable orca-agent skill.
#
# These tests assert that the skill directory contains the executable scripts
# needed to spawn workers, and that the repo exposes the skill from Codex's
# native project-skill discovery path without duplicating the implementation.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
SKILL_DIR="$REPO_ROOT/skills/orca-agent"
CODEX_SKILL_LINK="$REPO_ROOT/.agents/skills/orca-agent"
PLUGIN_MANIFEST="$REPO_ROOT/.codex-plugin/plugin.json"
MARKETPLACE="$REPO_ROOT/.agents/plugins/marketplace.json"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }

ok() { local desc=$1; shift; if "$@"; then pass; else fail "$desc"; fi; }
eq() { [[ "$1" == "$2" ]]; }
json_get() { jq -er "$2" "$1"; }
valid_json() { jq -e . "$1" >/dev/null; }

for script in orca-adapter.sh orca-cmux.sh orca-spawn.sh; do
  path="$SKILL_DIR/scripts/$script"
  ok "$script: exists in skill scripts" test -f "$path"
  ok "$script: is executable" test -x "$path"
  ok "$script: bash syntax is valid" bash -n "$path"
done

list=$("$SKILL_DIR/scripts/orca-adapter.sh" list 2>/dev/null)
ok "bundled adapter lists known agents" eq "$list" $'claude\ncodex'
ok "skill instructions point at bundled spawn script" grep -qF "scripts/orca-spawn.sh" "$SKILL_DIR/SKILL.md"
ok "Codex project skill entry exists" test -L "$CODEX_SKILL_LINK"
ok "Codex project skill entry points at canonical skill" eq "$(readlink "$CODEX_SKILL_LINK")" "../../skills/orca-agent"
ok "Codex project skill resolves to SKILL.md" test -f "$CODEX_SKILL_LINK/SKILL.md"

ok "Codex plugin manifest exists" test -f "$PLUGIN_MANIFEST"
ok "Codex plugin manifest is valid JSON" valid_json "$PLUGIN_MANIFEST"
ok "Codex plugin identity is orca" eq "$(json_get "$PLUGIN_MANIFEST" '.name')" "orca"
ok "Codex plugin packages the skills directory" eq "$(json_get "$PLUGIN_MANIFEST" '.skills')" "./skills/"
ok "Codex plugin skills path resolves" test -d "$REPO_ROOT/$(json_get "$PLUGIN_MANIFEST" '.skills')"
ok "Codex plugin includes orca-agent skill" test -f "$REPO_ROOT/$(json_get "$PLUGIN_MANIFEST" '.skills')/orca-agent/SKILL.md"

ok "Codex marketplace exists" test -f "$MARKETPLACE"
ok "Codex marketplace is valid JSON" valid_json "$MARKETPLACE"
ok "Codex marketplace uses owner namespace" eq "$(json_get "$MARKETPLACE" '.name')" "chrisedwards"
ok "Codex marketplace exposes the orca plugin" eq "$(json_get "$MARKETPLACE" '.plugins[] | select(.name == "orca") | .name')" "orca"
ok "Codex marketplace uses Git URL source" eq "$(json_get "$MARKETPLACE" '.plugins[] | select(.name == "orca") | .source.source')" "url"
ok "Codex marketplace points at the repository" eq "$(json_get "$MARKETPLACE" '.plugins[] | select(.name == "orca") | .source.url')" "https://github.com/ChrisEdwards/orca.git"

duplicate_runtime_scripts=$(find "$REPO_ROOT" -path "$REPO_ROOT/.git" -prune -o -path "$REPO_ROOT/skills/*/scripts/*" -prune -o -name 'orca-*.sh' -print)
ok "runtime scripts are not duplicated outside skill directories" eq "$duplicate_runtime_scripts" ""

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
