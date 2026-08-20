#!/usr/bin/env bash
# scripts/gen_status.sh — regenerate the STATUS snapshot from the ACTUAL git state.
#
# Two forms of STATUS.txt exist, and this script generates the ARTIFACT form:
#
#   1. The COMMITTED STATUS.txt is the SHA-INDEPENDENT SOURCE-STATE
#      description: it records structural facts, harness constants and
#      pointers, but never claims a commit SHA or run numbers (a committed
#      file is stale the moment the next commit lands — the generate-then-
#      commit workflow cannot win). It is maintained by docs edits, not by
#      this script.
#
#   2. The ARTIFACT form (what THIS script writes) is generated at release
#      / CI time FROM THE TESTED SHA: the exact commit the tests ran on,
#      the working-tree list at that commit, the structural facts, and —
#      when --artifacts is given — the sha-256 of the test artifacts
#      (canary outputs, phase fingerprints, litmus/target-lane outputs).
#      CI's `status` job runs this script after the tests and uploads the
#      result as the `status-snapshot` artifact; the committed file points
#      at it instead of pretending to be current.
#
# Usage: ./scripts/gen_status.sh [--artifacts <dir>] [outfile]
#   --artifacts <dir>   include a TEST ARTIFACTS section: sha-256 of every
#                       file under <dir> (repeatable; also read from
#                       $TG_STATUS_ARTIFACTS, a colon-separated list).
#   outfile             defaults to STATUS.txt at the repo root.
# Exit status: 0 when every structural fact greps as expected; non-zero
# (with the file still written) when a fact drifted, so CI can gate on it.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/STATUS.txt}"
ARTIFACT_DIRS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts)
      shift
      ARTIFACT_DIRS="${ARTIFACT_DIRS}${1}:"
      shift
      ;;
    *) break ;;
  esac
