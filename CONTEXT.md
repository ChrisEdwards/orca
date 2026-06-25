# Orca

Orca orchestrates multiple AI coding agents across an SDLC workflow from a single Claude Code session, spawning each agent in its own cmux pane and passing context between steps through files.

## Roles

**Orchestrator**
The single Claude Code session the human talks to. It spawns workers, hands them briefs, watches for completion, and reports status. It is not itself a worker.
_Avoid_ controller, master, supervisor, driver

**Worker**
A task-bearing agent instance launched by the orchestrator in its own tab to carry out one task.
_Avoid_ sub-agent, child, bare "agent" when an instance is meant

## Agents

**Agent type**
A kind of AI coding agent orca can launch, such as Claude Code or Codex. Distinct from a worker, which is a running instance of an agent type.
_Avoid_ "agent" on its own, which blurs into worker

**Agent instance**
A live running instance of an agent type in an Orca-managed surface. An agent instance may simply expose a forked conversation, or it may become a worker when assigned a task.

**Adapter**
The configuration describing how to launch, drive, detect, and exit one agent type. Adding support for a new agent type means adding an adapter.
_Avoid_ plugin, driver, connector

**Auto mode**
Claude Code's state in which it runs allowlisted operations without prompting for permission. Reached only through the post-launch sequence, since enterprise policy forbids launching directly into it.

**Post-launch sequence**
Keystrokes or commands orca sends a worker right after starting it, to put it in the right state. The Shift+Tab cycling that moves Claude Code into auto mode is one example.

## cmux units

**Workspace**
cmux's top-level container of panes and surfaces, with one working directory and a sidebar. Orca adds each worker as a tab in the calling workspace rather than spinning up a workspace per worker.
_Avoid_ window, session

**Calling workspace**
The cmux workspace the orchestrator was fired from. New worker tabs are added here, so invoking orca from a different workspace places its workers there instead. There is no fixed, dedicated orca workspace.

**Surface**
A single terminal (or markdown or browser view) inside a pane. A worker occupies one terminal surface. This is the thing orca writes to and reads from.

**Surface descriptor**
A human description used to identify an existing surface when the surface UUID is not supplied directly.
_Avoid_ pane descriptor, target pane

**Tab**
The human-facing label for a surface within a pane. Adding a worker means adding a tab to the shared workspace, and "spawn a pane" in casual terms means this.

## Work

**Conversation**
A provider-owned transcript and history for one AI coding agent interaction. Codex may call it a thread and Claude Code may call it a session; Orca uses conversation when the concept must work across agent types.
_Avoid_ thread or session in Orca-level language unless referring to a provider-specific identifier

**Task**
A single piece of work handed to one worker in its own tab. The standalone, ad-hoc case is a task on its own.
_Avoid_ job, ticket

**Brief**
The self-contained task description the orchestrator constructs and hands a worker. Built fresh per task, carrying no prior conversation history.
_Avoid_ prompt, instructions, message

**Step**
One task that forms a single stage of a workflow, pairing an agent type with a brief.

**Workflow**
An ordered sequence of steps the orchestrator runs, where each step may use a different agent type. A Layer 2 concept, out of scope for the first deliverable.

**Handoff**
Non-code context one step produces for the next, passed through files rather than conversation. The git branch carries code changes, handoff files carry everything else.
_Avoid_ context passing, state transfer

## Detection

**Completion detection**
Recognizing that a worker has finished its turn and is waiting. Hook-based notification is the primary signal, screen reading the fallback. Also called turn-end detection.

**Attention-needed**
A worker that has gone idle without signaling completion, or is showing an error, and needs human input before it can make progress.

## Operations

**Spawn**
Orca's central action, create a worker tab, launch the agent, bring it to the right ready state, and hand it the brief. The whole sequence, not just the tab creation.

**Fire and confirm**
The spawn behavior where orca verifies the worker came up and reached the right mode, then delivers the brief and stops. It does not monitor the worker afterward. Contrast with later monitoring behavior that watches a worker through to completion.

**Fork**
Create a new conversation by branching an existing conversation, then open that branch in its own tab. Unlike spawn, a fork preserves prior conversation history instead of starting from a fresh brief.

**Message**
Deliver follow-up text to an existing agent instance in its current surface. Unlike spawn or fork, message does not create a new surface or conversation.
_Avoid_ prompt, brief
