#!/usr/bin/env bash
#
# Shared launch-to-ready helper for Orca skill scripts.
#
# Spawning a worker and forking a conversation share the same mechanical core:
# type the agent's launch command into a fresh terminal surface, then poll the
# screen until the agent is ready, dismissing the trust and upgrade prompts that
# can appear first. Claude additionally cycles Shift+Tab into auto mode. This
# helper owns that whole sequence so orca-spawn and orca-fork do not each carry
# their own copy of the poll loop.
#
# This file is intentionally duplicated into each self-contained skill package.
# Keep copies byte-for-byte identical and protected by package tests.
#
# Caller contract:
#   - $ORCA_CMUX points at the bundled orca-cmux helper.
#   - orca-trust-prompt.sh and orca-upgrade-prompt.sh are already sourced.
#   - ORCA_READY_POLLS / ORCA_POLL_INTERVAL set the readiness budget; the mode
#     step uses ORCA_MODE_INTERVAL (falling back to ORCA_POLL_INTERVAL).
#   - On failure the functions set ORCA_LAUNCH_REASON and return non-zero; the
#     caller maps that to its own fail path so it can leave the tab open.

ORCA_LAUNCH_REASON=""

# orca_is_ready <provider> <ready_marker> <screen>
# Codex shows its ready marker before the input box is usable, so it also
# requires the status separator; Claude's marker alone is sufficient.
orca_is_ready() {
  local provider=$1 ready_marker=$2 screen=$3
  case "$provider" in
    codex)
      grep -qF -- "$ready_marker" <<<"$screen" && grep -qF -- " · " <<<"$screen"
      ;;
    claude)
      grep -qF -- "$ready_marker" <<<"$screen"
      ;;
    *)
      return 1
      ;;
  esac
}

# orca_launch_to_ready <surface> <launch_cmd> <provider> <ready_marker>
# Sends the launch command, then polls until the agent is ready, dismissing the
# trust and upgrade prompts along the way. Returns 0 when ready; on failure sets
# ORCA_LAUNCH_REASON and returns non-zero.
orca_launch_to_ready() {
  local surface=$1 launch=$2 provider=$3 ready_marker=$4
  ORCA_LAUNCH_REASON=""

  if ! "$ORCA_CMUX" send --surface "$surface" "$launch" >/dev/null; then
    ORCA_LAUNCH_REASON="failed to send the launch command"; return 2
  fi
  if ! "$ORCA_CMUX" send-key --surface "$surface" enter >/dev/null; then
    ORCA_LAUNCH_REASON="failed to send enter after launch"; return 2
  fi

  local p screen rc
  for ((p = 0; p < ORCA_READY_POLLS; p++)); do
    if ! screen=$("$ORCA_CMUX" read-screen --surface "$surface" --lines 40 2>&1); then
      ORCA_LAUNCH_REASON="failed to read worker screen: ${screen//$'\n'/ }"; return 3
    fi
    if orca_maybe_accept_trust_prompt "$screen" "$surface"; then
      sleep "$ORCA_POLL_INTERVAL"; continue
    else
      rc=$?
      case "$rc" in
        1) ;;
        2) ORCA_LAUNCH_REASON="failed to answer the trust prompt"; return 4 ;;
        3) ORCA_LAUNCH_REASON="failed to submit the trust prompt answer"; return 4 ;;
        *) ORCA_LAUNCH_REASON="failed to handle the trust prompt"; return 4 ;;
      esac
    fi
    if orca_maybe_dismiss_upgrade_prompt "$screen" "$surface"; then
      sleep "$ORCA_POLL_INTERVAL"; continue
    else
      rc=$?
      case "$rc" in
        1) ;;
        2) ORCA_LAUNCH_REASON="failed to answer the upgrade prompt"; return 5 ;;
        3) ORCA_LAUNCH_REASON="failed to submit the upgrade prompt answer"; return 5 ;;
        *) ORCA_LAUNCH_REASON="failed to handle the upgrade prompt"; return 5 ;;
      esac
    fi
    if orca_is_ready "$provider" "$ready_marker" "$screen"; then return 0; fi
    sleep "$ORCA_POLL_INTERVAL"
  done

  ORCA_LAUNCH_REASON="readiness marker '$ready_marker' never appeared (agent did not come up)."
  return 6
}

# orca_cycle_mode <surface> <mode_key> <mode_target> <mode_max>
# Sends the mode key until the target marker appears (e.g. Claude's auto mode).
# Returns 0 on reaching the target; on failure sets ORCA_LAUNCH_REASON.
orca_cycle_mode() {
  local surface=$1 mode_key=$2 mode_target=$3 mode_max=$4
  ORCA_LAUNCH_REASON=""
  local attempts=0 screen
  while true; do
    if ! screen=$("$ORCA_CMUX" read-screen --surface "$surface" --lines 40 2>&1); then
      ORCA_LAUNCH_REASON="failed to read worker screen: ${screen//$'\n'/ }"; return 3
    fi
    if grep -qF -- "$mode_target" <<<"$screen"; then return 0; fi
    if ((attempts >= mode_max)); then
      ORCA_LAUNCH_REASON="mode never reached '$mode_target' after $mode_max attempts."; return 7
    fi
    if ! "$ORCA_CMUX" send-key --surface "$surface" "$mode_key" >/dev/null; then
      ORCA_LAUNCH_REASON="failed to send the mode key '$mode_key'"; return 8
    fi
    attempts=$((attempts + 1))
    sleep "${ORCA_MODE_INTERVAL:-$ORCA_POLL_INTERVAL}"
  done
}