done
[ $# -eq 0 ] || OUT="$1"
ARTIFACT_DIRS="${ARTIFACT_DIRS}${TG_STATUS_ARTIFACTS:-}"

SHA="$(git -C "$ROOT" rev-parse HEAD)"
DATE="$(date +%Y-%m-%d)"

# ── harness constants (single source: bootstrap_helpers.sh) ───────────────
POS="$(sed -n 's/^CANARY_SUITE_POSITIVE_COUNT=\([0-9]*\)/\1/p' "$ROOT/scripts/bootstrap_helpers.sh" | head -1)"
NEG="$(sed -n 's/^CANARY_SUITE_NEGATIVE_COUNT=\([0-9]*\)/\1/p' "$ROOT/scripts/bootstrap_helpers.sh" | head -1)"
ARM="$(sed -n 's/^CANARY_SUITE_ARM64_COUNT=\([0-9]*\)/\1/p' "$ROOT/scripts/bootstrap_helpers.sh" | head -1)"

# ── structural verification facts ──────────────────────────────────────────
# Each fact greps for the marker of the implemented behavior; a fact that
# fails to grep sets `fail=1` (the snapshot still records the outcome).
fail=0
fact() { # fact <label> <grep-expr> <file>
  local label="$1" expr="$2" file="$3"
  if grep -qE "$expr" "$file"; then
    printf '  [ok] %s\n' "$label"
  else
    printf '  [MISSING] %s (expected /%s/ in %s)\n' "$label" "$expr" "$file" >&2
    fail=1
  fi
}

# Structured diagnostics at the API boundary: analyze_program/analyze_parsed
# return the structured Vec[Diagnostic] — no stringified-error returns remain.
fact "analyze_program returns Result[AnalyzedProgram, Vec[Diagnostic]]" \
  'pub def analyze_program\(.*\) -> Result\[AnalyzedProgram, Vec\[Diagnostic\]\]' \
  "$ROOT/tg_compiler/compiler_core.tg"
fact "analyze_parsed returns Result[AnalyzedProgram, Vec[Diagnostic]]" \
  'pub def analyze_parsed\(.*\) -> Result\[AnalyzedProgram, Vec\[Diagnostic\]\]' \
  "$ROOT/tg_compiler/compiler_core.tg"

# ModeConfig reduction: only the enforced bits remain; the deleted
# configuration fields are absent from mode.tg.
if grep -q 'enforce_effects' "$ROOT/tg_compiler/mode.tg"; then
  printf '  [MISSING] mode.tg still carries enforce_effects\n' >&2
  fail=1
else
  printf '  [ok] mode.tg carries no enforce_effects bit\n'
fi
fact "mode.tg ModeConfig is reduced (mode + enforce_contracts + enforce_capabilities)" \
  'struct ModeConfig' "$ROOT/tg_compiler/mode.tg"
fact "mode.tg keeps the Mode enum" \
  'enum Mode' "$ROOT/tg_compiler/mode.tg"

# String Clone/Eq/Hash trait impls present (std/core.tg).
fact "impl Clone for String" '^impl Clone for String' "$ROOT/std/core.tg"
fact "impl Eq for String" '^impl Eq for String' "$ROOT/std/core.tg"
fact "impl Hash for String" '^impl Hash for String' "$ROOT/std/core.tg"

# ── round-9 grammar state (E100/E106) ─────────────────────────────────────
# The legacy parameter spellings are HARD errors (E100), never normalized.
fact "legacy parameter spellings rejected (E100)" \
  'legacy parameter spelling' "$ROOT/tg_compiler/parser.tg"
# First-class reference types in general type position are E106.
fact "first-class safe references rejected (E106)" \
  'diag_safe_ref_not_first_class' "$ROOT/tg_compiler/parser.tg"
# Ref-pattern rejection (E106).
fact "ref-pattern rejection" 'ref patterns are not supported' "$ROOT/tg_compiler/parser.tg"

# FFI audit — the extern-ABI reference exception is scoped to the
# compiler-known `__intrinsic_` declarations (parse_extern_fn AND
# parse_extern_static, 2 sites), and the scoping test is the name prefix.
if [ "$(grep -c 'p.extern_abi_context = is_intrinsic_extern_name(&name)' "$ROOT/tg_compiler/parser.tg")" -eq 2 ]; then
  printf '  [ok] extern-ABI reference context scoped by is_intrinsic_extern_name (2 sites)\n'
else
  printf '  [MISSING] extern-ABI reference context scoping sites drifted (expected 2)\n' >&2
  fail=1
fi
fact "is_intrinsic_extern_name = the __intrinsic_ prefix test" \
  'def is_intrinsic_extern_name' "$ROOT/tg_compiler/ids.tg"
fact "is_intrinsic_extern_name prefix body" \
  'starts_with\("__intrinsic_"\)' "$ROOT/tg_compiler/ids.tg"

# ── round-9 gates ──────────────────────────────────────────────────────────
# Self-host grammar gate: the script exists and is wired into the bootstrap
# harness next to the struct-integrity pre-gate.
fact "self-host grammar gate script (forbidden legacy scan)" \
  'forbidden legacy parameter' "$ROOT/scripts/run_selfhost_grammar_gate.sh"
fact "grammar gate wired into run_bootstrap.sh" \
  'run_selfhost_grammar_gate' "$ROOT/run_bootstrap.sh"

# Two-layer stdlib gate: tg check (zero diagnostics) + the forbidden-syntax
# grep backstop, a REQUIRED CI job.
fact "stdlib sweep backstop (forbidden-syntax grep)" \
  'forbidden-syntax grep backstop' "$ROOT/tests/run_stdlib_e106_sweep.sh"
fact "stdlib sweep covers every shipped module (133)" \
  '133' "$ROOT/tests/run_stdlib_e106_sweep.sh"
fact "stdlib-e106-sweep is a required CI job" \
  'stdlib-e106-sweep' "$ROOT/.github/workflows/ci.yml"

# Test-runner integrity (P0): tg test must distinguish pass / fail /
# zero-tests / parse-error / implicit-skip.
fact "test-runner integrity gate" \
  'test-runner integrity' "$ROOT/tests/run_test_runner_integrity.sh"

# ── round-9 compiler/runtime state ─────────────────────────────────────────
# Atomics: the __intrinsic_atomic_* family is the ONE atomic authority.
fact "atomic intrinsic authority (emit_atomic_intrinsic)" \
  'emit_atomic_intrinsic' "$ROOT/tg_compiler/codegen.tg"

# Allocator: per-size-class locks serialize the free-list head pop/push
# (the lock emitter pair in runtime.tg; the per-size-class call sites and
# the lock label usage in codegen.tg).
fact "allocator per-size-class lock emitter" 'def emit_tg_alloc_lock' "$ROOT/tg_compiler/runtime.tg"
fact "allocator per-size-class unlock emitter" 'def emit_tg_alloc_unlock' "$ROOT/tg_compiler/runtime.tg"
fact "allocator lock label used by the allocator paths" '_tg_alloc_lock' "$ROOT/tg_compiler/codegen.tg"

# MIR verifier: real CFG/dataflow verification (verify_function_v2).
fact "MIR CFG/dataflow verifier (verify_function_v2)" \
  'verify_function_v2' "$ROOT/tg_compiler/mir.tg"

# @cfg pass: target-conditioned declaration elimination + E108 fail-closed
# empty-predicate diagnostic.
fact "@cfg elimination pass (apply_cfg_elimination)" \
  'apply_cfg_elimination' "$ROOT/tg_compiler/compiler_core.tg"
fact "@cfg empty predicate fails closed (E108)" \
  'E108InvalidCfgPredicate' "$ROOT/tg_compiler/parser.tg"

# ── allocator + String drop (round-7/8 facts, still live) ──────────────────
fact "allocator per-class free heads" '_tg_alloc_free_heads' "$ROOT/tg_compiler/runtime.tg"
fact "String destructor (DeinitPlan::String -> _tg_string_drop)" '_tg_string_drop' "$ROOT/tg_compiler/runtime.tg"

# Verifier projection walk (copy-safety backstop) + its tests.
fact "verifier projection walk (copy-safety)" 'verifier_check_operand_ownership' "$ROOT/tg_compiler/mir.tg"
fact "verifier unit tests file" 'verifier' "$ROOT/tests/verifier_projection_tests.tg"

# Fixed-array const sizes.
fact "fixed-array const-size evaluator" 'eval_const_size_expr' "$ROOT/tg_compiler/types.tg"
fact "fixed-array const-size canary" 'canary_pos_fixed_array_const_size' "$ROOT/tests/canary/MANIFEST"

# Partial-move place registry + masked glue.
fact "place-level move registry" 'place_move_states' "$ROOT/tg_compiler/types.tg"
fact "partial-drop chain (masked glue)" 'mir_emit_partial_drop_chain' "$ROOT/tg_compiler/mir.tg"

# ── round-10 facts ─────────────────────────────────────────────────────────
# Doctest discipline: scripts/check_doctests.sh extracts the fenced blocks
# of the six doctested docs, scans unannotated blocks for the forbidden
# legacy forms, and verifies the compile_fail annotations; the CI doctests
# job runs it with the stage3 artifact.
fact "doctest gate script (forbidden-form scan + compile_fail verification)" \
  'compile_fail' "$ROOT/scripts/check_doctests.sh"
fact "doctest gate script covers the six documents" \
  'feature_registry.md' "$ROOT/scripts/check_doctests.sh"
fact "doctest gate wired into CI (doctests job)" \
  'doctests' "$ROOT/.github/workflows/ci.yml"

# @cfg strictness + the cross-target matrix: the elimination is FINAL (an
# eliminated item never resurrects), and the matrix drives the pass with
# explicit --target overrides, positive cases check clean and negative
# cases must show the exact unresolved-name rejection.
fact "@cfg elimination is final (never resurrected by references)" \
  'never resurrected' "$ROOT/tg_compiler/compiler_core.tg"
fact "@cfg cross-target matrix script" \
  'cfg matrix' "$ROOT/tests/run_cfg_matrix_tests.sh"
fact "@cfg matrix negative canaries present" \
  'cfg_macos_marker' "$ROOT/tests/cfg_matrix/canary_neg_cfg_macos_symbol_on_linux.tg"

# Arc-guard redesign: Mutex::lock clones the Arc into the guard, so the
# guard keeps the lock state alive — no raw pointer into a caller-owned
# Mutex; the guard's Drop releases the lock with an atomic store.
fact "Arc-guard redesign (guard holds its own Arc clone)" \
  'Arc\[MutexInner' "$ROOT/std/sync.tg"

# TLS capacity/drop fixes: explicit with_capacity instead of empty Vec
# growth (the DER/read buffer can no longer be overrun) + Drop impls that
# free the OpenSSL handles.
fact "TLS buffer capacity fixes (Vec::with_capacity)" \
  'with_capacity\(8192\)' "$ROOT/std/tls.tg"
fact "TLS handle Drop impls (Certificate/PrivateKey/TlsConnection)" \
  'impl Drop for Certificate' "$ROOT/std/tls.tg"

# Atomic ABI widths: the intrinsic family covers the 1/2/4/8-byte widths
# on both arches (atomic_intrinsic_op_and_width), and std::atomic exposes
# the sized types.
fact "atomic ABI widths (op+width decode)" \
  'atomic_intrinsic_op_and_width' "$ROOT/tg_compiler/codegen.tg"
fact "atomic sized types (AtomicU8..AtomicU64)" \
  'struct AtomicU8' "$ROOT/std/atomic.tg"

# SeqCst store = the xchg-based store on x86-64 (the ordering code is
# read where it matters: cmp edx, 5 branches to the plain MOV for the
# weaker orderings; the SeqCst LOAD stays the plain MOV under TSO).
fact "SeqCst store dispatches on the ordering code" \
  'cmp edx, 5' "$ROOT/tg_compiler/codegen.tg"
fact "SeqCst xchg store + weak-MOV store pair" \
  'Latomic_store_weak' "$ROOT/tg_compiler/codegen.tg"

# Atomic accounting: the allocator's outstanding-allocations counters are
# updated atomically (LDADDAL / lock xadd), never under a partially
# released lock.
fact "atomic accounting emitters (a64/x64)" \
  'def rt_outstanding_add_a64' "$ROOT/tg_compiler/runtime.tg"
fact "atomic accounting x64 pair" \
  'def rt_outstanding_add_x64' "$ROOT/tg_compiler/runtime.tg"

# Alignment contract: every allocator path returns a 16-byte-aligned
# payload (raw runtime, SystemAllocator, arena), asserted by the
# alignment test.
fact "allocator alignment contract test" \
  '16-byte-aligned PAYLOAD' "$ROOT/tests/allocator_alignment_test.tg"

# io pointer wrappers: sys_read/sys_write take the BUFFER POINTERS
# (PtrMut[u8] / Ptr[u8]), never Int addresses.
fact "io syscall wrappers are pointer-typed (sys_read)" \
  'def sys_read\(fd: Int, buf: PtrMut\[u8\], len: Int\)' "$ROOT/std/io.tg"
fact "io syscall wrappers are pointer-typed (sys_write)" \
  'def sys_write\(fd: Int, buf: Ptr\[u8\], len: Int\)' "$ROOT/std/io.tg"

# DB/thread semantics: the ToSqlParam/FromSqlValue conversions dropped the
# legacy deref spellings, and std::thread re-exports std::sync's types
# (the ONE Arc-guard design) — no second mutex universe.
fact "db conversions use plain value bindings" \
  'def to_sql_param\(self: Int\)' "$ROOT/std/db.tg"
fact "thread module re-exports the std::sync types" \
  'use std::sync::{Mutex, RwLock, Arc}' "$ROOT/std/thread.tg"

# @test canonicalization + the restored lanes: `tg test` compiles a file
# with a generated per-test dispatch main (each @test runs as its own
# process), and the stdlib/gfx-ui CI lanes were restored to check ->
# object -> link/import smoke -> native.
fact "@test per-test dispatch main" \
  'compile_and_run_tests' "$ROOT/tg_compiler/driver.tg"
fact "@test dispatch is the canonical per-test main" \
  'per-test dispatch main' "$ROOT/tg_compiler/driver.tg"
fact "stdlib verify lane restored (CI job)" \
  'stdlib-new-modules' "$ROOT/.github/workflows/ci.yml"
fact "gfx-ui lanes restored (CI jobs)" \
  'gfx-ui-visual' "$ROOT/.github/workflows/ci.yml"

# Crypto KAT: the known-answer suite over the std/crypto.tg primitives is
# a required CI job.
fact "crypto KAT suite (known-answer vectors)" \
  'test_crypto_rigor' "$ROOT/tests/unit/test_crypto_rigor.tg"
fact "crypto KAT CI job" \
  'crypto-kat' "$ROOT/.github/workflows/ci.yml"

# ── working-tree file list ─────────────────────────────────────────────────
WT="$(git -C "$ROOT" status --porcelain)"

# ── test-artifact hashes (--artifacts / $TG_STATUS_ARTIFACTS) ─────────────
ARTIFACT_HASHES=""
if [ -n "$ARTIFACT_DIRS" ]; then
  ARTIFACT_HASHES="$(IFS=':' ; for d in $ARTIFACT_DIRS; do
    [ -n "$d" ] || continue
    if [ -d "$d" ]; then
      find "$d" -type f -print0 | sort -z | while IFS= read -r -d '' f; do
        shasum -a 256 "$f" 2>/dev/null | sed "s#  $d/#  #"
      done
    elif [ -f "$d" ]; then
      shasum -a 256 "$d" 2>/dev/null
    else
      echo "  (missing artifact path: $d)" >&2
    fi
  done)"
