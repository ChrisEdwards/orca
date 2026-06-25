# Orca

Orca packages skills for spawning, forking, and messaging Claude Code or Codex
agent instances in cmux tabs.

The plugin includes three skills:

- `orca-spawn` launches one worker for one task, waits for the worker to reach
  its ready state, gives it a self-contained brief, and reports the resulting
  cmux surface.
- `orca-fork` forks an existing Codex or Claude Code conversation into a new
  cmux tab, preserving conversation history, and reports the resulting surface.
- `orca-msg` delivers a follow-up message to an existing agent instance in a
  cmux surface, using either a pasted `surface_id` or a human target
  description that resolves to one surface.

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
available as `/orca:orca-spawn`, `/orca:orca-fork`, and `/orca:orca-msg` after
the plugin is installed or loaded.

Validate the Claude plugin and marketplace manifests:

```bash
claude plugin validate .claude-plugin/plugin.json --strict
claude plugin validate .claude-plugin/marketplace.json --strict
```
