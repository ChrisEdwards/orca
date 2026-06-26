#!/usr/bin/env bash
#
# Shared upgrade-prompt helper for Orca skill scripts.
#
# This file is intentionally duplicated into each self-contained skill package.
# Keep copies byte-for-byte identical and protected by package tests.

orca_screen_has_upgrade_prompt() {
  local screen=$1
  grep -qF -- "Update available!" <<<"$screen" \
    && grep -qiE -- '[23][.)]?[[:space:]]+Skip' <<<"$screen"
}

orca_maybe_dismiss_upgrade_prompt() {
  local screen=$1 surface=$2
  if ! orca_screen_has_upgrade_prompt "$screen"; then
    return 1
  fi

  "$ORCA_CMUX" send --surface "$surface" "2" >/dev/null || return 2
  "$ORCA_CMUX" send-key --surface "$surface" enter >/dev/null || return 3
  return 0
}
