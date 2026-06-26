---
name: orca-ship
description: Run one change from a fresh branch through implementation, review-until-clean, and a draft PR, across Claude Code and Codex workers in cmux tabs. Use when the user wants to hand off a whole task end to end (not just spawn one worker), ship a feature or fix as a reviewed draft PR, or run the orca branch -> implement -> review -> fix -> PR pipeline.
---

# orca-ship

Drive one task through the full delivery pipeline, one worker per step, passing context between steps through handoff files rather than conversation history.

orca-ship is a **workflow**: it defines the steps below, but it does not carry the machinery to run them. **For each step below, follow the `orca-workflow` skill's run-step procedure** (set up the handoff workspace with its init helper, then for each step construct the brief, spawn the worker with `orca-spawn`, follow with `orca-watch --after`, and read the handoff). The gate, the review-round cap, cleanup, and reporting all come from `orca-workflow`. This skill only supplies the pipeline and the rules specific to shipping.

The judgment parts — constructing each step's brief from the previous step's handoff, and deciding when review is clean — are yours, exactly as `orca-workflow` describes.

## The pipeline

1. **Branch** (claude) — create a fresh branch for the task.
2. **Implement** (codex) — implement the task on that branch.
3. **Review** (claude) — review the diff, record findings with severities.
4. **Gate** (you) — if findings are all low/note (or none), go to step 6. Otherwise step 5.
5. **Fix** (codex) — address the findings on the same branch, then go back to step 3.
6. **Draft PR** (claude) — open a draft PR for the branch.

Steps 3↔5 loop until the gate passes or the review-round cap is hit (the cap is `orca-workflow`'s default of 3).

## Prerequisites

- The `orca-workflow` skill (the runner this is a workflow for) and the primitives it composes (`orca-spawn`, `orca-watch`, `orca-msg`).
- Optional but preferred: the `pr-tools` skills (branch and PR creation) and `goat-review-pr` (review). If absent, briefs fall back to doing the equivalent directly with git and `gh`.

## The steps in detail

All workers share one repo working directory (`--cwd <repo>`) and one target workspace, because the branch is the shared workspace. Resolve the repo `cwd` and pick a `task` slug first, then:

- **Branch.** Brief a claude worker to create a fresh branch off the base for this task (prefer the `pr-tools` create-stacked-branch skill; otherwise `git switch -c`). Have it write the branch name to `handoff_dir/branch.txt` as its final action. Read it back.
- **Implement.** Brief a codex worker: it is on branch `{branch}`; implement `{task}`; keep changes scoped; write a short implementation summary to `handoff_dir/implementation.md` as its final action. The code lands on the branch.
- **Review.** Brief a claude worker to review the diff on `{branch}` against the base (prefer `goat-review-pr`; otherwise review `git diff <base>...{branch}` directly). Require it to write findings to `handoff_dir/review-{round}.json` as a JSON array of `{severity, file, line, title, detail}`, where `severity` is one of `critical|high|medium|low|note`, and an empty array if clean.
- **Gate.** Read `handoff_dir/review-{round}.json`. The gate **passes** when every finding is `low` or `note` (or the array is empty). Otherwise there is real work, go to Fix.
- **Fix.** Brief a codex worker: on branch `{branch}`, address the findings in `handoff_dir/review-{round}.json` (quote the high/medium/critical ones into the brief); write what changed to `handoff_dir/fix-{round}.md`. Then run Review again with `round + 1`.
- **Draft PR.** Brief a claude worker to open a **draft** PR for `{branch}` (prefer the `pr-tools` create-pr skill; otherwise `gh pr create --draft`). Have it write the PR URL to `handoff_dir/pr.txt`. Read it back and report it.

## Shipping boundaries

These are specific to orca-ship; honor them on top of `orca-workflow`'s general boundaries:

- orca-ship never force-pushes, merges, or marks a PR ready. It stops at a draft PR for human review.
- At the end, report the branch, the number of review rounds, and the draft PR URL, plus the `task_dir` path if the human wants to inspect handoffs.
