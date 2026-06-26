#!/usr/bin/env bash
#
# orca-ship-init - set up the task id and handoff workspace for one ship run.
#
# orca-ship hands context between steps through files, never through worker
# conversation history. Those files live OUTSIDE the target repo so they can
# never be committed: ${TMPDIR:-/tmp}/orca/<task-id>/. This helper owns only the
# deterministic mechanics (slugging the task id, creating the dirs) so the rest
# of orca-ship can stay orchestrator-driven.
#
# Usage:
#   orca-ship-init.sh --task <title> [--root <dir>]
#
#   --task   human task title; becomes the kebab task id (collision-suffixed)
#   --root   base dir for task state (default ${TMPDIR:-/tmp}/orca)
#
# Output (stdout, key=value lines):
#   task_id=<kebab slug>
#   task_dir=<root>/<task-id>
#   handoff_dir=<task-dir>/handoff
#   artifacts_dir=<task-dir>/artifacts
set -euo pipefail

die() { printf 'orca-ship-init: %s\n' "$1" >&2; exit 1; }

task=""; root=""
while (($#)); do
  case "$1" in
    --task) [[ $# -ge 2 ]] || die "--task needs a value"; task=$2; shift 2 ;;
    --root) [[ $# -ge 2 ]] || die "--root needs a value"; root=$2; shift 2 ;;
    *) die "unexpected argument: $1" ;;
  esac
done
[[ -n "$task" ]] || die "usage: orca-ship-init.sh --task <title> [--root <dir>]"

root=${root:-${TMPDIR:-/tmp}/orca}

slug=$(printf '%s' "$task" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')
slug=${slug#-}; slug=${slug%-}
[[ -n "$slug" ]] || slug=task

# mkdir is the collision guard: it fails if the task dir already exists, so two
# runs of the same title get distinct ids rather than sharing handoff state.
task_id=$slug
n=2
while ! mkdir -p "$root" 2>/dev/null || ! mkdir "$root/$task_id" 2>/dev/null; do
  [[ -d "$root" ]] || die "could not create task root: $root"
  task_id="$slug-$n"; n=$((n + 1))
  ((n <= 1000)) || die "could not allocate a unique task dir under $root"
done

task_dir="$root/$task_id"
handoff_dir="$task_dir/handoff"
artifacts_dir="$task_dir/artifacts"
mkdir -p "$handoff_dir" "$artifacts_dir" || die "could not create handoff dirs under $task_dir"

printf 'task_id=%s\n' "$task_id"
printf 'task_dir=%s\n' "$task_dir"
printf 'handoff_dir=%s\n' "$handoff_dir"
printf 'artifacts_dir=%s\n' "$artifacts_dir"
