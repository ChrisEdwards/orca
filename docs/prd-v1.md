# Orca v1 PRD

## Problem Statement

Running multiple AI coding agents across a full SDLC workflow today requires manual session management. You open separate terminals, type prompts, watch for completion, copy context between sessions, and mentally track what step you're on. When different steps need different agents (Claude Code for branching and review, Codex for implementation), the coordination overhead compounds. There is no way to define a multi-step, multi-agent workflow and have it execute automatically while still being able to observe and intervene at any point.

## Solution

Orca is a set of Claude Code skills and shell scripts that let a Claude Code session orchestrate multiple AI coding agents in cmux panes. It provides two layers:

**Layer 1 (primitives):** Skills and scripts that spawn agents in cmux workspaces, send them prompts, read their terminal output, detect when they finish or need attention, and clean up when done. These primitives are agent-type-agnostic, working through a simple adapter interface.

**Layer 2 (workflows):** Skills that compose Layer 1 primitives into multi-step SDLC workflows where each step can use a different agent type. The orchestrator constructs a brief for each step, monitors execution, passes context between steps via handoff files, and reports status to the human.

The human interacts with orca by talking to their Claude Code session (the orchestrator). They can also jump into any worker's cmux pane to observe or interact directly. cmux was chosen over tmux for usability. The cmux interaction is abstracted behind a thin interface so tmux or other terminal multiplexers could be supported later.

## User Stories

1. As a developer, I want to tell my Claude Code session to run a workflow that creates a branch, implements a feature, reviews it, and opens a draft PR, so that I can focus on higher-level decisions while agents handle the mechanical work.

2. As a developer, I want each step of a workflow to use a different agent type (e.g., Claude Code for branching, Codex for implementation), so that I can use the best tool for each job.

3. As a developer, I want to see each agent working in its own cmux pane, so that I can observe progress in real time without switching contexts.

4. As a developer, I want to jump into any worker agent's cmux pane and type to it directly, so that I can intervene when something goes wrong or provide guidance.

5. As a developer, I want the orchestrator to detect when a worker agent finishes its turn, so that the workflow advances automatically without me watching for completion.

6. As a developer, I want the orchestrator to detect when a worker agent is stuck or needs my input, so that I can be notified rather than discovering it later.

6a. As a developer, I want common operations (file reads, git commands, builds, tests) pre-allowed via allowlists, so that worker agents can make progress on routine work without constant permission approvals.

7. As a developer, I want context passed between workflow steps via files in a `.orca/` directory that is gitignored, so that handoff artifacts don't pollute the target repo's commit history.

8. As a developer, I want to define workflows where the review step loops until only low-severity or note-level findings remain, so that code quality gates are enforced automatically.

9. As a developer, I want to add support for a new agent type by defining its launch command, busy/done detection patterns, and exit command, so that I'm not locked into Claude Code and Codex.

10. As a developer, I want the cmux interaction abstracted behind a simple interface (spawn, send, read, list, close), so that tmux or another multiplexer could be supported later without rewriting workflow logic.

11. As a developer, I want the orchestrator to construct a brief for each workflow step that includes what was done in previous steps and what to do next, so that each agent has the context it needs without receiving the full conversation history of prior agents.

12. As a developer, I want to use my existing pr-tools skills (like `create-stacked-branch`) as steps within an orca workflow, so that I don't have to rebuild what I already have.

13. As a developer, I want to run a single ad-hoc task (spawn one agent, give it a job, watch it) without defining a full workflow, so that orca is useful for simple cases too.

14. As a developer, I want the orchestrator to work within a single Claude Code session, so that I don't need to run a separate daemon or long-lived process.

15. As a developer, I want to refine and change my workflows over time by editing skills and scripts, so that orca adapts to my evolving process rather than locking me in.

16. As a developer, I want worker agents to share a git branch as their common workspace, so that each step picks up the code where the previous step left off.

