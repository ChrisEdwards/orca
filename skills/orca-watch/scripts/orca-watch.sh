#!/usr/bin/env bash
#
# orca-watch - block until one worker signals turn-end or attention-needed.
#
# This is the detection primitive that turns fire-and-confirm into
# fire-and-follow. cmux forwards agent lifecycle hooks onto a reconnectable
# event stream as `agent.hook.<HookName>` frames. Turn-end is `agent.hook.Stop`
# for both Claude and Codex. Attention is Notification / PermissionRequest /
# AskUserQuestion. See docs/research/cmux-completion-detection.md.
#
# Those frames carry `surface_id: null`, so a worker is identified by its
# session, not its surface, on the wire. We resolve the worker's surface UUID
# (the durable handle from spawn) to a sessionId via the cmux session store,
# then filter the stream for that session.
#
# Usage:
#   orca-watch --surface <uuid> --agent <claude|codex> [--after <seq>] [--timeout <secs>]
#
#   --surface   worker surface UUID captured at spawn
#   --agent     agent type, selects the session store and event prefix
#   --after     event seq to resume from (the spawn-time latest_seq) so a fast
#               worker that finishes before we subscribe is never missed
#   --timeout   seconds to wait before giving up (0 = wait forever, default 0)
#
# On the first matching transition it prints one JSON line and exits 0:
#   {"event":"turn_end"|"attention","hook":"Stop",...}
# Exit 3 on timeout, 4 if the stream closes first, 2 on usage/resolve error.
set -euo pipefail

die() { printf 'orca-watch: %s\n' "$1" >&2; exit 2; }

surface=""; agent=""; after=""; timeout="0"
while (($#)); do
  case "$1" in
    --surface) [[ $# -ge 2 ]] || die "--surface needs a value"; surface=$2; shift 2 ;;
    --agent)   [[ $# -ge 2 ]] || die "--agent needs a value";   agent=$2;   shift 2 ;;
    --after)   [[ $# -ge 2 ]] || die "--after needs a value";   after=$2;   shift 2 ;;
    --timeout) [[ $# -ge 2 ]] || die "--timeout needs a value"; timeout=$2; shift 2 ;;
    *) die "unexpected argument: $1" ;;
  esac
done

[[ -n "$surface" ]] || die "usage: orca-watch --surface <uuid> --agent <claude|codex> [--after <seq>] [--timeout <secs>]"
[[ "$agent" == claude || "$agent" == codex ]] || die "--agent must be claude or codex, got: ${agent:-<empty>}"
[[ "$timeout" =~ ^[0-9]+$ ]] || die "--timeout must be a non-negative integer, got: $timeout"
[[ -z "$after" || "$after" =~ ^[0-9]+$ ]] || die "--after must be a non-negative integer, got: $after"

store="$HOME/.cmuxterm/${agent}-hook-sessions.json"
[[ -f "$store" ]] || die "no session store for $agent at $store (is the cmux $agent hook integration installed?)"

# Resolve surface UUID -> sessionId via the store, retrying because the hook may
# still be landing for a freshly spawned worker. Claude registers by ready-time,
# but Codex can take many seconds longer to associate its surface, so the window
# is generous (override with ORCA_WATCH_RESOLVE_SECS). Resolving late is safe:
# the event subscription uses --after, so a Stop that fired during resolution is
# replayed rather than lost.
resolve_secs=${ORCA_WATCH_RESOLVE_SECS:-30}
[[ "$resolve_secs" =~ ^[0-9]+$ ]] || die "ORCA_WATCH_RESOLVE_SECS must be a non-negative integer, got: $resolve_secs"
session=""
resolve_deadline=$(( $(date +%s) + resolve_secs ))
while :; do
  session=$(python3 - "$store" "$surface" <<'PY'
import json, sys
store, surface = sys.argv[1], sys.argv[2]
target = surface.lower()
try:
    data = json.load(open(store))
except Exception:
    sys.exit(0)

# Two store shapes seen in the wild:
#  - Claude: activeSessionsBySurface[surface] = {sessionId: ...}
#  - Codex:  sessions[sessionId] = {surfaceId: ..., sessionId: ...}
entry = (data.get("activeSessionsBySurface") or {}).get(surface)
if entry and entry.get("sessionId"):
    print(entry["sessionId"]); sys.exit(0)

for sid, rec in (data.get("sessions") or {}).items():
    if not isinstance(rec, dict):
        continue
    if str(rec.get("surfaceId") or "").lower() == target:
        print(rec.get("sessionId") or sid); sys.exit(0)
PY
)
  [[ -n "$session" ]] && break
  (( $(date +%s) >= resolve_deadline )) && break
  sleep 0.5
done
[[ -n "$session" ]] || die "could not resolve a session for surface $surface in $store within ${resolve_secs}s (worker may not have started, or hooks are off)"

target="${agent}-${session}"

# Stream the relevant lifecycle hooks and return on the first frame for our
# session. Python owns the cmux subprocess so timeout and teardown are clean and
# a SIGPIPE on the producer can never mask a successful match.
ORCA_TARGET="$target" ORCA_SURFACE="$surface" ORCA_AGENT="$agent" \
ORCA_CMUX_BIN="${CMUX_BIN:-cmux}" \
ORCA_AFTER="$after" ORCA_TIMEOUT="$timeout" python3 <<'PY'
import json, os, select, subprocess, sys, time

target  = os.environ["ORCA_TARGET"]
surface = os.environ["ORCA_SURFACE"]
agent   = os.environ["ORCA_AGENT"]
cmux_bin = os.environ.get("ORCA_CMUX_BIN") or "cmux"
after   = os.environ.get("ORCA_AFTER") or ""
timeout = int(os.environ.get("ORCA_TIMEOUT") or "0")

TURN_END  = {"Stop"}
ATTENTION = {"Notification", "PermissionRequest", "AskUserQuestion"}

cmd = [cmux_bin, "events", "--no-heartbeat",
       "--name", "agent.hook.Stop",
       "--name", "agent.hook.Notification",
       "--name", "agent.hook.PermissionRequest",
       "--name", "agent.hook.AskUserQuestion"]
if after:
    cmd += ["--after", after]

proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True)
deadline = time.time() + timeout if timeout > 0 else None

def finish(obj, code, kill=True):
    if kill and proc.poll() is None:
        proc.terminate()
    print(json.dumps(obj))
    sys.exit(code)

try:
    while True:
        remaining = None
        if deadline is not None:
            remaining = deadline - time.time()
            if remaining <= 0:
                finish({"event": "timeout", "surface": surface, "agent": agent}, 3)
        ready, _, _ = select.select([proc.stdout], [], [], remaining)
        if not ready:
            continue  # woke for a deadline check
        line = proc.stdout.readline()
        if line == "":
            finish({"event": "stream_closed", "surface": surface, "agent": agent}, 4, kill=False)
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("type") != "event":
            continue
        name = ev.get("name", "")
        if not name.startswith("agent.hook."):
            continue
        hook = name[len("agent.hook."):]
        payload = ev.get("payload") or {}
        if payload.get("session_id") != target:
            continue
        kind = "turn_end" if hook in TURN_END else ("attention" if hook in ATTENTION else None)
        if kind is None:
            continue
        finish({
            "event": kind,
            "hook": hook,
            "agent": agent,
            "surface": surface,
            "session_id": target,
            "cwd": payload.get("cwd"),
            "workspace_id": payload.get("workspace_id"),
            "seq": ev.get("seq"),
        }, 0)
finally:
    if proc.poll() is None:
        proc.terminate()
PY
