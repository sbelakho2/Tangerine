#!/usr/bin/env bash
# Produce/validate the kernel Stage1 artifact directly from the OCaml seed.
# No seed-VM self-host preflight: Stage1 production compiles the closure once.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/bootstrap_helpers.sh"
TARGET="$(bh_boot_target)"
STAGE1="$ROOT/build/tg_stage1"
SEED="$ROOT/stage0_ocaml/_build/default/bin/tg_stage0.exe"
mkdir -p "$ROOT/build"

if bh_stage1_provenance_ok "$STAGE1" "$TARGET"; then
  echo "stage1 production: resume accepted (provenance matches)"
  exit 0
fi

bh_export_stage1_vm_limits
echo "stage1 production: steps=$TANGERINE_BOOTSTRAP_VM_MAX_STEPS host_calls=$TANGERINE_BOOTSTRAP_VM_MAX_HOST_CALLS rss_mb=$TANGERINE_BOOTSTRAP_VM_MAX_RSS_MB alloc=$TANGERINE_BOOTSTRAP_VM_MAX_ALLOC"
bh_ocaml_seed_compile "$SEED" "$ROOT" "$TARGET" "$STAGE1" 2>&1 | tee "$ROOT/build/stage1_production.log"
rc=${PIPESTATUS[0]}
if [ "$rc" -ne 0 ] || [ ! -x "$STAGE1" ]; then
  echo "stage1 production: FAIL rc=$rc artifact=$([ -x "$STAGE1" ] && echo present || echo missing)" >&2
  exit "${rc:-1}"
fi
bh_write_stage1_provenance "$STAGE1" "$TARGET"
if ! validate_stage tg_stage1 "$STAGE1"; then
  echo "stage1 production: validation FAILED" >&2
  exit 1
fi
echo "stage1 production: PASS ($STAGE1)"
