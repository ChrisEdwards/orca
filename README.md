# Orca

Orca turns one Claude Code or Codex session into an orchestrator that spawns,
forks, messages, follows, and coordinates other AI coding agents, each running
in its own cmux tab. You stay in a single conversation and hand work out to
fresh agent instances working beside you.

## How it works

The session you talk to is the **orchestrator**. When you ask it to run work in
the background, it uses an Orca skill to open a new cmux tab, launch a
**worker** (a fresh Claude Code or Codex instance), bring it to its ready
state, and hand it a self-contained **brief**. Each worker lives in its own tab,
so you can watch it work while you keep talking to the orchestrator.

Workers start cold, with no memory of your conversation. The orchestrator builds
each brief from your request so a worker gets everything it needs to do the task
and to know when it is done. In a multi-step workflow, context travels between
steps through files and the git branch, never through shared memory.

By default a spawn is **fire and confirm**. The orchestrator verifies the worker
came up and received its brief, then stops. Ask it to follow the worker and it
switches to **fire and follow**, parking on cmux events until the worker
finishes its turn or pauses for input.

## Requirements

Orca drives cmux, so you need a few CLIs on your `PATH`.

- `cmux`, the terminal multiplexer Orca opens worker tabs in
- `jq`
- `claude` for Claude workers, `codex` for Codex workers, or both
- `python3`, plus a one-time `cmux hooks setup codex` for Codex, only if you
  want the orchestrator to follow workers to completion

Claude Code's completion hook is injected automatically by cmux, so following
Claude workers needs no extra setup.

## Install

### In Claude Code

Add the marketplace and install the plugin.

```text
/plugin marketplace add ChrisEdwards/orca
/plugin install orca@chrisedwards
```

From the terminal, the equivalent commands are the following.

```bash
claude plugin marketplace add ChrisEdwards/orca
claude plugin install orca@chrisedwards
```

For one session while developing locally, load the plugin directly.

```bash
claude --plugin-dir . --print "List available Orca skills."
```

### In Codex

Add this repository as a custom Codex plugin marketplace, then install the
plugin.

```bash
codex plugin marketplace add ChrisEdwards/orca --ref main
codex plugin add orca --marketplace chrisedwards
```

In the Codex app, add a plugin marketplace with source `ChrisEdwards/orca`, Git
ref `main`, and no sparse paths. Select the Chris Edwards marketplace, then
install the `orca` plugin.

## Using Orca

Once installed, you drive Orca in plain language from your orchestrator session.
Describe the work and Orca picks the matching skill, opens a tab, and drives the
worker there. You never call the bundled scripts yourself.

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

### Steer where a worker runs

By default a worker opens in your current cmux workspace and starts in your
current directory. You can steer all three choices in plain language.

- Say "spin up a Codex worker" or "use Claude" to pick the agent type. If you do
  not say, the orchestrator asks.
- Name a workspace, such as "in the aiml-services workspace", to place the
  worker in an existing tab group. Orca creates that workspace if it does not
  exist yet.
- Point at a repo, such as "in ~/projects/api", to set the worker's working
  directory.

### Auto mode and permission prompts

For Claude workers, Orca cycles the worker into auto mode after launch, where it
runs allowlisted operations without asking. Enterprise policy forbids launching
straight into auto mode, so Orca reaches it through a post-launch keystroke
sequence instead. If a worker still hits a permission, trust, or question
prompt, it pauses. When you are following that worker, the orchestrator reports
attention-needed so you can flip to its tab or answer through `orca-msg`. Orca
never answers permission or trust prompts for you.

### Follow and message workers

A plain spawn stops once the worker has its brief. Ask the orchestrator to
follow a worker and it waits for the first turn-end or attention pause, then
tells you which happened. You can nudge a running worker at any time by asking
the orchestrator to message it, either to answer a prompt it paused on or to add
context mid-task. Workers do not talk to each other, so the orchestrator relays
everything between them.

### Clean up when you are done

Orca does not tear workers down on its own. When you are finished, ask the
orchestrator to close them, or close the tabs yourself in cmux. A workflow such
as `orca-ship` closes the worker tabs it created for you and leaves any tab that
failed or paused open so you can inspect it. Orca never closes your orchestrator
tab.

### Where results and files live

A worker's results come back in its own tab and in what the orchestrator reports
to you. When a task needs a durable handoff or artifact, Orca writes it under
`${TMPDIR:-/tmp}/orca/<task-id>/`, outside your repo, so nothing leaks into a
commit. Internal brief files live under `.orca/` in the working directory, which
Orca keeps gitignored.

## Troubleshooting

- **`command not found: cmux` (or `jq`, `claude`, `codex`).** Install the
  missing CLI and confirm it is on the same `PATH` your orchestrator session
  sees. See Requirements.
- **The orchestrator cannot follow a Codex worker.** Run `cmux hooks setup
  codex` once. Claude workers need no setup because cmux injects their hook.
- **A worker looks stuck.** It is usually waiting on a permission or trust
  prompt. Flip to its tab, or ask the orchestrator to message it. Orca will not
  answer those prompts for you.
- **A spawn failed but left a tab open.** That is deliberate. Open the reported
  surface to see what happened rather than retrying blindly.

## Skills reference

Orca ships six skills. Claude Code namespaces them by plugin name, so after
install they are available as `/orca:orca-spawn`, `/orca:orca-fork`,
`/orca:orca-msg`, `/orca:orca-watch`, `/orca:orca-workflow`, and
`/orca:orca-ship`. You rarely name them directly. You describe the work and the
orchestrator picks one.

- `orca-spawn` launches one worker for one task, waits for it to reach its ready
  state, gives it a self-contained brief, and reports the cmux workspace,
  surface, and follow anchor.
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

## Development

### Local authoring

The canonical skills live under `skills/`. The project-skill symlinks under
`.agents/skills/` are kept only for repo-local Codex discovery while developing
Orca itself. Plugin installation uses `.codex-plugin/plugin.json`, which
packages every skill under `skills/`.

Each skill must remain self-contained. Runtime files used by a skill belong
inside that skill directory, such as `skills/orca-spawn/scripts/`.

### Development setup

After cloning, install the git hooks.

```bash
./scripts/install-hooks.sh
```

This symlinks `hooks/pre-push` into `.git/hooks/`. The hook warns you to bump
the plugin version in `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json`
when skill files change.

### Validate packaging

Run the package checks.

```bash
tests/test-orca-skill-package.sh
```

Validate the Codex plugin manifest.

```bash
python3 /Users/chrisedwards/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py .
```

Validate the Claude plugin and marketplace manifests.

```bash
claude plugin validate .claude-plugin/plugin.json --strict
claude plugin validate .claude-plugin/marketplace.json --strict
```

Smoke-test Codex marketplace discovery without touching your normal Codex
configuration.

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
