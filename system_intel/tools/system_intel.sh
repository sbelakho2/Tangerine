#!/usr/bin/env bash
# Wrapper for the Tangerine System Intelligence CLI.
# Resolves the repository root from this script's location so it can be run
# from anywhere, then execs the module with the repo root on PYTHONPATH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

export PYTHONPATH="${REPO_ROOT}${PYTHONPATH:+:${PYTHONPATH}}"

exec python3 -m system_intel.cli "$@"
