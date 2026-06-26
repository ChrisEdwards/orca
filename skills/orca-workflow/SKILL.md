---
name: orca-workflow
description: Run a multi-step, multi-agent workflow whose steps are defined by another skill (or stated inline), driving each step through a fresh worker in a cmux tab and passing context via handoff files. Use when a workflow skill (e.g. orca-ship) tells you to "run these steps with orca-workflow", or when you have an ordered set of English steps each naming an agent and need the shared run-step, gate/loop, and cleanup machinery to execute them.
---

# orca-workflow

The generic runner for Orca's multi-step, multi-agent workflows. A **workflow skill** supplies the *what* (an ordered list of steps, each naming an agent and a goal, written in English). orca-workflow supplies the *how* (set up handoff state, run each step as a fresh worker, pass context through files, loop a review-style gate, clean up).

You compose the two in your own head. You load the workflow skill, read its steps into context, then follow this procedure to execute them. orca-workflow never reads the workflow skill's files; you carry the steps over. This is the same composition orca-ship already uses for `orca-spawn`, `orca-watch`, and `orca-msg`: one skill invokes another, no cross-skill file paths.

**The mechanical parts are primitives you already have. The judgment parts — constructing each step's brief from the previous step's handoff, and deciding when a gate is satisfied — are yours. Do not try to push that judgment into a script.**

## Prerequisites

- `cmux`, `jq`, `claude`, and `codex` on `PATH`.
- The `orca-spawn`, `orca-watch`, and `orca-msg` skills (the primitives this composes).
- Whatever the workflow's individual steps prefer (e.g. `pr-tools`, `goat-review-pr`). If a preferred skill is absent, the step's brief falls back to doing the equivalent directly with git and `gh`.

## Set up the run

Create the task id and handoff workspace once, up front:

```bash
scripts/orca-workflow-init.sh --task "<task title>"
```

It prints `task_id`, `task_dir`, `handoff_dir`, and `artifacts_dir` under `${TMPDIR:-/tmp}/orca/`. Hold these. Every step writes its result into `handoff_dir`; the git branch in the repo carries the code. Nothing under the repo is used for handoff, so nothing leaks into a commit.

Most workflows run all workers against one **repo working directory** (`--cwd <repo>`) and one **target workspace**, because the branch is the shared workspace. Resolve those once and reuse them for every step.

## Run-step: how to execute one step

Every step is the same fire-and-follow shape, composed from the primitives:

1. **Construct the brief.** Write a self-contained brief for the step into the handoff dir, e.g. `handoff_dir/brief-<step>.md`. The brief carries: the task, what the previous step produced (quote or point at the relevant handoff file), exactly what to do this step, and where to write the result. Workers start cold, so never assume they saw a prior step.
2. **Spawn the worker** with `orca-spawn`:
   ```bash
   orca-spawn.sh --agent <claude|codex> --task "<step> <task_id>" \
     --brief-file handoff_dir/brief-<step>.md --cwd <repo> [workspace selector]
   ```
   Capture the reported `surface` and `after_seq`.
3. **Follow to completion** with `orca-watch`, passing the anchor so a fast worker is never missed:
   ```bash
   orca-watch.sh --surface <surface> --agent <agent> --after <after_seq> --timeout <secs>
   ```
   - `event: turn_end` — the step finished. Read its handoff file and continue.
   - `event: attention` — the worker is waiting on a permission, question, or notification. Flip the human to that tab, or use `orca-msg` to answer or nudge, then watch again.
   - `event: timeout` — the step is taking longer than expected. Tell the human and decide whether to keep waiting (watch again) or intervene.
   - For **codex** steps spawning into a cold repo, the worker can register its surface later than the default 30s resolve window (mode cycle + trust prompt + brief submission delay first-event time). Set `ORCA_WATCH_RESOLVE_SECS=90` for those follows. If watch still exits 2 on resolve, the Stop may already be buffered — re-run watch with the **same `--after`** and it replays the missed `turn_end` rather than losing it.
4. **Read the handoff.** Pull the step's result from `handoff_dir` and use it to build the next brief.

Each step gets a fresh worker. Context flows through handoff files and the branch, not through worker memory. Use `orca-msg` only to unstick a worker that paused, not to hand it the next step.

## Handoff dialect

Workflow skills write their steps against these conventions, so every workflow speaks the same language and you can run any of them with this procedure:

- **Handoff files** live at `handoff_dir/<name>` (for example `branch.txt`, `implementation.md`, `review-<round>.json`, `pr.txt`). A step's brief names the exact file it must produce.
- **Final action.** Each step's brief ends by telling the worker that writing its handoff file is its *final action*, so the file exists by the time `turn_end` fires.
- **References** like `{branch}` and `{round}` in a workflow's step text are placeholders you resolve from earlier handoffs and the loop state, not literals to pass through.

## Gate and loop

Some workflows include a **gate**: after a step (typically a review), read its handoff result and decide whether the workflow may advance or must loop back through a fix step. The workflow skill states the pass condition (e.g. "pass when every finding is `low` or `note`, or the array is empty"). You apply it.

When a gate fails, run the workflow's fix step, then re-run the gated step with the round counter incremented (`review-1.json`, `review-2.json`, ...). **Cap the loop at 3 failed rounds** unless the workflow states otherwise. If the cap is hit, stop, summarize the outstanding items from the latest handoff, and hand control to the human rather than forcing the workflow to a conclusion over unresolved problems.

## Report back

Narrate the workflow as it runs: which step is executing, the worker surface, and each step's handoff result. At the end, give the human the workflow's final outputs (whatever the last steps produced) plus the `task_dir` path if they want to inspect handoffs.

## Cleanup

When the workflow finishes or the human stops it, close the worker tabs you opened (`orca-cmux.sh close --surface <uuid>` from the `orca-spawn` skill), unless the human wants to inspect a worker. Leave a worker tab open if its step failed or paused, so the human can see what happened. The handoff dir under `${TMPDIR}` is disposable and may be left for inspection.

## Boundaries

- One workflow at a time. No tracking of concurrent runs, no task queue.
- No state persistence across sessions. If this session ends mid-run, in-flight state is lost; the branch and handoff files remain for a manual restart.
- Workers do not talk to each other. You mediate every handoff.
- orca-workflow does not bypass permissions. If a step worker hits a permission or trust prompt, it pauses (`attention`); answer via `orca-msg` or hand the human the tab.
- Step-level boundaries (what a workflow must never do, e.g. never force-push or mark a PR ready) belong to the workflow skill, and you honor them.

## Authoring a new workflow

A workflow is just a thin skill: its own `name`/`description` frontmatter (so it is discoverable on its own), a short statement of the pipeline, the steps in English (each naming its agent and its handoff file), and a closing line that says **"for each step below, follow the orca-workflow skill's run-step procedure."** See `orca-ship` for the reference example. Keep all the machinery here; keep only the steps and any step-specific boundaries in the workflow skill.
