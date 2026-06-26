## Instructions

Use TDD where it is feasible and valuable: behavior-heavy code, bug fixes with
clear reproduction steps, and interfaces where a test can exercise real public
behavior. Do not create brittle or artificial tests only to satisfy TDD. For
packaging metadata, documentation, generated manifests, external CLI smoke
checks, or behavior that is hard to observe deterministically, prefer direct
validation commands and clear manual smoke-test notes over overbuilt test code.

All code changes should have a bead tracking it. Create one if you are making changes and don't have one.

When implementing a bead:

1. Before starting implementation, claim the bead which will set it to in-progress.
2. Implement the bead, using TDD only where it fits the change.
3. Commit (using conventional commits and including the bead id) and push
4. Close the bead with a comment stating what you did and the commit hash(es)

## Reflection

When you make a mistake and overcome it, update your AGENTS.md or relavent SKILL.md files to ensure you don't repeat that mistake next time. Keep this under the `## Learnings` header.  Keep these concise, but ensure they are rich enough to be effective.

You can also add meaningful learnings that you learn along the way. 

## Skill Packaging

Skills must be self-contained. Runtime files a skill needs belong inside that
skill directory, usually under `scripts/`, `references/`, or `assets/`.

Do not have a skill reference files outside its own directory tree, including
sibling skills, repo-root scripts, or absolute installed plugin/cache paths.
OpenSkills, Codex plugins, and other installers may copy each skill as an
isolated unit.

When two skills need the same helper, prefer duplicating the small helper into
each skill over introducing a shared runtime path. If the helper is too large or
needs one source of truth, promote it to a separately installed external CLI and
document it as a prerequisite.

## Learnings

- The `orca-cmux.sh` copy-parity test only guarantees the shared cmux seam stays byte-for-byte identical. `orca-spawn.sh` and `orca-fork.sh` are not copied files; shared user-facing behavior across them needs explicit behavior tests in both suites.
- `br create` does not accept `--acceptance`; create the bead first, then use `br update <id> --acceptance-criteria="$criteria"` for acceptance criteria.
- `br create --json` returns a single JSON object, not an array. Extract ids with `jq -r '.id'`.
- Worker findings should default to the worker's final response. If a durable handoff or artifact is needed, use `${TMPDIR:-/tmp}/orca/<task-id>/`, never paths inside the repo that can be checked in.

<!-- br-agent-instructions-v1 -->

---

## Beads Workflow Integration

This project uses [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`/`bd`) for issue tracking. Issues are stored in `.beads/` and tracked in git.

### Essential Commands

```bash
# View ready issues (open, unblocked, not deferred)
br ready              # or: bd ready

# List and search
br list --status=open # All open issues
br show <id>          # Full issue details with dependencies
br search "keyword"   # Full-text search

# Create and update
br create --title="..." --description="..." --type=task --priority=2
br update <id> --status=in_progress
br close <id> --reason="Completed"
br close <id1> <id2>  # Close multiple issues at once

# Sync with git
br sync --flush-only  # Export DB to JSONL
br sync --status      # Check sync status
```

### Workflow Pattern

1. **Start**: Run `br ready` to find actionable work
2. **Claim**: Use `br update <id> --status=in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `br close <id>`
5. **Sync**: Always run `br sync --flush-only` at session end

### Key Concepts

- **Dependencies**: Issues can block other issues. `br ready` shows only open, unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers 0-4, not words)
- **Types**: task, bug, feature, epic, chore, docs, question
- **Blocking**: `br dep add <issue> <depends-on>` to add dependencies

### Session Protocol

**Before ending any session, run this checklist:**

```bash
git status              # Check what changed
git add <files>         # Stage code changes
br sync --flush-only    # Export beads changes to JSONL
git commit -m "..."     # Commit everything
git push                # Push to remote
```

### Best Practices

- Check `br ready` at session start to find available work
- Update status as you work (in_progress → closed)
- Create new issues with `br create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always sync before ending session

<!-- end-br-agent-instructions -->

## Agent skills

### Issue tracker

Issues are tracked with beads (`.beads/`, `br` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Triage roles map to beads statuses and tags. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout. `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
