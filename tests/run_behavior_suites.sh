#!/usr/bin/env bash
#
# tests/run_behavior_suites.sh — the non-kernel-stdlib behavior suites
# (the mandate's non-kernel-stdlib-behavior row): the behavioral @test
# suites for the parse-clean modules whose behavior the host can run —
# the embedded MMIO/collections surface, the wasi guest surface, the
# kernel primitives, the HAL software backend, the GPU software backend
# and the GUI software canvas.
#
# Every suite runs through `tg test` (the standard runner — each @test
# function runs in its own process). The runner PROBES the compiler
# first: a compiler that cannot serve the suites (a pre-ladder or broken
# local binary) reports the suites as skipped — the CI ladder build
# serves them.
#
# Usage: tests/run_behavior_suites.sh <compiler> <outdir>

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

COMPILER="${1:-build/tg_stage2}"
OUTDIR="${2:-build/.behavior_suites}"

if [ ! -x "$COMPILER" ]; then
  echo "behavior suites: compiler binary not executable: $COMPILER" >&2
  exit 1
fi

mkdir -p "$OUTDIR"

# The probe: a trivial suite must compile and run.
PROBE="$OUTDIR/probe_suite.tg"
cat > "$PROBE" << 'EOF'
use std::core::{Option, Result, Unit, Bool, Int, UInt}
use std::test::*

@test
def probe_ok() -> Unit
  let x = 40 + 2
  if x != 42 then
    panic("probe failed")
  end
end
EOF

if ! "$COMPILER" test "$PROBE" > "$OUTDIR/probe.log" 2>&1; then
  echo "behavior suites: SKIP — the compiler cannot run `tg test` suites (the probe failed; see $OUTDIR/probe.log)"
  echo "behavior suites: the suites run after the next compiler build from this tree"
  exit 0
fi