fi

# ── emit the snapshot (the CI/release ARTIFACT form) ───────────────────────
{
  cat <<EOF
STATUS: $DATE — TESTED-SHA snapshot at commit $SHA
(artifact form generated by scripts/gen_status.sh FROM THE TESTED SHA:
the CI \`status\` job runs this after the tests and uploads the result as
the \`status-snapshot\` artifact; the committed STATUS.txt is the
SHA-independent source-state description and points at this artifact —
see the WORKFLOW note in the committed file)

WORKING TREE (git status --porcelain, at the tested SHA):
$WT

RUN RESULTS — see the test artifacts (hashes below) and the CI job
summaries (bootstrap, conformance, cross-compile, stdlib-e106-sweep,
stdlib-new-modules, gfx-ui, gfx-ui-visual, test-runner integrity,
crypto-kat, doctests):
  The tested SHA is the commit this file names; the run numbers belong to
  the CI jobs that consumed it, not to a hand-rolled local snapshot.

TEST ARTIFACTS (sha-256 of the uploaded canary/fingerprint/litmus and
target-lane outputs; regenerated by --artifacts <dir> or the
TG_STATUS_ARTIFACTS list):
${ARTIFACT_HASHES:-  (no artifact paths were provided to this run — pass --artifacts <dir> or TG_STATUS_ARTIFACTS)}

CURRENT STATE (structural, verified against the tested tree):
- Stage0 (Swift interpreter) exists; the ladder is run via ./run_bootstrap.sh
  (stage0 -> stage1 -> stage2 -> stage3 with stage2 == stage3 byte-identical
  and per-phase fingerprints; --skip-ladder/--skip-determinism options exist
  but a full run is the release gate). The self-host GRAMMAR GATE
  (scripts/run_selfhost_grammar_gate.sh) runs before any stage is built
  next to the struct-integrity pre-gate: the manifest closure (37 sources)
  must be free of every forbidden legacy parameter form (mut/&/&mut/move/own
  prefixes, \`x: &T\` / \`x: &mut T\` markers, fn-type conventions, \`&self\` /
  \`&mut self\` receivers), or the harness fails before stage0.
- Bootstrap closure: bootstrap/compiler_kernel.manifest, 37 sources
  (14 std + 23 compiler files); build/bootstrap-input.json records the
  aggregate source hash (aarch64-apple-darwin; regenerated by the
  manifest-hash tool against the current working tree).
- Native compiler pipeline: lex -> parse (E100 hard error on every legacy
  parameter spelling; E106 hard error on first-class \`&T\` type positions
  AND on ref patterns; the extern-declaration ABI parser parse_extern_abi_type
  is the ONE allowed reference position, SCOPED to __intrinsic_-named
  externs by is_intrinsic_extern_name — the FFI audit) -> dependency merge
  -> @cfg target-conditioned declaration elimination (apply_cfg_elimination;
  an empty \`@cfg()\` predicate fails closed with E108; the elimination is
  FINAL — an eliminated item does not exist for the target and is never
  resurrected by references) -> macro expansion
  (E105 fixpoint) -> resolve (strict, forced) -> type check (typed HIR) ->
  access check -> resource check (capabilities enforced) -> MIR
  (verify_function_v2, the CFG/dataflow verifier with the projection-aware
  moved-state lattice, post-lower/mono/opt) -> mono (zero-inference) ->
  codegen (aarch64 host; x86-64 cross lane) -> link.
- @cfg cross-target matrix (P0): tests/run_cfg_matrix_tests.sh drives the
  pass with explicit --target overrides — (a+) linux member checks clean
  on x86_64-linux-gnu, (a-) the macos symbol is rejected with "unresolved
  name: cfg_macos_marker" on linux, (b+) the macos member checks clean on
  aarch64-apple-darwin, (b-) the linux symbol is rejected on macos, (c) an
  un-gated windows reference is rejected on EVERY non-windows target, and
  the host family canary compiles and runs (exit 0).
- Diagnostics are STRUCTURED at the API boundary: analyze_parsed /
  analyze_program / analyze_source return Result[AnalyzedProgram,
  Vec[Diagnostic]] — every diagnostic keeps its span and code; the
  stringification (join_diagnostics) happens only at the CLI/human
  presentation boundary (compile_file_core/compile_startup_entry/
  compile_multiple_files emit each structured diagnostic through the
  emitter before returning the joined summary).
- ModeConfig is REDUCED to the implemented behavior (tg_compiler/mode.tg):
  mode + enforce_contracts + enforce_capabilities only; both bits are
  unconditional (lower_contract / validate_capability_exit never consult
  the flag). The former config bits (effects/budgets/coverage/CQS/docs/
  tests/unsafe/review/memory-safety/dependency-audit/stubs/escalation)
  are DELETED — see docs/current/language.md §Progressive Strictness.
- String Clone/Eq/Hash: std/core.tg declares impl Clone/Eq/Hash for
  String, so the [T: Clone]/[T: Eq]/[T: Hash] bounds are satisfiable.
- Partial moves: the place-level registry (types.tg record_place_moves /
  place_move_states) + the masked glue (mir.tg mir_emit_partial_drop_chain)
  exist, under the projection-aware moved-state lattice the MIR verifier
  checks; direct expression-level projected-place consume/assign is still
  rejected (docs/current/memory_model.md §4.4).
- Fixed-array const sizes: eval_const_size_expr (literals, const
  references, constant arithmetic) — canary_pos_fixed_array_const_size.tg.
- Drop glue: every concrete non-trivial plan owns a generated
  drop-glue MirFunction (mir_build_all_drop_glues); recursion broken by
  symbol; String's plan is DeinitPlan::String — _tg_string_drop frees the
  object AND the buffer through the real-heap allocator (_tg_mem_free,
  per-class free list; _tg_alloc_free_heads; the per-size-class locks
  _tg_alloc_lock/_tg_alloc_unlock serialize the free-list head pop/push).
- Atomics: codegen.tg emit_atomic_intrinsic is the ONE atomic authority —
  std::atomic and std::sync route every atomic operation through the
  __intrinsic_atomic_* family (inline LDAR/STLR/LSE on AArch64, LOCKed
  xchg/xadd/cmpxchg on x86-64); a fence never substitutes for atomicity.
  The intrinsic ABI covers the 1/2/4/8-byte widths on both arches
  (atomic_intrinsic_op_and_width; AtomicU8..AtomicU64 in std/atomic.tg).
  On x86-64 the SeqCst STORE is the xchg-based store (the ordering code
  is read where it matters — cmp edx, 5 branches to the plain-MOV store
  for the weaker orderings, which TSO already makes release), while the
  SeqCst LOAD stays the plain MOV (total order = TSO + the xchg-store
  discipline); the SeqCst store on AArch64 is the STLR of the LDAR/STLR
  pair. The allocator's outstanding-allocations accounting is atomic too
  (runtime.tg rt_outstanding_add/sub_* — LDADDAL / lock xadd), so the
  counter is never updated under a partially released lock.
- Stdlib E106 migration COMPLETE: every shipped std module (all 133
  std/*.tg files) is parse-clean, enforced by the two-layer gate
  (tests/run_stdlib_e106_sweep.sh: \`tg check\` zero-diagnostics per module
  + the forbidden-syntax grep backstop), a REQUIRED CI job
  (stdlib-e106-sweep in .github/workflows/ci.yml). The ONLY remaining
  reference type positions are the five __intrinsic_map_visit_* /
  __intrinsic_set_visit_* record-visit extern signatures in
  std/collections.tg — the documented extern-ABI exception, not a
  migration remainder (docs/current/stdlib_reference.md §Completeness).
- Test-runner integrity: tests/run_test_runner_integrity.sh (P0 gate)
  encodes the \`tg test\` outcome contract — explicit passing file exits 0,
  failing file exits nonzero, zero-@test file exits nonzero with the "no
  tests found in <file>" diagnostic, parse-error file exits nonzero with
  diagnostics, implicit directory discovery stays skip-tolerant.
- @test canonicalization: \`tg test\` compiles each test file with a
  GENERATED per-test dispatch main (driver.tg compile_and_run_tests) and
  runs every @test function as its own process; the stdlib and gfx-ui CI
  lanes were restored to check -> object -> link/import smoke -> native.
- The Arc-guard redesign (std/sync.tg): Mutex::lock clones the Arc into
  the guard, so the guard KEEPS THE LOCK STATE ALIVE — the Mutex can be
  dropped or moved while a guard lives, no guard ever holds a raw pointer
  into a caller-owned Mutex; the guard's Drop releases the lock with an
  atomic store, and std::thread re-exports the std::sync types (ONE mutex
  universe — no second pthread-based rwlock family).
- TLS capacity/drop fixes (std/tls.tg): the DER/read buffers use explicit
  Vec::with_capacity with bounds checks against capacity (negative and
  overflow results are errors, never silent set_len), and Certificate /
  PrivateKey / TlsConnection gained Drop impls that free the OpenSSL
  handles (tls_x509_free / tls_pkey_free / tls_ssl_free).
- The io syscall wrappers are pointer-typed (std/io.tg): sys_read takes
  buf: PtrMut[u8] and sys_write takes buf: Ptr[u8] — the kernel writes
  into / reads from the caller's buffer directly; the Int-address
  reduction (\`buf.as_ptr() as Int\`) is gone.
- DB conversions (std/db.tg): ToSqlParam / FromSqlValue bind the SqlValue
  payload by plain value (\`self as i64\`, never a deref of a reference
  that no longer exists).
- Allocator alignment contract: every path (raw runtime, SystemAllocator,
  arena) returns a 16-byte-aligned payload — the block base is 16-aligned
  and the header is 16 bytes, so payload = base + 16 is 16-aligned;
  asserted by tests/allocator_alignment_test.tg.
- Crypto KAT: tests/unit/test_crypto_rigor.tg exercises every primitive in
  std/crypto.tg against its published known-answer vectors (sha256, hmac,
  aes, hex, base64, ...) — a REQUIRED CI job (crypto-kat).
- Doctest discipline: docs/current/language.md, grammar.md,
  memory_model.md, stabilized_subset.md, feature_matrix.md and
  feature_registry.md are checked by scripts/check_doctests.sh — every
  \`\`\`tangerine / unlabeled fenced example is canonical-form (the
  structural forbidden-syntax scan; compiler mode when a probe-validated
  binary exists) or annotated \`compile_fail: <expected diagnostic>\`
  with the annotation machine-verified — a REQUIRED CI job (doctests).
- Canary suites (tests/canary, tests/canary_neg, tests/arm64) hold the
  three-way parity (declared count == listed == discovered) with
  $POS, $NEG and $ARM files respectively; the acceptance-test additions
  (allocator_churn/large/oom/reuse/threaded, verifier_projection_tests,
  the three canary_neg additions, the alignment and atomic-litmus tests)
  are manifest-registered; their execution numbers live in the CI jobs
  that ran this SHA, not in this file.

STRUCTURAL FACTS (greps run by scripts/gen_status.sh against this tree):
EOF
  if [ "$fail" -eq 0 ]; then
    echo "  all facts [ok]"
  else
    echo "  one or more facts MISSING (see the stderr lines above)"
  fi

  cat <<EOF

TO REGENERATE THIS FILE (generated-by instructions):
  1. CI: the \`status\` job (in .github/workflows/ci.yml) runs after the
     test jobs, checks out the TESTED SHA, downloads the test artifacts
     (bootstrap fingerprints + native-tests, cross-lane binaries), and
     generates this snapshot:
         ./scripts/gen_status.sh --artifacts build/.status_artifacts \\
             build/.status_artifacts/STATUS.txt
     then uploads it as the \`status-snapshot\` artifact. The committed
     STATUS.txt is the SHA-independent source-state description and is
     NEVER regenerated from a commit (a committed snapshot is stale the
     moment it lands).
  2. Locally, the same command with the artifact dirs of a real run
     reproduces the artifact form; the committed file's structural facts
     are re-verifiable by running:
         ./scripts/gen_status.sh /tmp/status-check.txt
     (exit 0 = every fact still holds; the file is the artifact form).
  3. The harness constants and the structural facts are re-derived from
     the tree at the tested SHA; the per-suite "N/M passed" numbers and
     the stage2 == stage3 verdict live in the CI job logs, not in this
     file.

HARNESS CONSTANTS (read from scripts/bootstrap_helpers.sh at generation):
  CANARY_SUITE_POSITIVE_COUNT=$POS
  CANARY_SUITE_NEGATIVE_COUNT=$NEG   (includes the three 2026-08 canaries:
  canary_neg_ref_pattern, canary_neg_ring_buffer_peek_string,
  canary_neg_ring_buffer_peek_resource)
  CANARY_SUITE_ARM64_COUNT=$ARM
  The harness's four-way check (declared == listed == discovered ==
  constant) fails until the manifests and the constants agree.

KNOWN ISSUES RECORDED BY THE 2026-08 AUDIT (verification only; fixes
outside the docs/STATUS/tests edit scope are tracked here):
  - tests/layout_tests.tg, tests/canary/* and tests/canary_neg/* were
    verified structurally (block balance, manifest parity) in earlier
    snapshots; execution evidence for this SHA lives in the CI jobs.
  - The former "Reviewer item 100 +:" comment token in tg_compiler/mir.tg
    is FIXED (no reviewer-item token remains — verified by grep).
EOF
} > "$OUT"

echo "wrote $OUT (commit $SHA, positive=$POS negative=$NEG arm64=$ARM)"
exit "$fail"
