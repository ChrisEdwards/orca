# cmux Interface Reference for Agent Orchestration

Reference for building a firstmate-style orchestrator on cmux instead of tmux.
Covers every primitive needed to spawn, supervise, steer, and tear down autonomous coding agents.

## Architecture Overview

cmux is a native macOS terminal app built on libghostty. It replaces tmux's session/window/pane hierarchy with a four-level model:

```
Window  (a macOS window, can have multiple workspaces)
  └── Workspace  (equivalent to a tmux window, has a sidebar, name, working directory)
        └── Pane  (a layout container, can hold splits)
              └── Surface  (the actual terminal, browser, or markdown viewer)
```

For orchestration purposes, a **workspace** maps to a task (one agent per workspace), and a **surface** is the terminal you type into and read from.

All IDs come in two forms:
- **UUID** for exact targeting (e.g., `3B3F0D83-...`)
- **Ref** for scripting convenience (e.g., `workspace:1`, `surface:5`)

The environment variables `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID` are set inside every cmux terminal, providing implicit context when commands are run from within.

## Connection

cmux exposes a Unix socket at `/tmp/cmux.sock` (or `/tmp/cmux-debug.sock` for debug builds). Override with `CMUX_SOCKET_PATH`.

Socket access modes (set via `CMUX_SOCKET_MODE`):
- **default** restricts to processes spawned within cmux terminals
- **allowAll** permits any local process to connect

For an external orchestrator, use `allowAll` or run the orchestrator from within a cmux terminal.

---

## Core Operations

### 1. Create a Terminal for a Task

**CLI:**
```bash
cmux new-workspace --cwd /path/to/project --command "echo ready"
cmux new-workspace --cwd /path/to/project --env KEY=VALUE --description "fix-login-k3"
```

**Socket API:**
```json
{"id":"1","method":"workspace.create","params":{
  "cwd":"/path/to/project",
  "title":"fix-login-k3",
  "description":"Ship task for login fix"
}}
```

**Response fields you need:**
- `workspace_id`, `workspace_ref` for targeting the workspace
- The workspace auto-creates one pane with one terminal surface

To get the surface ID after creation, call `surface.list` or `surface.current` with the workspace ID.

**Splits** (if you need multiple terminals in one workspace):
```bash
cmux new-split --direction right --surface <id>
```

### 2. Send Text to an Agent

**CLI:**
```bash
cmux send --surface <id> --text "your command here"
cmux send-key --surface <id> --key enter
```

**Socket API:**
```json
{"id":"2","method":"surface.send_text","params":{"surface_id":"surface:5","text":"claude --dangerously-skip-permissions \"$(cat brief.md)\""}}
{"id":"3","method":"surface.send_key","params":{"surface_id":"surface:5","key":"Enter"}}
```

**Available key names:** `enter`, `tab`, `escape`, `backspace`, `delete`, `up`, `down`, `left`, `right`, `C-c` (Ctrl+C)

### 3. Read Terminal Content (capture-pane equivalent)

**CLI:**
```bash
cmux read-screen --surface <id> --lines 40
cmux read-screen --surface <id> --scrollback
cmux capture-pane --surface <id> --lines 40    # tmux-compat alias
```

**Socket API:**
```json
{"id":"4","method":"surface.read_text","params":{"surface_id":"surface:5","lines":40}}
{"id":"5","method":"surface.read_text","params":{"surface_id":"surface:5","scrollback":true}}
```

**Response:**
```json
{"id":"4","ok":true,"result":{"text":"...terminal content...","lines":40}}
```

### 4. List Workspaces and Surfaces

**CLI:**
```bash
cmux list-workspaces --json
cmux list-pane-surfaces --pane <id> --json
```

**Socket API:**
```json
{"id":"6","method":"workspace.list","params":{}}
{"id":"7","method":"surface.list","params":{"workspace_id":"workspace:3"}}
```

**Workspace list returns** (key fields):
- `id`, `ref`, `title`, `custom_title`
- `selected` (boolean, is it focused)
- `current_directory` (string or null)
- `listening_ports` (integer array)
- `latest_conversation_message`, `latest_submitted_message` (agent integration)

**Surface list returns** (key fields):
- `id`, `ref`, `kind` (`terminal`, `browser`, `markdown`)
- `pane_id`, `pane_ref`
- `pid`, `cwd`, `shell`, `user`, `host` (for terminals)
- `focused`, `selected`, `index`

### 5. Query Context and State

**CLI:**
```bash
cmux identify --json           # focused window, workspace, surface
cmux current-workspace --json  # current workspace details
cmux tree --json               # full hierarchy tree
```

**Socket API:**
```json
{"id":"8","method":"workspace.current","params":{}}
```

The workspace summary includes `current_directory`, which gives you the equivalent of tmux's `#{pane_current_path}`. The surface list gives you `cwd` per terminal.

### 6. Close a Workspace (kill-window equivalent)

