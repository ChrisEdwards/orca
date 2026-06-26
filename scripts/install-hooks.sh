#!/usr/bin/env bash
# Symlinks repo hooks into .git/hooks. Run once after cloning.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
hooks_dir="${repo_root}/.git/hooks"
src="${repo_root}/hooks/pre-push"
dest="${hooks_dir}/pre-push"

if [ ! -f "$src" ]; then
  echo "Error: $src not found." >&2
  exit 1
fi

mkdir -p "$hooks_dir"
chmod +x "$src"
ln -sf "$src" "$dest"
echo "Installed: $dest -> $src"
