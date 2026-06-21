# Issue tracker: Beads

Issues for this repo live in `.beads/` and are managed with the `br` CLI.

## Conventions

- Issues are created with `br create --title="..." --description="..." --type=<type> --priority=<0-4>`
- View actionable work with `br ready` (open, unblocked, not deferred)
- Search with `br search "keyword"` or list with `br list --status=open`
- Full details with `br show <id>`

## When a skill says "publish to the issue tracker"

Create a new beads issue: `br create --title="<title>" --description="<description>" --type=task --priority=2`

## When a skill says "fetch the relevant ticket"

Run `br show <id>` with the issue ID the user provides.

## When a skill says "apply a label"

Beads uses statuses and tags rather than labels. See `triage-labels.md` for the mapping.

## Sync protocol

Always run `br sync --flush-only` after making changes to export the DB to JSONL for git tracking.
