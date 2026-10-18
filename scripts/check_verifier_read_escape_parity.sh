#!/usr/bin/env bash
# ———————————————————————————————————————————————————————————————
# Read-escape parity check (seed verifier <-> self-host kernel verifier).
#
# The ownership rule lives in two implementations:
#   * stage0_ocaml/src/mir_verify.ml      check_read_escapes / shareable_go
#   * tg_compiler/mir.tg                  verifier_check_read_escape / verifier_type_shareable_read
#
# This script runs BOTH test batteries:
#   * the seed self-check tg_verify (m5 reject owning element, m6 shareable
#     accept, m7 call-borrow accept);
#   * the kernel verifier suite tests/verifier_read_escape_tests.tg (the
#     full projection matrix: field/tuple/variant/constant/dynamic index/
#     deref, Box/Rc/Arc/weak/UniquePtr and container nestings).
#
# It requires both to pass.  It deliberately does NOT treat a missing
# kernel binary as success: build the stage1 ladder first (run_bootstrap.sh)
# so ./build/tg exists.  The suites encode the same expected semantic
# outcome per shape; a disagreement is a parity failure.
#
# Exit: 0 both pass, 1 a suite failed, 2 kernel binary unavailable.
# ———————————————————————————————————————————————————————————————
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SEED_EXE="stage0_ocaml/_build/default/selfcheck/tg_verify.exe"
KERNEL_EXE="build/tg"

if [[ ! -x "$SEED_EXE" ]]; then
  echo "read-escape parity: building the seed self-check executable..."
  (cd stage0_ocaml && dune build selfcheck/tg_verify.exe)
fi

echo "== seed verifier (tg_verify: m5/m6/m7 Read gate) =="
SEED_OUT="$(mktemp)"
trap 'rm -f "$SEED_OUT"' EXIT
if ! "$SEED_EXE" >"$SEED_OUT" 2>&1; then
  cat "$SEED_OUT"
  echo "read-escape parity: FAIL — seed verifier battery failed"
  exit 1
fi
grep -E "^(PASS|FAIL): m[5-7]:" "$SEED_OUT" || true

if [[ ! -x "$KERNEL_EXE" ]]; then
  echo "read-escape parity: PENDING — $KERNEL_EXE is absent; build the stage1 ladder (./run_bootstrap.sh) and rerun"
  exit 2
fi

echo "== self-host kernel verifier (tests/verifier_read_escape_tests.tg) =="
if ! "$KERNEL_EXE" test tests/verifier_read_escape_tests.tg; then
  echo "read-escape parity: FAIL — kernel verifier battery failed"
  exit 1
fi

echo "read-escape parity: PASS — seed and kernel verifier batteries agree on the Read-escape matrix"