SUITES=(
  "tests/embedded/embedded_mmio_behavior_test.tg"
  "tests/embedded/embedded_volatile_surface_test.tg"
  "tests/wasi/wasi_guest_surface_test.tg"
  "tests/kernel/kernel_primitives_test.tg"
  "tests/hal/hal_software_backend_test.tg"
  "tests/gui/gui_software_canvas_test.tg"
  "tests/gpu/gpu_software_backend_test.tg"
  "tests/platform/platform_surface_smoke_test.tg"
  "tests/mir_int_arith_semantics_test.tg"
  "tests/diag_derivation_test.tg"
  # third-audit items 23/24: the stable diagnostic id + retained store,
  # the typed ExplainNode trees and the diagnostic.* session round trip.
  "tests/semantic_diagnostics_test.tg"
  # third-audit item 22: the typed wire response records (the one-renderer/
  # one-parser round trips + the dispatch attachment) and the normal
  # `tg server` subcommand arg parse.
  "tests/semantic_server_test.tg"
  # offline snapshot path: the semantic_snapshot_parse exact-inverse lane
  # (byte-identity over a hand-built full snapshot), the malformed-row
  # fail-closed probes and the loaded-artifact session query.
  "tests/semantic_snapshot_parse_test.tg"
  # audit item 49: the structured generic-instance keys (StructuralInstanceId
  # / MonoCache.instances re-key + the P0-5 cross-kind order + the P0-6
  # insertion-stability lane + the documented const-fold model).
  "tests/mono_instance_key_test.tg"
  # fourth-audit P0-4: the persistent member/binder/HIR-node lineages
  # (insertion/rename stability, per-function binder numbering, the v2
  # store's member/binder/HIR sections and their save-load round trip).
  "tests/stable_member_lineage_test.tg"
  # fourth-audit P0-7/P0-8/P1-10: the persistent MIR origins + the semantic
  # re-key lane (origin stability across the O2 optimizer, PGO v3
  # round-trip + fail-closed v2 conversion, structural tail eligibility,
  # coverage control-origin ids carried by the LIR route's plan).
  "tests/mir_origin_identity_lane_test.tg"
  "tests/unit/test_int_overflow_behavior.tg"
  # audit item 1: the Slice ownership split (copied_slice / cloned_slice
  # drop counts, sub-view range validation) + the fixed-decimal suite.
  "tests/unit/test_slice_copy_resource_drop_count.tg"
  "tests/unit/test_slice_noncopy_clone_drop.tg"
  "tests/unit/test_slice_sub_oob.tg"
  "tests/unit/test_slice_sub_overflow.tg"
  "tests/unit/test_fixed_decimal.tg"
  # audit items 28 + 29: the ABI call-plan rows (classify_call_plan over
  # aarch64/x86-64/cortex-m/riscv64, internal + ExternC flavors).
  "tests/abi/abi_call_plan_rows_test.tg"
  # the cortex-m float-ABI residual slice: the AAPCS32 float stack
  # arguments (callee [FP + 8 + 4*k] binds and the caller's descending
  # push stream, the F64 even-word alignment pads and the word-aware
  # verifier accounting), the F32 int<->float transmute crossings and
  # the variadic float base-convention marshalling (P0-21).
  "tests/thumb_float_residual_rows_test.tg"
  # P0-21 (audit §16/§26): the cortex-m AAPCS32 variadic BASE-convention
  # lane rows — an F64/F32-promoted extra in an aligned r-pair via
  # vmov r,r,d or an 8-byte-aligned stack unit, the interleaved
  # displaced-int row, and the FPv4-SP F32-promotion fail-closed rule.
  "tests/thumb_variadic_float_rows_test.tg"
  # the cortex-m FPU-variant model rows (the float-work correctness
  # fix): the cm pool restricted to the encodable d8..d13, the FPv4-SP
  # F64-data-processing fail-closed gate vs the FPv5-D16 admission,
  # and the VPUSH/VPOP {d8-d15} FP callee-save emission.
  "tests/thumb_fp_fpu_variant_rows_test.tg"
  # the riscv float slice's row pinning (the F/D encoder bytes, the
  # psABI stack stream, the F32 F-only li32 + fmv.w.x constant path,
  # the riscv32 F64 two-unit push and the general-pool phys mapping).
  "tests/riscv_float_rows_test.tg"
  # P0-21 (audit §26): the riscv psABI variadic INTEGER-convention lane
  # rows — the rv64 F64 extra as one a-register bit pattern via
  # fmv.x.d, the rv32 aligned a-pair via fsd + lw/lw, the stack-extra
  # stream and the RVF F32-promotion fail-closed rule.
  "tests/riscv_variadic_float_rows_test.tg"
  # P0-21 deinit-plan consumer: the MirDeinit plan-tree rows (aggregate
  # field order, UserFinalizer-then-walk, enum active-variant selection,
  # the fixed-array counted loop, recursion-by-symbol glue calls, the
  # String destructor leaf) + the verify_lir gate on every row.
  "tests/lir_deinit_plan_test.tg"
  # P0-21 aggregate-layout model: the layout-driven admission/emission
  # rows (tuples, fixed arrays, nested aggregates, @packed/@align,
  # sub-word fields, zero-field structs) + the verify_lir gate.
  "tests/lir_aggregate_layout_test.tg"
  # the aggregate-residual slice: nested enum fields (value word,
  # discriminant normalization, heap downcast), heap-handle fields
  # (String move + plan destructor), nested projection through a
  # pointer (p.inner.x, p.e downcast) and sub-word F32 fields (4-byte
  # width accesses + GP<->FP bit moves) + the verify_lir gate.
  "tests/lir_aggregate_residual_test.tg"
  # audit item 34 stage 2: the LIR vector params/returns + ABI crossings
  # (the shared SIMD&FP file positions from classify_call_plan, the
  # entry bind / call argument / return markers, the memory-resident
  # image across a call, the v256 admission gated by the desc's AVX
  # tokens) + the verify_lir gate.
  "tests/lir_vector_abi_rows_test.tg"
  # the explicit-op extension lane: the andnot / compare / shift /
  # splat / lane / pack-unpack lowering rows (each extension intrinsic
  # becomes one marked LirVecOp and verify_lir stays clean) + the
  # semantic-set refusal rows (float gt/ge, the 64-bit ordering
  # compares, the float lane moves, the non-narrow pack source and the
  # out-of-range marker data).
  "tests/lir_vector_ext_op_rows_test.tg"
  # the whole-vector move/copy slice: the v128 slot-image copy row
  # (aarch64), the assignment-move (MirMovePlace) row, the v256 copy on
  # the AVX2 x86-64 desc with the baseline refusal, and the stale-note
  # gate over lir.tg's live header.
  "tests/lir_vector_move_rows_test.tg"
  # third-audit item 34: the §40 coverage ingest lane (tg.cov.v1 ids, the
  # tg.cov.trace.v1 ingest, the point indexes, uncovered_paths and the
  # test.affected / coverage.affected ops).
  "tests/coverage_graph_test.tg"
  # third-audit item 34 (runtime producer): the coverage emission plan
  # (counter table attach + global bases) and the dump-writer renderer
  # over a synthetic counter array — the contract the LIR-route runtime
  # blob is built from.
  "tests/coverage_emission_test.tg"
  # third-audit item 45: the @budget guarantee vocabulary + classification
  # lane (the BudgetGuarantee / BudgetDerivations records, the
  # budget_classification_of rule, the derivation-aware static
  # classification and the violation-row derivation).
  "tests/budget_guarantees_test.tg"
  # Tier-4: the compiler-grounded persistent rationale history (the five
  # decision sources, the text save/load and the record / history digests)
  # + the dynamic semantic-tool discovery surface (the registry walk, the
  # audited enumeration and the requires_* filters).
  "tests/semantic_rationale_test.tg"
  # fourth-audit P1-9: deterministic record/run/compare over typed replay
  # events (the ReplayChoice union, the deterministic choice stream, the
  # semantic-only replay_compare and the sync-edge happens-before slice).
  "tests/replay_typed_events_test.tg"
)

