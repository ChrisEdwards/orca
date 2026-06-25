#!/usr/bin/env bash
# Compatibility wrapper for the bundled orca-adapter implementation.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec "$SCRIPT_DIR/../skills/orca-agent/scripts/orca-adapter.sh" "$@"
