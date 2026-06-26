#!/usr/bin/env bash
# Integration tests for skills/orca-msg/scripts/orca-msg.sh.
#
# These tests run the real message script and cmux seam on top of a fake cmux.
# They verify target resolution, readiness checks, and exact message delivery
# without launching real agents.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MSG="$REPO_ROOT/skills/orca-msg/scripts/orca-msg.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

CALLS="$TMP/calls.log"
FAKE="$TMP/cmux"

SFC_CLAUDE="5DE180A2-FEB8-4733-B750-2681FA2C2982"
SFC_CODEX="6EE280A2-FEB8-4733-B750-2681FA2C2983"
SFC_OTHER="7FF280A2-FEB8-4733-B750-2681FA2C2984"
SFC_ORIGIN="8AA280A2-FEB8-4733-B750-2681FA2C2985"
WS_AIML="90D8E74A-E0EE-4FCB-8F7C-105574F46F01"
WS_OTHER="80D8E74A-E0EE-4FCB-8F7C-105574F46F02"

cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
sub=${1:-}; shift || true
{ printf '%s' "$sub"; for a in "$@"; do printf '\t%s' "$a"; done; printf '\n'; } >> "$FAKE_CALLS"

arg_after() {
  local want=$1 prev=""
  shift
  for a in "$@"; do
    if [[ "$prev" == "$want" ]]; then printf '%s\n' "$a"; return 0; fi
    prev=$a
  done
  return 1
}

