#!/usr/bin/env bash
# Package tests for the redistributable orca skills.
#
# These tests assert that skill directories contain their executable scripts,
# that repo-local skill discovery points at the canonical skills, and that
# intentionally shared helper copies stay byte-for-byte identical.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
SKILLS_DIR="$REPO_ROOT/skills"
EXPECTED_SKILLS=(orca-spawn orca-fork orca-msg orca-watch orca-workflow orca-ship)
SPAWN_SKILL_DIR="$REPO_ROOT/skills/orca-spawn"
FORK_SKILL_DIR="$REPO_ROOT/skills/orca-fork"
MSG_SKILL_DIR="$REPO_ROOT/skills/orca-msg"
WATCH_SKILL_DIR="$REPO_ROOT/skills/orca-watch"
WORKFLOW_SKILL_DIR="$REPO_ROOT/skills/orca-workflow"
CODEX_SPAWN_SKILL_LINK="$REPO_ROOT/.agents/skills/orca-spawn"
CODEX_FORK_SKILL_LINK="$REPO_ROOT/.agents/skills/orca-fork"
CODEX_MSG_SKILL_LINK="$REPO_ROOT/.agents/skills/orca-msg"
CODEX_WATCH_SKILL_LINK="$REPO_ROOT/.agents/skills/orca-watch"
PLUGIN_MANIFEST="$REPO_ROOT/.codex-plugin/plugin.json"
MARKETPLACE="$REPO_ROOT/.agents/plugins/marketplace.json"
CLAUDE_PLUGIN_MANIFEST="$REPO_ROOT/.claude-plugin/plugin.json"
CLAUDE_MARKETPLACE="$REPO_ROOT/.claude-plugin/marketplace.json"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }

ok() { local desc=$1; shift; if "$@"; then pass; else fail "$desc"; fi; }
eq() { [[ "$1" == "$2" ]]; }
json_get() { jq -er "$2" "$1"; }
valid_json() { jq -e . "$1" >/dev/null; }
does_not_contain() { ! grep -qF "$1" "$2"; }

