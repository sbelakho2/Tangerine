#!/usr/bin/env bash
# scripts/check_system_intel_gate.sh — the system_intel (P0-10) release gate.
#
# The subsystem gate the reviewer's item P0-10 requires: the language-neutral
# system_intel layer is gated on its own tests, a CLI smoke over a scratch
# database, the always-on protocol regression, and — once it lands — the
# core v2 regression suite. It is pure python3 + bash and MUST NOT require
# the Tangerine compiler toolchain (no stage3 `tg`, no bootstrap artifact).
#
# Steps (run from the repository root, resolved from this script's path):
#   1. python3 must exist (the only hard tool requirement);
#   2. `python3 -m unittest discover -s system_intel/tests -v`;
#   3. CLI smoke on a scratch DB: scan + stats + `protocol | head -3`;
#   4. `python3 -m unittest system_intel.tests.test_core_v2 -v` when that
#      module exists; while it does not, report "pending core v2 suite"
#      (the core v2 workstream lands separately) and keep going;
#   5. ALWAYS run `python3 -m unittest system_intel.tests.test_protocol -v`.
#
# Exactly one final verdict line is printed:
#   SYSTEM_INTEL_GATE: PASS   (exit 0)
#   SYSTEM_INTEL_GATE: FAIL   (exit non-zero)
#
# Portable to GNU and BSD userlands: only POSIX/bash builtins, mktemp,
# head -n and python3 are used.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CLI="system_intel/tools/system_intel.sh"
workdir=""

on_exit() {
    status=$?
    if [ -n "$workdir" ] && [ -d "$workdir" ]; then
        rm -rf "$workdir" || true
    fi
    if [ "$status" -ne 0 ]; then
        printf 'SYSTEM_INTEL_GATE: FAIL\n'
    fi
    return "$status"
}
trap on_exit EXIT

if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 is required by the system_intel gate" >&2
    exit 1
fi

echo "==> system_intel unittest suite"
python3 -m unittest discover -s system_intel/tests -v

echo "==> system_intel CLI smoke (scratch DB)"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/system-intel-gate.XXXXXX")"
DB="$workdir/db"

bash "$CLI" scan system_intel/tests/fixtures/mini_repo --db "$DB"
bash "$CLI" stats "$DB"
bash "$CLI" protocol "$DB" >"$workdir/protocol.out"
if [ ! -s "$workdir/protocol.out" ]; then
    echo "error: protocol output is empty" >&2
    exit 1
fi
head -n 3 "$workdir/protocol.out"

echo "==> core v2 regression suite"
if [ -f system_intel/tests/test_core_v2.py ]; then
    python3 -m unittest system_intel.tests.test_core_v2 -v
else
    echo "warning: pending core v2 suite (system_intel/tests/test_core_v2.py does not exist yet)"
fi

echo "==> protocol regression (always)"
python3 -m unittest system_intel.tests.test_protocol -v

printf 'SYSTEM_INTEL_GATE: PASS\n'
