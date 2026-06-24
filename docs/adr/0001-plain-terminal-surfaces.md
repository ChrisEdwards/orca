# Workers launch in plain terminal surfaces, not native agentSession surfaces

Orca spawns each worker by creating a cmux terminal surface and typing the agent's launch command, rather than using `cmux new-surface --type agent-session --provider <p>`.

Verified on cmux 0.64.16, an agentSession surface has type `agentSession` (a React-rendered view) and rejects both `read-screen` and `send`/`send-key` with "Surface is not a terminal". It also renders blank to the user in our test. Orca's control model depends on typing into the surface and reading it back, the launch command, the Shift+Tab mode cycle, the brief, and the `auto mode on` confirmation, so a terminal surface is the only viable host.

cmux still attaches its agent integration (lifecycle state, hooks, AI-generated title) to a terminal running `claude` through its Claude wrapper, so nothing is lost by avoiding the native surface.

## Considered options

- **Native agentSession surface** rejected, no terminal I/O and renders blank.
- **Plain terminal with typed launch** chosen.

## Consequences

The seam for a future tmux backend stays clean, because orca only ever needs terminal send and read primitives.
