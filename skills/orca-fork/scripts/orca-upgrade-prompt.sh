#!/usr/bin/env bash
#
# Shared upgrade-prompt helper for Orca skill scripts.
#
# This file is intentionally duplicated into each self-contained skill package.
# Keep copies byte-for-byte identical and protected by package tests.

orca_upgrade_skip_option() {
  local screen=$1
  local line option=""
  local bare_skip_re='^[[:space:]]*[>›]?[[:space:]]*([0-9]+)[.)]?[[:space:]]+Skip[[:space:]]*$'
  local any_skip_re='^[[:space:]]*[>›]?[[:space:]]*([0-9]+)[.)]?[[:space:]]+Skip($|[[:space:]])'

  while IFS= read -r line; do
    if [[ "$line" =~ $bare_skip_re ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi

    if [[ -z "$option" && "$line" =~ $any_skip_re ]]; then
      option=${BASH_REMATCH[1]}
    fi
  done <<<"$screen"

  [[ -n "$option" ]] || return 1
  printf '%s\n' "$option"
}

orca_screen_has_upgrade_prompt() {
  local screen=$1
  grep -qF -- "Update available!" <<<"$screen" \
    && orca_upgrade_skip_option "$screen" >/dev/null
}

orca_maybe_dismiss_upgrade_prompt() {
  local screen=$1 surface=$2
  if ! grep -qF -- "Update available!" <<<"$screen"; then
    return 1
  fi

  local option
  option=$(orca_upgrade_skip_option "$screen") || return 4

  "$ORCA_CMUX" send --surface "$surface" "$option" >/dev/null || return 2
  "$ORCA_CMUX" send-key --surface "$surface" enter >/dev/null || return 3
  return 0
}
