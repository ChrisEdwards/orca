#!/usr/bin/env bash
#
# Shared trust-prompt helper for Orca skill scripts.
#
# This file is intentionally duplicated into each self-contained skill package.
# Keep copies byte-for-byte identical and protected by package tests.

orca_screen_has_trust_prompt() {
  local screen=$1
  (grep -qF -- "Is this a project you trust?" <<<"$screen" \
    || grep -qF -- "Is this a project you created or one you trust?" <<<"$screen" \
    || grep -qF -- "Do you trust the contents of this directory?" <<<"$screen") \
    && grep -qiE -- '1[.)]?[[:space:]]+Yes' <<<"$screen"
}

orca_maybe_accept_trust_prompt() {
  local screen=$1 surface=$2
  if ! orca_screen_has_trust_prompt "$screen"; then
    return 1
  fi

  "$ORCA_CMUX" send --surface "$surface" "1" >/dev/null || return 2
  "$ORCA_CMUX" send-key --surface "$surface" enter >/dev/null || return 3
  return 0
}