17. As a developer, I want hook-based completion detection as the primary signal with screen-reading as a fallback, so that detection is reliable across different agent types.

18. As a developer, I want the orchestrator to clean up cmux workspaces when a workflow completes or a task is done, so that I don't accumulate stale terminals.

## Implementation Decisions

### Module 1: cmux Interface

A thin shell script providing five operations that abstract cmux's CLI. This is the layer that would be swapped for tmux support.

- **spawn**: Create a cmux workspace with a given working directory and optional title. Return the workspace and surface IDs.
- **send**: Send text to a surface, followed by enter.
- **read**: Read N lines of terminal content from a surface.
- **list**: List workspaces, optionally filtered by a naming prefix.
- **close**: Close a workspace and all its surfaces.

The script calls `cmux` CLI commands directly. No socket API usage in v1, CLI is simpler and sufficient.

An additional operation is needed beyond the five listed above:

- **send-key**: Send a special key sequence to a surface (e.g., `cmux send-key shift+tab`). Used for post-launch mode switching and other non-text input. cmux supports modifier syntax like `shift+tab`, `ctrl+c`, `alt+key`.

### Module 2: Agent Adapters

A configuration-driven definition of per-agent-type behavior. Each adapter specifies:

- **launch_command**: Template for starting the agent (e.g., `claude` for Claude Code, `codex` for Codex). No permission-bypass flags. Agents run with standard permission controls and rely on allowlists for common operations.
- **post_launch**: Optional. Sequence of keystrokes or commands to send after the agent is running. For Claude Code, this sends Shift+Tab three times to cycle into auto mode (enterprise policy prevents launching directly into auto mode). The orchestrator reads the screen and confirms "auto mode on" appears before proceeding.
- **busy_pattern**: Regex or string that appears in terminal output when the agent is actively working (e.g., "esc to interrupt").
- **done_pattern**: Regex or string that appears when the agent is idle and waiting for input (e.g., a prompt character).
- **exit_command**: How to gracefully exit the agent (e.g., `/exit` for Claude Code, `/quit` for Codex).
- **hook_setup**: Optional. How to install a turn-end hook that calls `cmux notify` on completion. For Claude Code, the orchestrator writes a `.claude/settings.local.json` with a `Stop` hook before launching the agent. For Codex, the `-c notify=` launch parameter is used. The hook file is cleaned up on teardown.

Adapters can be defined in a simple config file (shell-sourceable or JSON) or as variables in the adapter script. Adding a new agent type means adding a new adapter definition.

Initial adapters: Claude Code, Codex.

### Module 3: Agent Lifecycle Skill (Layer 1)

A Claude Code skill (`orca-agent`) that exposes agent management primitives to the orchestrator session.

- Spawn an agent of a given type in a cmux pane, pointed at a working directory, with an optional brief. Run the adapter's `post_launch` sequence (e.g., Shift+Tab cycling for Claude Code) and verify the expected mode before sending the brief.
- Monitor the agent by reading terminal output and/or listening for cmux notifications.
- Detect completion (hook-based notification primary, screen pattern matching fallback).
- Detect attention-needed (agent idle without signaling completion, or error patterns in output).
- Send follow-up text to the agent.
- Close the agent's workspace when done.

This skill calls Module 1 (cmux interface) and Module 2 (agent adapters) under the hood.

### Module 4: Workflow Runner Skill (Layer 2)

A Claude Code skill (`orca-workflow`) that runs multi-step workflows.