case "$sub" in
  identify)
    printf '{ "caller": { "workspace_id": "%s", "surface_id": "%s" } }\n' "$FAKE_WS_AIML" "$FAKE_SFC_ORIGIN"
    ;;
  list-workspaces)
    cat <<JSON
{ "workspaces": [
  { "id": "$FAKE_WS_AIML", "ref": "workspace:9", "title": "aiml-services", "custom_title": "aiml-services", "current_directory": "/work/aiml-services" },
  { "id": "$FAKE_WS_OTHER", "ref": "workspace:10", "title": "docs", "custom_title": "docs", "current_directory": "/work/docs" }
] }
JSON
    ;;
  list-pane-surfaces)
    ws=$(arg_after --workspace "$@")
    if [[ "$ws" == "$FAKE_WS_AIML" ]]; then
      case "${FAKE_SCENARIO:-}" in
        descriptor-ambiguous)
          cat <<JSON
{ "surfaces": [
  { "id": "$FAKE_SFC_CLAUDE", "ref": "surface:35", "kind": "terminal", "pane_id": "PANE-1", "pane_ref": "pane:16", "cwd": "/work/aiml-services", "shell": "zsh", "title": "claude-a" },
  { "id": "$FAKE_SFC_OTHER", "ref": "surface:36", "kind": "terminal", "pane_id": "PANE-1", "pane_ref": "pane:16", "cwd": "/work/aiml-services", "shell": "zsh", "title": "claude-b" }
] }
JSON
          ;;
        *)
          cat <<JSON
{ "surfaces": [
  { "id": "$FAKE_SFC_CLAUDE", "ref": "surface:35", "kind": "terminal", "pane_id": "PANE-1", "pane_ref": "pane:16", "cwd": "/work/aiml-services", "shell": "zsh", "title": "claude-main" },
  { "id": "$FAKE_SFC_CODEX", "ref": "surface:36", "kind": "terminal", "pane_id": "PANE-1", "pane_ref": "pane:16", "cwd": "/work/aiml-services", "shell": "zsh", "title": "codex-main" }
] }
JSON
          ;;
      esac
    else
      cat <<JSON
{ "surfaces": [
  { "id": "$FAKE_SFC_OTHER", "ref": "surface:40", "kind": "terminal", "pane_id": "PANE-2", "pane_ref": "pane:20", "cwd": "/work/docs", "shell": "zsh", "title": "claude-docs" }
] }
JSON
    fi
    ;;
  read-screen)
    sfc=$(arg_after --surface "$@")
    case "$sfc" in
      "$FAKE_SFC_CLAUDE")
        case "${FAKE_SCENARIO:-}" in
          claude-blocked)
            printf 'Do you want to allow this command?\n'
            printf '1. Yes\n2. No\n'
            ;;
          stale-claude-shell)
            printf 'Previous Claude turn finished here.\n'
            printf '  ? for shortcuts                                   ← for agents\n'
            printf '\n'
            printf 'chrisedwards@host orca-73y-msg-readiness %% \n'
            ;;
          stale-claude-starship-shell)
            printf 'Previous Claude turn finished here.\n'
            printf '  ? for shortcuts                                   ← for agents\n'
            printf '\n'
            printf '%s\n' '~/project on  main ❯ '
            ;;
          stale-claude-user-path-shell)
            printf 'Previous Claude turn finished here.\n'
            printf '  ? for shortcuts                                   ← for agents\n'
            printf '\n'
            printf '%s\n' 'user ~/project> '
            ;;
          stale-marker-high-scrollback)
            printf 'Old Claude turn finished here.\n'
            printf '  ? for shortcuts                                   ← for agents\n'
            printf 'Build step one completed.\n'
            printf 'Build step two completed.\n'
            printf 'Build step three completed.\n'
            printf 'Build step four completed.\n'
            printf 'Build step five completed.\n'
            printf '%s\n' '~/project on  main ❯ '
            ;;
          claude-ready-question-prose)
            printf 'Should I continue with the next step? Want me to continue?\n'
            printf '  ? for shortcuts                                   ← for agents\n'
            ;;
          claude-busy)
            printf '  ? for shortcuts                                   ← for agents\n'
            printf 'Running command: bash tests/test-orca-msg.sh\n'
            printf 'esc to interrupt\n'
            ;;
          permission-prompt)
            printf 'Claude needs your approval before using this tool.\n'
            printf 'Allow tool execution?\n'
            printf '1. Allow\n2. Deny\n'
            ;;
          unknown-ui)
            printf 'vim README.md\n'
            printf '-- INSERT --\n'
            ;;
          *)
            printf '  ? for shortcuts                                   ← for agents\n'
            ;;
        esac
        ;;
      "$FAKE_SFC_CODEX")
        case "${FAKE_SCENARIO:-}" in
          codex-blocked)
            printf '  Do you trust the contents of this directory?\n'
            printf '› 1. Yes, continue\n'
            printf '  2. No, quit\n'
            ;;
          stale-codex-shell)
            printf '› Implement {feature}\n'
            printf 'gpt-5.5 high · /work/aiml-services\n'
            printf '\n'
            printf '/work/aiml-services $ \n'
            ;;
          stale-codex-themed-shell)
            printf '› Implement {feature}\n'
            printf 'gpt-5.5 high · /work/aiml-services\n'
            printf '\n'
            printf '%s\n' '~/project on  main ❯ '
            ;;
          *)
            printf '› Implement {feature}\n'
            printf 'gpt-5.5 high · /work/aiml-services\n'
            ;;
        esac
        ;;
      "$FAKE_SFC_OTHER")
        printf '  ? for shortcuts                                   ← for agents\n'
        ;;
      *)
        printf 'unknown surface\n'
        ;;
    esac
    ;;
  send|send-key)
    echo "OK"
    ;;
  *)
    echo "OK"
    ;;
esac
EOF
chmod +x "$FAKE"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }
ok() { local desc=$1; shift; if "$@"; then pass; else fail "$desc"; fi; }
no() { local desc=$1; shift; if "$@"; then fail "$desc"; else pass; fi; }

LAST_OUT=""
LAST_ERR=""
LAST_RC=0
SCENARIO=happy

msg_run() {
  : > "$CALLS"
  local errfile="$TMP/stderr"
  LAST_OUT=$(TMPDIR="${TMPDIR:-}" CMUX_BIN="$FAKE" FAKE_CALLS="$CALLS" FAKE_SCENARIO="$SCENARIO" \
    FAKE_WS_AIML="$WS_AIML" FAKE_WS_OTHER="$WS_OTHER" \
    FAKE_SFC_CLAUDE="$SFC_CLAUDE" FAKE_SFC_CODEX="$SFC_CODEX" FAKE_SFC_OTHER="$SFC_OTHER" \
    FAKE_SFC_ORIGIN="$SFC_ORIGIN" \
    ORCA_READY_POLLS=2 ORCA_POLL_INTERVAL=0 \
    "$MSG" "$@" 2>"$errfile")
  LAST_RC=$?
  LAST_ERR=$(cat "$errfile")
}

