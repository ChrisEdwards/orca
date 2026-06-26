#!/usr/bin/env bash
# Symlinks all hooks in hooks/ into .git/hooks. Run once after cloning.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
hooks_dir="${repo_root}/.git/hooks"
src_dir="${repo_root}/hooks"

mkdir -p "$hooks_dir"

installed=0
for src in "$src_dir"/*; do
  [ -f "$src" ] || continue
  hook_name=$(basename "$src")
  dest="${hooks_dir}/${hook_name}"
  chmod +x "$src"
  ln -sf "$src" "$dest"
  echo "Installed: $dest -> $src"
  installed=$((installed + 1))
done

if [ "$installed" -eq 0 ]; then
  echo "No hooks found in $src_dir" >&2
  exit 1
fi
