# Orca

Orca packages skills for spawning, forking, messaging, following, and
orchestrating Claude Code or Codex agent instances in cmux tabs.

The plugin includes six skills:

- `orca-spawn` launches one worker for one task, waits for the worker to reach
  its ready state, gives it a self-contained brief, and reports the cmux
  workspace, surface, and follow anchor.
- `orca-fork` forks an existing Codex or Claude Code conversation into a new
  cmux tab, preserving conversation history, and reports the resulting surface.
- `orca-msg` delivers a follow-up message to an existing agent instance in a
  cmux surface, using either a pasted `surface_id` or a human target
  description that resolves to one surface.
- `orca-watch` waits for an already-spawned Claude Code or Codex worker to
  finish its turn or pause for attention, using the cmux event stream for
  fire-and-follow orchestration.
- `orca-workflow` runs multi-step, multi-agent workflows through fresh workers
  in cmux tabs, passing context between steps through handoff files.
- `orca-ship` drives one change from a fresh branch through implementation,
  review-until-clean, and a draft PR across Claude Code and Codex workers.

## Using Orca

Once the plugin is installed (see below), you drive Orca by talking to the
Claude Code or Codex session that has it loaded. That session becomes the
**orchestrator**. You describe what you want in plain language, it picks the
matching skill, opens a new cmux tab, and drives the worker there. You never
call the bundled scripts yourself.

Orca runs inside cmux, so you need `cmux`, `jq`, and the `claude` or `codex`
CLI on your `PATH`. Each worker lands in its own tab in your current cmux
workspace, so you can watch it work while you keep talking to the orchestrator.

**Spin up a worker for one task** (`orca-spawn`)

```text
Use orca to spin up a Claude agent to add retry logic to the HTTP client
in ~/projects/api, then run the tests.
```

The orchestrator opens a new tab, launches Claude Code, brings it to auto mode,
hands it a self-contained brief built from your request, and confirms it came
up. Ask for a Codex worker instead and it launches Codex.

**Fork the current conversation** (`orca-fork`)

```text
Fork this conversation into a new tab so a copy can try the risky refactor
while we keep talking here.
```

Unlike a spawn, a fork carries the full conversation history into the new tab
instead of starting from a fresh brief.

**Message a running worker** (`orca-msg`)

```text
Tell the Codex worker in the payments workspace to also bump the changelog.
```

You can name the target in plain language or paste a cmux surface, and the
orchestrator resolves it to the right surface before delivering the message.

**Follow a worker to completion** (`orca-watch`)

```text
Spin up a Claude agent to migrate the config loader, then watch it and ping me
when it finishes or needs input.
```

The orchestrator parks on the cmux event stream instead of polling the screen,
so it catches turn-end and attention-needed even for a fast worker.

**Ship a change end to end** (`orca-ship`)

```text
Use orca to ship the rate-limiter fix as a reviewed draft PR.
```

This runs the whole pipeline across Claude and Codex workers, create a branch,
implement, review until clean, fix any findings, then open a draft PR. For a
custom multi-step pipeline, describe the steps and Orca runs them the same way
through `orca-workflow`.

## Install In Codex

Add this repository as a custom Codex plugin marketplace:

```bash
codex plugin marketplace add ChrisEdwards/orca --ref main
```

Then install the plugin:

```bash
codex plugin add orca --marketplace chrisedwards
```

In the Codex app, add a plugin marketplace with source
`ChrisEdwards/orca`, Git ref `main`, and no sparse paths. Select the
Chris Edwards marketplace, then install the `orca` plugin.

## Local Authoring

The canonical skills live under `skills/`. The project-skill symlinks under
`.agents/skills/` are kept only for repo-local Codex discovery while developing
Orca itself. Plugin installation uses `.codex-plugin/plugin.json`, which
packages every skill under `skills/`.

Each skill must remain self-contained. Runtime files used by a skill belong
inside that skill directory, such as `skills/orca-spawn/scripts/`.

## Development Setup

After cloning, install the git hooks:

```bash
./scripts/install-hooks.sh
```

This symlinks `hooks/pre-push` into `.git/hooks/`. The hook warns you to bump
the plugin version in `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json`
when skill files change.

## Validate Packaging

Run the package checks:

```bash
tests/test-orca-skill-package.sh
```

Validate the Codex plugin manifest:

```bash
python3 /Users/chrisedwards/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py .
```

Smoke-test Codex marketplace discovery without touching your normal Codex
configuration:

```bash
tmp_home=$(mktemp -d)
HOME="$tmp_home" codex plugin marketplace add "$PWD" --json
HOME="$tmp_home" codex plugin list --available --json
HOME="$tmp_home" codex plugin add orca --marketplace chrisedwards --json
rm -rf "$tmp_home"
```

If the install step fails with `fatal: could not read Username for
'https://github.com': terminal prompts disabled`, the marketplace is visible
but the GitHub source cannot be cloned non-interactively. Authenticate GitHub
access for `https://github.com/ChrisEdwards/orca.git` or make the repository
public, then rerun `codex plugin add orca --marketplace chrisedwards --json`.

## Install In Claude Code

Add this repository as a Claude Code plugin marketplace:

```text
/plugin marketplace add ChrisEdwards/orca
```

Then install the plugin:

```text
/plugin install orca@chrisedwards
```

From the terminal, the equivalent commands are:

```bash
claude plugin marketplace add ChrisEdwards/orca
claude plugin install orca@chrisedwards
```

For one session while developing locally, load the plugin directly:

```bash
claude --plugin-dir . --print "List available Orca skills."
```

Claude Code namespaces plugin skills by plugin name. The current skills are
available as `/orca:orca-spawn`, `/orca:orca-fork`, `/orca:orca-msg`,
`/orca:orca-watch`, `/orca:orca-workflow`, and `/orca:orca-ship` after the
plugin is installed or loaded.

Validate the Claude plugin and marketplace manifests:

```bash
claude plugin validate .claude-plugin/plugin.json --strict
claude plugin validate .claude-plugin/marketplace.json --strict
```