field() { grep -E "^$1=" <<<"$LAST_OUT" | head -1 | cut -d= -f2-; }
message_sent() { awk 'BEGIN{p=0} /^message_sent=/{sub(/^message_sent=/,""); p=1} p{print}' <<<"$LAST_OUT"; }
calls_have_line() { grep -qxF -- "$1" "$CALLS"; }
called_subcommand() { grep -qE "^$1(\t|$)" "$CALLS"; }
mentions() { grep -qiF -- "$1" <<<"$LAST_OUT"$'\n'"$LAST_ERR"; }
rc_is() { [[ "$LAST_RC" -eq "$1" ]]; }
rc_not() { [[ "$LAST_RC" -ne "$1" ]]; }
eq() { [[ "$1" == "$2" ]]; }
has_orca_msg_temp() { find "$1" -maxdepth 1 -name 'orca-msg-*' -print -quit | grep -q .; }

with_footer() {
  printf '%s\n[From the agent at surface %s. To reply, use the orca-msg skill targeting that surface if needed.]' "$1" "$SFC_ORIGIN"
}

# === Pasted copy-ids block extracts only surface_id ========================
IDS="$TMP/ids.txt"
cat > "$IDS" <<EOF
workspace_ref=workspace:9
workspace_id=$WS_AIML
pane_ref=pane:16
pane_id=E21F277D-EB24-4137-BE29-A42A7C7C654E
surface_ref=surface:35
surface_id=$SFC_CLAUDE
EOF
SCENARIO=happy
msg_run --target-file "$IDS" --message "Please summarize status."

ok  "copy ids: exits 0"                rc_is 0
ok  "copy ids: status=ok"              eq "$(field status)" ok
ok  "copy ids: targets surface_id"     eq "$(field surface)" "$SFC_CLAUDE"
ok  "copy ids: detects claude"         eq "$(field agent)" claude
ok  "copy ids: sends exact message" \
      calls_have_line $'send\t--surface\t'"$SFC_CLAUDE"$'\t'"$(with_footer "Please summarize status.")"
ok  "copy ids: reports origin surface" mentions "$SFC_ORIGIN"
ok  "copy ids: presses enter" \
      calls_have_line $'send-key\t--surface\t'"$SFC_CLAUDE"$'\tenter'

# === Positional refs alone are not accepted as durable targets =============
REFS="$TMP/refs.txt"
cat > "$REFS" <<'EOF'
surface_ref=surface:35
pane_ref=pane:16
EOF
msg_run --target-file "$REFS" --message "Should not send."
ok  "refs only: exits non-zero"         rc_not 0
ok  "refs only: needs clarification"    eq "$(field status)" needs_clarification
no  "refs only: does not send"          called_subcommand send

# === Descriptor resolution succeeds for one matching surface ===============
SCENARIO=happy
DESCRIPTOR_TMPDIR="$TMP/descriptor-success-tmp"
mkdir "$DESCRIPTOR_TMPDIR"
TMPDIR="$DESCRIPTOR_TMPDIR" msg_run --target "the Claude agent in the aiml-services workspace" --message "Review the decision."

ok  "descriptor: exits 0"               rc_is 0
ok  "descriptor: status=ok"             eq "$(field status)" ok
ok  "descriptor: selected claude"        eq "$(field surface)" "$SFC_CLAUDE"
ok  "descriptor: listed workspaces"      called_subcommand list-workspaces
ok  "descriptor: listed surfaces"        called_subcommand list-pane-surfaces
ok  "descriptor: sends message" \
      calls_have_line $'send\t--surface\t'"$SFC_CLAUDE"$'\t'"$(with_footer "Review the decision.")"