**CLI:**
```bash
cmux close-workspace --workspace <id>
cmux workspace close --workspace <id>
```

**Socket API:**
```json
{"id":"9","method":"workspace.close","params":{"workspace_id":"workspace:3"}}
```

### 7. Rename a Workspace

**CLI:**
```bash
cmux rename-workspace --workspace <id> --new-name "fm-fix-login-k3"
```

**Socket API:**
```json
{"id":"10","method":"workspace.rename","params":{"workspace_id":"workspace:3","title":"fm-fix-login-k3"}}
```

---

## Supervision and Observation

### Event Streaming

cmux has a reconnectable event stream that replaces the need for a polling watcher entirely. This is a major advantage over tmux.

**CLI:**
```bash
cmux events --name surface.input_sent --name notification.created --reconnect
cmux events --category workspace --reconnect
cmux events --after <seq> --cursor-file /path/to/cursor  # resume from last seen
```

**Socket API:**
```json
{"id":"11","method":"events.stream","params":{
  "names":["surface.input_sent","notification.created","workspace.closed"],
  "categories":["surface","notification"],
  "after_seq": 42
}}
```

After the initial `ack` frame, the socket streams newline-delimited JSON events:

```json
{
  "type":"event",
  "seq":43,
  "name":"notification.created",
  "workspace_id":"UUID",
  "surface_id":"UUID",
  "payload":{...}
}
```

**Event categories relevant to orchestration:**

| Category | Events | Use |
|----------|--------|-----|
| workspace | `workspace.created`, `.selected`, `.closed`, `.renamed` | Track task lifecycle |
| surface | `surface.created`, `.closed`, `.focused`, `.input_sent`, `.key_sent` | Detect activity, input events |
| notification | `notification.created`, `.read`, `.removed` | Agent needs-attention signals |
| sidebar | `sidebar.metadata.updated`, `.log.appended` | Status and progress tracking |
| pane | `pane.created`, `.closed`, `.focused` | Layout changes |

**Heartbeats** arrive every 15 seconds by default, giving you a built-in liveness signal.

**Reconnection** with `--after <seq>` or `--cursor-file` replays missed events, so you never lose a signal even if the orchestrator restarts.

### Notifications

Agents can signal the orchestrator through terminal notification sequences (OSC 9, OSC 99, OSC 777). cmux captures these and exposes them through the notification API.

**List notifications:**
```bash
cmux list-notifications --json --workspace <id>
```

**Create a notification programmatically:**
```bash
cmux notify --title "Build Complete" --body "All tests passed" --surface <id>
```

**Socket API:**
```json
{"id":"12","method":"notification.list","params":{"workspace_id":"workspace:3"}}
{"id":"13","method":"notification.create_for_surface","params":{
  "surface_id":"surface:5",
  "title":"Task done",
  "body":"PR ready for review"
}}
```

Notification hooks in `~/.config/cmux/cmux.json` can filter or transform notifications before display:
```json
{
  "notifications": {
    "hooks": [{"id":"filter","command":"your-filter-script","timeoutSeconds":20}]
  }
}
```

### Sidebar Status and Progress

cmux has a built-in sidebar that can show status pills, progress bars, and log entries per workspace. Agents or the orchestrator can write to these for visual monitoring.

**Status pills:**
```bash
cmux set-status task "building" --workspace <id>
cmux clear-status task --workspace <id>
```

**Progress bars:**
```bash
cmux set-progress build --percentage 0.75 --label "Running tests" --workspace <id>
```

**Log entries:**
```bash
cmux log build "Tests passed (42/42)" --workspace <id>
cmux list-log --json --workspace <id>
```

**Dump all sidebar state:**
```bash
cmux sidebar-state --json
```

### Surface Health

```bash
cmux surface-health --surface <id> --json
```

Returns TTY state and rendering stats for a terminal surface.

---

## Agent Hook Integration

cmux has built-in hook support for coding agents. Install hooks that fire on agent lifecycle events.

```bash
cmux hooks setup claude    # install Claude Code hooks
cmux hooks setup codex     # install Codex hooks
cmux hooks setup           # auto-detect and install
```

These hooks integrate with cmux's session resume system, notification routing, and sidebar metadata.

### Session Resume

When an agent exits, its session can be preserved for resume:

```bash
cmux surface resume set --kind claude --checkpoint <session-id> --shell "claude --continue <session-id>"
cmux surface resume get --surface <id> --json
cmux surface resume clear --surface <id>
```

---

## Browser Automation

cmux includes a scriptable browser with a Playwright-style API. Useful for verifying UI changes, taking screenshots, or driving web-based tools.

**Open a browser surface:**
```bash
cmux browser open --url https://localhost:3000
```

**Navigate and interact:**
```bash
cmux browser goto --surface <id> --url https://localhost:3000/login
cmux browser fill --surface <id> --selector "#username" --text "admin"
cmux browser click --surface <id> --selector "button[type=submit]"
cmux browser screenshot --surface <id> --path /tmp/screenshot.png
```

