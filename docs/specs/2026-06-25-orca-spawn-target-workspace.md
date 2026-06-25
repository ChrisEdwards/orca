# orca-spawn target workspaces

Extend `orca-spawn` so a caller can spawn a worker in a target cmux workspace other than the calling workspace. This supports higher-level skills, such as future PR-review skills, that resolve a local repository path and then ask `orca-spawn` to put the worker in the repo's workspace.

## Boundary

`orca-spawn` owns cmux target workspace routing:

* choose the calling workspace by default
* resolve a target workspace by exact name or UUID
* create a missing named workspace in the caller's current cmux window
* create the worker surface in the target workspace
* launch the agent, wait for readiness, deliver the brief, and report key values

Higher-level skills own repository and review semantics:

* parse PR URLs
* identify the repository
* decide where the repository should live locally
* clone missing repositories
* fetch or check out PR branches
* construct review-specific briefs

`orca-spawn` never clones repositories, creates working directories, parses PR links, or fetches code.

## User Interface

Add optional target workspace inputs to the script and the `orca-spawn` skill wrapper.

```bash
scripts/orca-spawn.sh \
  --agent codex \
  --task "Review PR 123" \
  --brief-file /tmp/review.md \
  --workspace-name "aiml-services" \
  --cwd ~/projects/aiml-services
```

Workspace selectors:

* `--workspace-name <name>` selects or creates a workspace by exact human-readable title.
* `--workspace-id <uuid>` selects an existing workspace by stable cmux UUID.
* At most one workspace selector may be supplied.
* Positional refs such as `workspace:3` are rejected.

`--task` remains required. Workspace name answers where the worker appears; task answers what work the worker is doing and still drives the task id, brief filename, and tab name.

## Defaults

If no workspace selector is supplied, `orca-spawn` uses the calling workspace, matching existing behavior.

If no `--cwd` is supplied:

* calling workspace target: use the caller's current workspace `current_directory`
* existing named target workspace: use that workspace's `current_directory`
* newly created named target workspace: use the caller's current workspace `current_directory`
* workspace UUID target: use that workspace's `current_directory`

If `--cwd` is supplied, it is the worker working directory regardless of target workspace. If a named workspace must be created, that same `--cwd` is used as the new workspace's initial directory.

The resolved worker working directory must already exist before `orca-spawn` creates a workspace or surface.

## Workspace Resolution

Workspace lookup is scoped to the caller's current cmux window.

`--workspace-name <name>`:

* searches workspace `custom_title` and `title` by exact match
* uses the workspace if exactly one match exists
* creates a workspace named `<name>` in the caller's current window if no match exists
* fails as ambiguous if multiple exact matches exist

`--workspace-id <uuid>`:

* validates the value is a UUID
* searches workspaces in the caller's current cmux window
* uses the workspace if found
* fails if not found
* never creates a workspace

Created workspaces use `cmux new-workspace --name <name> --cwd <cwd> --window <caller-window> --focus false --id-format both` or the current cmux equivalent. `orca-spawn` then creates a separate worker surface inside that workspace. It does not reuse the initial terminal surface created by `new-workspace`.

Workspace creation and worker surface creation must not steal focus from the orchestrator.

## Output Contract

Add target workspace fields to the existing `key=value` output.

Success output includes:

```text
status=ok
task_id=<task-id>
workspace=<target-workspace-uuid>
workspace_name=<target-workspace-name-if-known>
workspace_created=true|false
surface=<worker-surface-uuid>
tab=<task-id>
cwd=<worker-working-directory>
brief=<relative-brief-path>
```

Failure output includes values already known. Workspace resolution and cwd validation failures happen before creating a worker surface. If workspace creation succeeds but later worker launch fails, the created workspace and worker surface are left open when applicable, and the error output includes the known workspace and surface ids.

## cmux Helper Changes

Extend the bundled `orca-cmux.sh` copies with workspace operations needed by spawn:

* list workspaces in the caller's current window as JSON
* create workspace by name, cwd, and caller window
* parse and return the created workspace UUID
* keep UUID-only validation for durable targets

If these helper changes are shared with `orca-fork` and `orca-msg`, update every copied helper and keep drift tests green. This feature itself applies only to `orca-spawn`; fork remains calling-workspace-only until a concrete fork use case needs target workspace routing.

## Conversational Wrapper

The `orca-spawn` skill should expose target workspace routing directly. It can gather:

* agent type
* task
* brief
* optional worker working directory
* optional workspace name or workspace id

The wrapper should not parse PR URLs or clone/fetch repositories. If the human asks for a PR-review workflow directly through `orca-spawn`, the wrapper should either gather a concrete local cwd and workspace selector or explain that PR URL resolution belongs in a higher-level review skill.

## Validation

Automated tests should cover:

* default behavior remains calling workspace plus caller current directory
* `--workspace-name` exact match uses the matching workspace
* missing `--workspace-name` creates a named workspace in the caller's current window
* duplicate exact workspace names fail as ambiguous
* `--workspace-id` uses a matching UUID in the caller's current window
* `--workspace-id` rejects positional refs and unknown UUIDs
* explicit `--cwd` is used as the worker working directory even when the target workspace has different directory metadata
* omitted `--cwd` defaults from the selected existing workspace
* omitted `--cwd` for a newly created workspace defaults from the caller's current workspace
* missing resolved cwd fails before creating a workspace or surface
* workspace creation uses `--focus false`
* worker surface creation still uses `--focus false`
* output includes `workspace`, `workspace_name`, and `workspace_created`
* full package tests still prove runtime files are skill-local and copied helpers stay in sync

Manual smoke test:

* Spawn into the calling workspace with no workspace selector.
* Spawn into an existing named repo workspace.
* Spawn into a missing named workspace and confirm cmux creates it without stealing focus.
* Spawn into an existing named workspace with a different explicit `--cwd` and confirm the worker starts in that cwd.