no  "descriptor: cleans temp files"      has_orca_msg_temp "$DESCRIPTOR_TMPDIR"

# === Ambiguous descriptor reports candidates and does not send =============
SCENARIO=descriptor-ambiguous
AMBIGUOUS_TMPDIR="$TMP/descriptor-ambiguous-tmp"
mkdir "$AMBIGUOUS_TMPDIR"
TMPDIR="$AMBIGUOUS_TMPDIR" msg_run --target "the Claude agent in the aiml-services workspace" --message "Pick one?"

ok  "ambiguous: exits non-zero"         rc_not 0
ok  "ambiguous: status"                 eq "$(field status)" needs_clarification
ok  "ambiguous: includes first candidate" mentions "$SFC_CLAUDE"
ok  "ambiguous: includes second candidate" mentions "$SFC_OTHER"
no  "ambiguous: does not send"          called_subcommand send
no  "ambiguous: cleans temp files"       has_orca_msg_temp "$AMBIGUOUS_TMPDIR"

# === Codex readiness can be inferred from screen text ======================
SCENARIO=happy
msg_run --surface "$SFC_CODEX" --message "Proceed with tests."

ok  "codex infer: exits 0"              rc_is 0
ok  "codex infer: agent=codex"          eq "$(field agent)" codex
ok  "codex infer: sends message" \
      calls_have_line $'send\t--surface\t'"$SFC_CODEX"$'\t'"$(with_footer "Proceed with tests.")"

# === Blocked states are refused, not answered ==============================
SCENARIO=codex-blocked
msg_run --surface "$SFC_CODEX" --agent codex --message "Do not type into prompt."

ok  "blocked: exits non-zero"           rc_not 0
ok  "blocked: status=error"             eq "$(field status)" error
ok  "blocked: explains not ready"       mentions "not ready"
no  "blocked: does not send text"       called_subcommand send
no  "blocked: does not press enter"     called_subcommand send-key

# === Stale prompt markers in scrollback are refused ========================
SCENARIO=stale-claude-shell
msg_run --surface "$SFC_CLAUDE" --agent claude --message "Do not type into shell."

ok  "stale claude shell: exits non-zero" rc_not 0
ok  "stale claude shell: status=error"   eq "$(field status)" error
ok  "stale claude shell: explains not ready" mentions "not ready"
no  "stale claude shell: does not send text" called_subcommand send
no  "stale claude shell: does not press enter" called_subcommand send-key

SCENARIO=stale-claude-starship-shell
msg_run --surface "$SFC_CLAUDE" --agent claude --message "Do not type into themed shell."

ok  "stale claude starship shell: exits non-zero" rc_not 0
ok  "stale claude starship shell: status=error"   eq "$(field status)" error
ok  "stale claude starship shell: explains not ready" mentions "not ready"
no  "stale claude starship shell: does not send text" called_subcommand send
no  "stale claude starship shell: does not press enter" called_subcommand send-key

SCENARIO=stale-claude-user-path-shell
msg_run --surface "$SFC_CLAUDE" --agent claude --message "Do not type into user path shell."

ok  "stale claude user path shell: exits non-zero" rc_not 0
ok  "stale claude user path shell: status=error"   eq "$(field status)" error
ok  "stale claude user path shell: explains not ready" mentions "not ready"
no  "stale claude user path shell: does not send text" called_subcommand send
no  "stale claude user path shell: does not press enter" called_subcommand send-key

SCENARIO=stale-marker-high-scrollback
msg_run --surface "$SFC_CLAUDE" --agent claude --message "Do not type into high scrollback shell."

ok  "high scrollback stale marker: exits non-zero" rc_not 0
ok  "high scrollback stale marker: status=error"   eq "$(field status)" error
ok  "high scrollback stale marker: explains not ready" mentions "not ready"
no  "high scrollback stale marker: does not send text" called_subcommand send
no  "high scrollback stale marker: does not press enter" called_subcommand send-key

SCENARIO=stale-codex-shell
msg_run --surface "$SFC_CODEX" --agent codex --message "Do not type into shell."

