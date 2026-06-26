---
name: orca-ship
description: Run one change from a fresh branch through implementation, review-until-clean, and a draft PR, across Claude Code and Codex workers in cmux tabs. Use when the user wants to hand off a whole task end to end (not just spawn one worker), ship a feature or fix as a reviewed draft PR, or run the orca branch -> implement -> review -> fix -> PR pipeline.
---

# orca-ship

Drive one task through the full delivery pipeline, one worker per step, passing context between steps through handoff files rather than conversation history.

Unlike `orca-spawn` (one worker, one task), **orca-ship is a multi-step, multi-agent workflow and you are the runner.** The mechanical parts are primitives you already have; the judgment parts — constructing each step's brief from the previous step's handoff, and deciding when review is clean — are yours. Do not try to push that judgment into a script.

This is the one hardcoded pipeline. A general workflow runner is separate.

## The pipeline

1. **Branch** (claude) — create a fresh branch for the task.
2. **Implement** (codex) — implement the task on that branch.
3. **Review** (claude) — review the diff, record findings with severities.
4. **Gate** (you) — if findings are all low/note (or none), go to step 6. Otherwise step 5.
5. **Fix** (codex) — address the findings on the same branch, then go back to step 3.
6. **Draft PR** (claude) — open a draft PR for the branch.

Steps 3↔5 loop until the gate passes or the review-round cap is hit.

## Prerequisites

- `cmux`, `jq`, `claude`, and `codex` on `PATH`.
- The `orca-spawn`, `orca-watch`, and `orca-msg` skills (the primitives this composes).
- Optional but preferred: the `pr-tools` skills (branch and PR creation) and `goat-review-pr` (review). If absent, briefs fall back to doing the equivalent directly with git and `gh`.

## Set up the run

Create the task id and handoff workspace once, up front:

```bash
scripts/orca-ship-init.sh --task "<task title>"
```

It prints `task_id`, `task_dir`, `handoff_dir`, and `artifacts_dir` under `${TMPDIR:-/tmp}/orca/`. Hold these. Every step writes its result into `handoff_dir`; the git branch in the repo carries the code. Nothing under the repo is used for handoff, so nothing leaks into a commit.

All workers share one **repo working directory** (`--cwd <repo>`) and one **target workspace**, because the branch is the shared workspace. Resolve those once and reuse them for every step.

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
4. **Read the handoff.** Pull the step's result from `handoff_dir` and use it to build the next brief.

Each step gets a fresh worker. Context flows through handoff files and the branch, not through worker memory. Use `orca-msg` only to unstick a worker that paused, not to hand it the next step.

## The steps in detail

Resolve the repo `cwd` and pick a `task` slug first, then:

- **Branch.** Brief a claude worker to create a fresh branch off the base for this task (prefer the `pr-tools` create-stacked-branch skill; otherwise `git switch -c`). Have it write the branch name to `handoff_dir/branch.txt` as its final action. Read it back.
- **Implement.** Brief a codex worker: it is on branch `<branch>`; implement `<task>`; keep changes scoped; write a short implementation summary to `handoff_dir/implementation.md` as its final action. The code lands on the branch.
- **Review.** Brief a claude worker to review the diff on `<branch>` against the base (prefer `goat-review-pr`; otherwise review `git diff <base>...<branch>` directly). Require it to write findings to `handoff_dir/review-<round>.json` as a JSON array of `{severity, file, line, title, detail}`, where `severity` is one of `critical|high|medium|low|note`, and an empty array if clean.
- **Gate.** Read `handoff_dir/review-<round>.json`. The gate **passes** when every finding is `low` or `note` (or the array is empty). Otherwise there is real work, go to Fix.
- **Fix.** Brief a codex worker: on branch `<branch>`, address the findings in `handoff_dir/review-<round>.json` (quote the high/medium/critical ones into the brief); write what changed to `handoff_dir/fix-<round>.md`. Then run Review again with `round + 1`.
- **Draft PR.** Brief a claude worker to open a **draft** PR for `<branch>` (prefer the `pr-tools` create-pr skill; otherwise `gh pr create --draft`). Have it write the PR URL to `handoff_dir/pr.txt`. Read it back and report it.

## Review-round cap

Stop the review↔fix loop after **3 rounds** that still fail the gate. Do not loop forever. If the cap is hit, stop, summarize the outstanding findings from the latest `review-<round>.json`, and hand control to the human rather than opening a PR over unresolved high-severity findings.

## Report back

Narrate the pipeline as it runs: which step is executing, the worker surface, and each step's handoff result (branch name, review round counts and severities, the final PR URL). At the end, give the human the branch, the number of review rounds, and the draft PR URL, plus the `task_dir` path if they want to inspect handoffs.

## Cleanup

When the pipeline finishes or the human stops it, close the worker tabs you opened (`orca-cmux.sh close --surface <uuid>` from the `orca-spawn` skill), unless the human wants to inspect a worker. Leave a worker tab open if its step failed or paused, so the human can see what happened. The handoff dir under `${TMPDIR}` is disposable and may be left for inspection.

## Boundaries

- One workflow at a time. No tracking of concurrent pipelines, no task queue.
- No state persistence across sessions. If this session ends mid-pipeline, in-flight state is lost; the branch and handoff files remain for a manual restart.
- Workers do not talk to each other. You mediate every handoff.
- orca-ship never force-pushes, merges, or marks a PR ready. It stops at a draft PR for human review.
- If a step worker hits a permission or trust prompt, it pauses (`attention`); answer via `orca-msg` or hand the human the tab. orca-ship does not bypass permissions.
