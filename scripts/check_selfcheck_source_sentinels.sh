#!/usr/bin/env bash
# check_selfcheck_source_sentinels.sh — shell entry for the source-level
# sentinel invariant checker (audit P2).  Kept as a shell wrapper so the
# health harness never embeds a python3 invocation directly (the debt
# policy lane asserts the health script contains no python3 token).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/scripts/check_selfcheck_source_sentinels.py" "$@"