ok  "stale codex shell: exits non-zero" rc_not 0
ok  "stale codex shell: status=error"   eq "$(field status)" error
ok  "stale codex shell: explains not ready" mentions "not ready"
no  "stale codex shell: does not send text" called_subcommand send
no  "stale codex shell: does not press enter" called_subcommand send-key

SCENARIO=stale-codex-themed-shell
msg_run --surface "$SFC_CODEX" --agent codex --message "Do not type into themed shell."

ok  "stale codex themed shell: exits non-zero" rc_not 0
ok  "stale codex themed shell: status=error"   eq "$(field status)" error
ok  "stale codex themed shell: explains not ready" mentions "not ready"
no  "stale codex themed shell: does not send text" called_subcommand send
no  "stale codex themed shell: does not press enter" called_subcommand send-key

# === Ready agents are not refused for ordinary response prose ==============
SCENARIO=claude-ready-question-prose
msg_run --surface "$SFC_CLAUDE" --agent claude --message "Continue after question prose."

ok  "ready question prose: exits 0"      rc_is 0
ok  "ready question prose: status=ok"    eq "$(field status)" ok
ok  "ready question prose: sends message" \
      calls_have_line $'send\t--surface\t'"$SFC_CLAUDE"$'\t'"$(with_footer "Continue after question prose.")"
ok  "ready question prose: presses enter" \
      calls_have_line $'send-key\t--surface\t'"$SFC_CLAUDE"$'\tenter'

# === Busy, permission, and unknown UI states are refused ===================
SCENARIO=claude-busy
msg_run --surface "$SFC_CLAUDE" --agent claude --message "Do not interrupt work."

ok  "busy: exits non-zero"              rc_not 0
ok  "busy: status=error"                eq "$(field status)" error
ok  "busy: explains not ready"          mentions "not ready"
no  "busy: does not send text"          called_subcommand send
no  "busy: does not press enter"        called_subcommand send-key

SCENARIO=permission-prompt
msg_run --surface "$SFC_CLAUDE" --agent claude --message "Do not approve."

ok  "permission: exits non-zero"        rc_not 0
ok  "permission: status=error"          eq "$(field status)" error
ok  "permission: explains blocked"      mentions "blocked on a prompt"
no  "permission: does not send text"    called_subcommand send
no  "permission: does not press enter"  called_subcommand send-key

SCENARIO=unknown-ui
msg_run --surface "$SFC_CLAUDE" --agent claude --message "Do not type into unknown UI."

ok  "unknown ui: exits non-zero"        rc_not 0
ok  "unknown ui: status=error"          eq "$(field status)" error
ok  "unknown ui: explains not ready"    mentions "not ready"
no  "unknown ui: does not send text"    called_subcommand send
no  "unknown ui: does not press enter"  called_subcommand send-key

# === Direct messages stay one cmux argv element ============================
SCENARIO=happy
TEXT=$'Line one with spaces\nLine two with `backticks` and $vars'
msg_run --surface "$SFC_CLAUDE" --agent claude --message "$TEXT"
ok  "direct multiline: exits 0"          rc_is 0
ok  "direct multiline: preserves argv" \
      calls_have_line $'send\t--surface\t'"$SFC_CLAUDE"$'\t'"$(with_footer "$TEXT")"

# === Message-file flow sends an absolute path and leaves the file ==========
MESSAGE_FILE="$TMP/message.md"
printf 'Long context\n' > "$MESSAGE_FILE"
SCENARIO=happy
msg_run --surface "$SFC_CLAUDE" --agent claude --message-file "$MESSAGE_FILE"

sent=$(message_sent)
ok  "message file: exits 0"              rc_is 0
ok  "message file: reports absolute path" eq "$(field message_file)" "$MESSAGE_FILE"
ok  "message file: sends read instruction" calls_have_line $'send\t--surface\t'"$SFC_CLAUDE"$'\t'"$sent"
ok  "message file: file remains"         test -f "$MESSAGE_FILE"
ok  "message file: instruction has path"  mentions "$MESSAGE_FILE"
ok  "message file: instruction has origin" mentions "$SFC_ORIGIN"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