**Read page content:**
```bash
cmux browser get --surface <id> --selector "h1" --property text
cmux browser snapshot --surface <id>     # full DOM snapshot
cmux browser eval --surface <id> --code "document.title"
```

**Wait for conditions:**
```bash
cmux browser wait --surface <id> --selector ".success" --timeout 10000
cmux browser wait --surface <id> --url "*/dashboard" --timeout 5000
```

---

## tmux-to-cmux Migration Cheat Sheet

| tmux | cmux CLI | cmux Socket Method |
|------|----------|--------------------|
| `tmux new-session -d -s name` | `cmux new-window` | `window.create` |
| `tmux new-window -d -t ses -n name -c dir` | `cmux new-workspace --cwd dir` | `workspace.create` |
| `tmux send-keys -t win -l "text" Enter` | `cmux send --surface <id> --text "text"` + `cmux send-key --surface <id> --key enter` | `surface.send_text` + `surface.send_key` |
| `tmux send-keys -t win Escape` | `cmux send-key --surface <id> --key escape` | `surface.send_key` |
| `tmux capture-pane -p -t win -S -40` | `cmux read-screen --surface <id> --lines 40` | `surface.read_text` |
| `tmux list-windows -a -F ...` | `cmux list-workspaces --json` | `workspace.list` |
| `tmux kill-window -t win` | `cmux close-workspace --workspace <id>` | `workspace.close` |
| `tmux display-message -p -t win '#{pane_current_path}'` | `cmux identify --json` or check `cwd` from `surface.list` | `surface.list` / `workspace.current` |
| `tmux has-session -t name` | `cmux list-windows --json` (check if exists) | `window.list` |
| `tmux list-windows ... \| grep ':fm-'` | `cmux list-workspaces --json` (filter by title) | `workspace.list` |

### Key Differences

**Addressing.** tmux uses `session:window` string names. cmux uses UUIDs or `kind:N` refs. Your orchestrator needs a mapping from task IDs to workspace/surface IDs (store in meta files, similar to firstmate's `state/<id>.meta`).

**Event-driven vs polling.** tmux has no event stream, so firstmate polls with a watcher. cmux has `events.stream` with replay, so you can subscribe to events and react immediately. This eliminates the need for a polling watcher loop, staleness hashing, and signal coalescing. A single long-lived `cmux events` process replaces the entire `fm-watch.sh` script.

**Naming.** tmux lets you name windows at creation (`-n fm-xyz`). cmux creates workspaces with auto-generated names, then you rename them. Or use the `title` param on creation. Filter by title to find task workspaces.

**No sessions.** cmux windows are top-level, not grouped into sessions. If you need grouping, use workspace groups (`cmux workspace group`).

**Built-in sidebar.** tmux has no sidebar. cmux's sidebar shows status, progress, logs, git branch, and ports per workspace. Your orchestrator can write task status directly to the sidebar instead of maintaining separate state files.

---

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `CMUX_SOCKET_PATH` | Override socket path |
| `CMUX_SOCKET_PASSWORD` | Socket authentication |
| `CMUX_SOCKET_MODE` | Access mode (`default`, `allowAll`) |
| `CMUX_WORKSPACE_ID` | Set inside cmux terminals, implicit workspace context |
| `CMUX_SURFACE_ID` | Set inside cmux terminals, implicit surface context |
| `CMUX_TAB_ID` | Set inside cmux terminals, implicit tab context |

---

## Design Notes for an Orchestrator

**Spawn pattern.** Create a workspace per task with `workspace.create`, capture the returned workspace and surface IDs, store them in meta, send the agent launch command via `surface.send_text` + `surface.send_key enter`.

**Supervision pattern.** Replace the polling watcher with a single `cmux events --reconnect --cursor-file state/.cmux-cursor` process. Filter for `notification.created`, `surface.closed`, and `sidebar.metadata.updated`. React to events instead of polling for file changes and pane hashes.

**Turn-end detection.** Instead of per-harness turn-end hooks that touch files, agents could emit an OSC notification sequence on turn end. cmux captures it as a notification event. Alternatively, keep the file-based hooks and watch for file changes as a fallback.

**Staleness detection.** `surface.read_text` with `--lines 40` replaces pane hashing. You can still hash the output to detect idle agents. But the event stream may make this unnecessary, since `surface.input_sent` and `surface.key_sent` events tell you when the agent last typed something.

**Status display.** Use `set-status`, `set-progress`, and `log` to show task state in the sidebar. This replaces status files for visual monitoring, though you may still want files for durability across restarts.

**Teardown.** `workspace.close` kills the workspace and all its surfaces. Clean up meta files and state afterward.

**Reconnection.** The event stream's `--cursor-file` and `--after <seq>` params give you lossless replay after an orchestrator restart, similar to firstmate's durable wake queue but built into the platform.