expected_skill_set=$(printf '%s\n' "${EXPECTED_SKILLS[@]}" | sort)
actual_skill_set=$(find "$SKILLS_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)
ok "shipped skills exactly match expected package list" eq "$actual_skill_set" "$expected_skill_set"

for skill in "${EXPECTED_SKILLS[@]}"; do
  skill_dir="$SKILLS_DIR/$skill"
  ok "$skill skill directory exists" test -d "$skill_dir"
  ok "$skill SKILL.md exists" test -f "$skill_dir/SKILL.md"
done

for script in orca-adapter.sh orca-cmux.sh orca-spawn.sh orca-trust-prompt.sh orca-upgrade-prompt.sh orca-launch.sh; do
  path="$SPAWN_SKILL_DIR/scripts/$script"
  ok "orca-spawn/$script: exists in skill scripts" test -f "$path"
  ok "orca-spawn/$script: is executable" test -x "$path"
  ok "orca-spawn/$script: bash syntax is valid" bash -n "$path"
done

for script in orca-fork-adapter.sh orca-cmux.sh orca-fork.sh orca-trust-prompt.sh orca-upgrade-prompt.sh orca-launch.sh; do
  path="$FORK_SKILL_DIR/scripts/$script"
  ok "orca-fork/$script: exists in skill scripts" test -f "$path"
  ok "orca-fork/$script: is executable" test -x "$path"
  ok "orca-fork/$script: bash syntax is valid" bash -n "$path"
done

for script in orca-cmux.sh orca-msg.sh; do
  path="$MSG_SKILL_DIR/scripts/$script"
  ok "orca-msg/$script: exists in skill scripts" test -f "$path"
  ok "orca-msg/$script: is executable" test -x "$path"
  ok "orca-msg/$script: bash syntax is valid" bash -n "$path"
done

for script in orca-watch.sh; do
  path="$WATCH_SKILL_DIR/scripts/$script"
  ok "orca-watch/$script: exists in skill scripts" test -f "$path"
  ok "orca-watch/$script: is executable" test -x "$path"
  ok "orca-watch/$script: bash syntax is valid" bash -n "$path"
done

for script in orca-workflow-init.sh; do
  path="$WORKFLOW_SKILL_DIR/scripts/$script"
  ok "orca-workflow/$script: exists in skill scripts" test -f "$path"
  ok "orca-workflow/$script: is executable" test -x "$path"
  ok "orca-workflow/$script: bash syntax is valid" bash -n "$path"
done

for skill in "${EXPECTED_SKILLS[@]}"; do
  scripts_dir="$SKILLS_DIR/$skill/scripts"
  if [[ -d "$scripts_dir" ]]; then
    while IFS= read -r path; do
      script=$(basename "$path")
      ok "$skill/$script: bundled script exists" test -f "$path"
      ok "$skill/$script: bundled script is executable" test -x "$path"
      ok "$skill/$script: bundled script bash syntax is valid" bash -n "$path"
    done < <(find "$scripts_dir" -maxdepth 1 -type f -name '*.sh' | sort)
  fi
done

list=$("$SPAWN_SKILL_DIR/scripts/orca-adapter.sh" list 2>/dev/null)
ok "bundled adapter lists known agents" eq "$list" $'claude\ncodex'
fork_list=$("$FORK_SKILL_DIR/scripts/orca-fork-adapter.sh" list 2>/dev/null)
ok "bundled fork adapter lists known providers" eq "$fork_list" $'codex\nclaude'
ok "orca-spawn instructions point at bundled spawn script" grep -qF "scripts/orca-spawn.sh" "$SPAWN_SKILL_DIR/SKILL.md"
ok "orca-spawn instructions forbid check-in-able handoff files" grep -qF "Do not ask the worker to write reports, findings, logs, status files, or handoff files anywhere in the repo where they can be checked in." "$SPAWN_SKILL_DIR/SKILL.md"
ok "orca-spawn instructions prefer final response for worker findings" grep -qF "For worker findings, default to the worker's final response in its tab." "$SPAWN_SKILL_DIR/SKILL.md"
ok "orca-spawn instructions route durable artifacts to tmp" grep -qF 'If a durable handoff or artifact is genuinely useful, put it outside the repo under `${TMPDIR:-/tmp}/orca/<task-id>/`, and report the absolute path back to the human.' "$SPAWN_SKILL_DIR/SKILL.md"
ok "orca-fork instructions point at bundled fork script" grep -qF "scripts/orca-fork.sh" "$FORK_SKILL_DIR/SKILL.md"
ok "orca-msg instructions point at bundled message script" grep -qF "scripts/orca-msg.sh" "$MSG_SKILL_DIR/SKILL.md"
ok "orca-watch instructions point at bundled watch script" grep -qF "scripts/orca-watch.sh" "$WATCH_SKILL_DIR/SKILL.md"
ok "orca-workflow instructions point at bundled workflow init script" grep -qF "scripts/orca-workflow-init.sh" "$WORKFLOW_SKILL_DIR/SKILL.md"
ok "orca-workflow SKILL.md avoids sibling skill script paths" does_not_contain "orca-cmux.sh" "$WORKFLOW_SKILL_DIR/SKILL.md"
ok "orca-workflow SKILL.md avoids sibling skill phrasing" does_not_contain "from the orca-spawn skill" "$WORKFLOW_SKILL_DIR/SKILL.md"
ok "Codex orca-spawn project skill entry exists" test -L "$CODEX_SPAWN_SKILL_LINK"
ok "Codex orca-spawn project skill entry points at canonical skill" eq "$(readlink "$CODEX_SPAWN_SKILL_LINK")" "../../skills/orca-spawn"
ok "Codex orca-spawn project skill resolves to SKILL.md" test -f "$CODEX_SPAWN_SKILL_LINK/SKILL.md"
# Claude discovers skills via the plugin's "skills": "./skills/" auto-discovery,
# so there is no .claude/skills dev symlink (dropped in 6158cf3). The
# .agents/skills/* symlinks remain the Codex dev-discovery convention.
ok "Codex orca-fork project skill entry exists" test -L "$CODEX_FORK_SKILL_LINK"
ok "Codex orca-fork project skill entry points at canonical skill" eq "$(readlink "$CODEX_FORK_SKILL_LINK")" "../../skills/orca-fork"
ok "Codex orca-fork project skill resolves to SKILL.md" test -f "$CODEX_FORK_SKILL_LINK/SKILL.md"
ok "Codex orca-msg project skill entry exists" test -L "$CODEX_MSG_SKILL_LINK"
ok "Codex orca-msg project skill entry points at canonical skill" eq "$(readlink "$CODEX_MSG_SKILL_LINK")" "../../skills/orca-msg"
ok "Codex orca-msg project skill resolves to SKILL.md" test -f "$CODEX_MSG_SKILL_LINK/SKILL.md"
ok "Codex orca-watch project skill entry exists" test -L "$CODEX_WATCH_SKILL_LINK"
ok "Codex orca-watch project skill entry points at canonical skill" eq "$(readlink "$CODEX_WATCH_SKILL_LINK")" "../../skills/orca-watch"
ok "Codex orca-watch project skill resolves to SKILL.md" test -f "$CODEX_WATCH_SKILL_LINK/SKILL.md"
ok "shared orca-cmux helpers are exact copies" cmp -s "$SPAWN_SKILL_DIR/scripts/orca-cmux.sh" "$FORK_SKILL_DIR/scripts/orca-cmux.sh"
ok "shared orca-cmux helper includes orca-msg" cmp -s "$SPAWN_SKILL_DIR/scripts/orca-cmux.sh" "$MSG_SKILL_DIR/scripts/orca-cmux.sh"
ok "shared orca-trust-prompt helpers are exact copies" cmp -s "$SPAWN_SKILL_DIR/scripts/orca-trust-prompt.sh" "$FORK_SKILL_DIR/scripts/orca-trust-prompt.sh"
ok "shared orca-upgrade-prompt helpers are exact copies" cmp -s "$SPAWN_SKILL_DIR/scripts/orca-upgrade-prompt.sh" "$FORK_SKILL_DIR/scripts/orca-upgrade-prompt.sh"
ok "shared orca-launch helpers are exact copies" cmp -s "$SPAWN_SKILL_DIR/scripts/orca-launch.sh" "$FORK_SKILL_DIR/scripts/orca-launch.sh"

ok "Codex plugin manifest exists" test -f "$PLUGIN_MANIFEST"
ok "Codex plugin manifest is valid JSON" valid_json "$PLUGIN_MANIFEST"
ok "Codex plugin identity is orca" eq "$(json_get "$PLUGIN_MANIFEST" '.name')" "orca"
ok "Codex plugin packages the skills directory" eq "$(json_get "$PLUGIN_MANIFEST" '.skills')" "./skills/"
ok "Codex plugin skills path resolves" test -d "$REPO_ROOT/$(json_get "$PLUGIN_MANIFEST" '.skills')"
ok "Codex plugin includes orca-spawn skill" test -f "$REPO_ROOT/$(json_get "$PLUGIN_MANIFEST" '.skills')/orca-spawn/SKILL.md"
ok "Codex plugin includes orca-fork skill" test -f "$REPO_ROOT/$(json_get "$PLUGIN_MANIFEST" '.skills')/orca-fork/SKILL.md"
ok "Codex plugin includes orca-msg skill" test -f "$REPO_ROOT/$(json_get "$PLUGIN_MANIFEST" '.skills')/orca-msg/SKILL.md"
for skill in "${EXPECTED_SKILLS[@]}"; do
  ok "Codex plugin includes $skill skill" test -f "$REPO_ROOT/$(json_get "$PLUGIN_MANIFEST" '.skills')/$skill/SKILL.md"
done

ok "Codex marketplace exists" test -f "$MARKETPLACE"
ok "Codex marketplace is valid JSON" valid_json "$MARKETPLACE"
ok "Codex marketplace uses owner namespace" eq "$(json_get "$MARKETPLACE" '.name')" "chrisedwards"
ok "Codex marketplace exposes the orca plugin" eq "$(json_get "$MARKETPLACE" '.plugins[] | select(.name == "orca") | .name')" "orca"
ok "Codex marketplace uses Git URL source" eq "$(json_get "$MARKETPLACE" '.plugins[] | select(.name == "orca") | .source.source')" "url"
ok "Codex marketplace points at the repository" eq "$(json_get "$MARKETPLACE" '.plugins[] | select(.name == "orca") | .source.url')" "https://github.com/ChrisEdwards/orca.git"

ok "Claude plugin manifest exists" test -f "$CLAUDE_PLUGIN_MANIFEST"
ok "Claude plugin manifest is valid JSON" valid_json "$CLAUDE_PLUGIN_MANIFEST"
ok "Claude plugin identity is orca" eq "$(json_get "$CLAUDE_PLUGIN_MANIFEST" '.name')" "orca"
ok "Claude plugin packages the skills directory" eq "$(json_get "$CLAUDE_PLUGIN_MANIFEST" '.skills')" "./skills/"
ok "Claude plugin skills path resolves" test -d "$REPO_ROOT/$(json_get "$CLAUDE_PLUGIN_MANIFEST" '.skills')"
ok "Claude plugin includes orca-spawn skill" test -f "$REPO_ROOT/$(json_get "$CLAUDE_PLUGIN_MANIFEST" '.skills')/orca-spawn/SKILL.md"
ok "Claude plugin includes orca-fork skill" test -f "$REPO_ROOT/$(json_get "$CLAUDE_PLUGIN_MANIFEST" '.skills')/orca-fork/SKILL.md"
ok "Claude plugin includes orca-msg skill" test -f "$REPO_ROOT/$(json_get "$CLAUDE_PLUGIN_MANIFEST" '.skills')/orca-msg/SKILL.md"
for skill in "${EXPECTED_SKILLS[@]}"; do
  ok "Claude plugin includes $skill skill" test -f "$REPO_ROOT/$(json_get "$CLAUDE_PLUGIN_MANIFEST" '.skills')/$skill/SKILL.md"
done

ok "Claude marketplace exists" test -f "$CLAUDE_MARKETPLACE"
ok "Claude marketplace is valid JSON" valid_json "$CLAUDE_MARKETPLACE"
ok "Claude marketplace uses owner namespace" eq "$(json_get "$CLAUDE_MARKETPLACE" '.name')" "chrisedwards"
ok "Claude marketplace exposes the orca plugin" eq "$(json_get "$CLAUDE_MARKETPLACE" '.plugins[] | select(.name == "orca") | .name')" "orca"
ok "Claude marketplace source is root-native" eq "$(json_get "$CLAUDE_MARKETPLACE" '.plugins[] | select(.name == "orca") | .source')" "./"
ok "Claude marketplace source resolves to repo root" test -f "$REPO_ROOT/$(json_get "$CLAUDE_MARKETPLACE" '.plugins[] | select(.name == "orca") | .source')/.claude-plugin/plugin.json"

duplicate_runtime_scripts=$(find "$REPO_ROOT" -path "$REPO_ROOT/.git" -prune -o -path "$REPO_ROOT/skills/*/scripts/*" -prune -o -name 'orca-*.sh' -print)
ok "runtime scripts are not duplicated outside skill directories" eq "$duplicate_runtime_scripts" ""

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