- Accepts a workflow definition: an ordered list of steps, each specifying an agent type and a brief template.
- Executes steps sequentially. For each step: construct the brief (incorporating context from previous steps), spawn the agent, wait for completion, collect results.
- Supports loops: the review-fix cycle repeats until a condition is met (e.g., review findings are all low/note severity).
- Reads handoff artifacts from `.orca/handoff/` to pass context between steps.
- The brief for each step is written to `.orca/briefs/` for debugging and auditability.
- Reports workflow status to the human (which step is running, what happened, what's next).

The workflow definition format will start simple (could be inline in the skill invocation or a YAML/JSON file) and evolve as usage patterns emerge.

### Module 5: `.orca/` State Directory

A gitignored directory in the target repo for orchestration artifacts.

- `.orca/briefs/` - Brief files sent to each agent per step.
- `.orca/handoff/` - Artifacts produced by one step for consumption by the next (review findings, implementation notes, PR URLs).
- `.orca/` is added to the target repo's `.gitignore` by the orchestrator if not already present.

### Context Passing Strategy

- The git branch is the shared workspace for code changes. All agents in a workflow operate on the same branch.
- Non-code context (review findings, metadata, step outputs) is passed via files in `.orca/handoff/`.
- Each agent receives a fresh brief constructed by the orchestrator. No conversation history is passed between agents.
- This follows Anthropic's own pattern for sub-agent context: externalized state, path-addressable, compaction-stable.

### Permission and Allowlist Strategy

Worker agents run without permission-bypass flags. To minimize interruptions, each agent type defines a recommended allowlist of common operations (file reads, git commands, build/test scripts) that gets configured in the target project's `.claude/settings.json` before the workflow starts. The orchestrator verifies the allowlist is in place during workflow setup.

Operations not covered by the allowlist will trigger permission prompts. The human can jump into the worker's cmux pane to approve or deny.

### Completion Detection Strategy

- **Primary: Hook-based.** Claude Code's `Stop` hook and Codex's `notify` parameter call `cmux notify` on turn end. The orchestrator subscribes to cmux notification events.
- **Fallback: Screen reading.** Read terminal content and match against the adapter's done/busy patterns. Used for agents that don't support hooks or as a safety net.
- cmux's event streaming eliminates the need for polling. The orchestrator subscribes to `notification.created` events.

## Testing Decisions

Good tests verify external behavior through the module's public interface, not implementation details. A test should break only when the module's behavior changes, not when its internals are refactored.

**Module 1 (cmux interface):** Testable in isolation. Tests can verify that the script produces correct cmux CLI commands for given inputs. Integration tests can verify spawn/send/read/close against a running cmux instance.

**Module 2 (agent adapters):** Primarily configuration. Validate that adapter definitions are complete (all required fields present) and that patterns are valid regex.

**Modules 3-4 (skills):** Difficult to test mechanically since they're Claude Code skills. Validated by running them against real cmux and real agents. Manual verification is the primary quality gate for v1.

## Out of Scope

- **Multi-task management.** v1 handles one workflow at a time. Tracking multiple concurrent workflows, task queues, and task identity systems are deferred.
- **State persistence across sessions.** When the orchestrator session ends, in-flight workflow state is lost. Durable state and session resume are deferred.
- **tmux support.** The cmux interface is designed to be swappable, but only the cmux implementation ships in v1.
- **Web UI or dashboard.** The human observes agents through cmux panes and interacts through their Claude Code session.
- **Agent-to-agent communication.** Agents don't talk to each other. The orchestrator mediates all context passing.
- **Automatic task creation from issues.** The human initiates workflows manually. Automatic intake from beads or other issue trackers is deferred.

## Further Notes

- The first concrete workflow to implement is: create branch (claude, using pr-tools) -> implement (codex) -> code review (claude, using goat-review-pr) -> address findings (codex) -> repeat review until clean -> create draft PR (claude).
- Orca is designed to be built bottom-up. Get the primitives working first (Module 1-2), then the lifecycle skill (Module 3), then the workflow runner (Module 4). Each layer is useful independently.
- The workflow definition format is intentionally left loose for v1. It will solidify based on actual usage patterns. Starting with inline definitions in skill invocations is fine.
- cmux v0.64.15+ is required. The project's cmux interface research is at `docs/research/cmux-interface.md`.