FAILED=0
for suite in "${SUITES[@]}"; do
  if "$COMPILER" test "$suite" > "$OUTDIR/$(basename "$suite").log" 2>&1; then
    echo "behavior suites: PASS  $suite"
  else
    echo "behavior suites: FAIL  $suite (see $OUTDIR/$(basename "$suite").log)" >&2
    FAILED=1
  fi
done

# Audit §24: the ordinary integer arithmetic semantics must be
# identical at every optimization level — the runtime rows of
# test_int_overflow_behavior.tg run again under -O0..-O3 (the default
# run above uses the driver's default level), and the exit-code trap
# lane proves the signed-overflow TRAP and the division-edge TRAP
# (audit item 30: /0, %0 and signed MIN/-1) fire at every level.
for level in 0 1 2 3; do
  if "$COMPILER" test "-O$level" "tests/unit/test_int_overflow_behavior.tg" > "$OUTDIR/test_int_overflow_behavior_O${level}.log" 2>&1; then
    echo "behavior suites: PASS  tests/unit/test_int_overflow_behavior.tg at -O$level"
  else
    echo "behavior suites: FAIL  tests/unit/test_int_overflow_behavior.tg at -O$level (see $OUTDIR/test_int_overflow_behavior_O${level}.log)" >&2
    FAILED=1
  fi
done

if bash tests/run_int_arith_trap_lane.sh "$COMPILER" "$OUTDIR/trap_lane"; then
  echo "behavior suites: PASS  tests/run_int_arith_trap_lane.sh"
else
  echo "behavior suites: FAIL  tests/run_int_arith_trap_lane.sh" >&2
  FAILED=1
fi

# The P0-21 retirement-readiness DIFFERENTIAL PARITY item: the
# differential-corpus lane (the explicit --codegen=direct fallback
# against the default LIR route — executed behavior compared where the
# host can run both, emitted-object AbiCallPlans + symbol sets compared
# with an explicit SKIP-EXEC status otherwise). The aarch64-none LIR
# artifact rows ride the same script (structural only).
if bash tests/run_differential_corpus_tests.sh "$COMPILER" "$OUTDIR/differential_corpus"; then
  echo "behavior suites: PASS  tests/run_differential_corpus_tests.sh"
else
  echo "behavior suites: FAIL  tests/run_differential_corpus_tests.sh" >&2
  FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
  echo "behavior suites: FAILED" >&2
  exit 1
fi

echo "behavior suites: PASS"
