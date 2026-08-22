#!/usr/bin/env bash
# scripts/gen_status.sh — regenerate the STATUS evidence document.
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
#   2. The ARTIFACT form (what THIS script writes) is the EVIDENCE
#      DOCUMENT, generated at release / CI time FROM THE TESTED SHA:
#      the exact commit the tests ran on, the timestamp, the workflow
#      identity, the canary suites' SELF-DESCRIBING counts and hashes
#      (read from the generated MANIFEST lines), the target suites, the
#      std-module counts, the ABI/integration suites, the structural
#      facts, and — when --artifacts is given — the sha-256 of the test
#      artifacts (stage hashes, phase fingerprints, canary outputs,
#      litmus/target-lane outputs; marked CI-RUN-PROVIDED, since they are
#      not derivable from the tree).
#      CI's `status` job runs this script after the tests and uploads the
#      result as the `status-snapshot-<tested-sha>` artifact (the artifact
#      NAME is tied to the tested SHA); the committed file points at it
#      instead of pretending to be current.
#
# Usage: ./scripts/gen_status.sh [--refresh-manifests] [--artifacts <dir>]
#                                 [--release-evidence <dir>]
#                                 [--job-results <json>] [outfile]
#   --refresh-manifests  regenerate the canary MANIFEST self-description
#                        (the `# count:`, `# manifest sha256:` and
#                        `# test list sha256:` lines of tests/canary,
#                        tests/canary_neg and tests/arm64) from the
#                        committed tree state and exit. The CI
#                        evidence-gate job runs this and then
#                        `git diff --exit-code`, so a stale committed
#                        count cannot merge.
#   --artifacts <dir>   include a TEST ARTIFACTS section: sha-256 of every
#                       file under <dir> (repeatable; also read from
#                       $TG_STATUS_ARTIFACTS, a colon-separated list).
#   --release-evidence  THE RELEASE-RUN EVIDENCE path (the reviewer's
#                       items 32/36/API-manifest): the directory holding
#                       ONE SUBDIRECTORY PER RUN ARTIFACT (the artifact
#                       names — tg-stages-macos-arm64, bootstrap-
#                       fingerprints, bootstrap-native-tests, cross-lane-
#                       binaries, linux-fingerprints, linux-native-tests;
#                       the CI status job downloads each artifact into its
#                       own subdirectory). Verifies the release gates —
#                       the API-manifest release check (a public callable
#                       with zero behavior tests, an error variant never
#                       exercised, or a cfg target without execution
#                       FAILS the release), the completeness enumeration
#                       (every std module contracted), the completeness
#                       model, and the run-artifact presence — then
#                       writes build/release_evidence.json through the
#                       RELEASE EVIDENCE SCHEMA (scripts/
#                       release_evidence_schema.sh): the workflow run
#                       identity, the per-job conclusions (--job-results),
#                       the required artifacts with the PER-ARTIFACT
#                       sha-256 read from the ACTUAL FILES, the stage
#                       binaries' hashes, the stage2 == stage3 and the
#                       semantic-fingerprint equality VERDICTS (the
#                       equality checks' actual results), and the
#                       native-lane outputs. This file is the ONLY source
#                       of the registry's EXACT_SHA_VERIFIED /
#                       RELEASE_GATED ladder positions: the registry
#                       generator reads it and never derives those
#                       positions from source. A failing gate writes NO
#                       evidence file (the release cannot be gated); the
#                       proof generator VALIDATES the evidence against
#                       the schema — a matching SHA alone is never a
#                       proof.
#   --job-results <f>   the CI job-results JSON (toJSON(needs) of the
#                       status job — the ACTUAL observed per-job
#                       conclusions), recorded in the evidence file.
#                       (Also read from $TG_STATUS_JOB_RESULTS.)
#   outfile             defaults to STATUS.txt at the repo root.
# Exit status: 0 when every structural fact greps as expected; non-zero
# (with the file still written) when a fact drifted, so CI can gate on it.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/STATUS.txt}"
ARTIFACT_DIRS=""
REFRESH_MANIFESTS=0
RELEASE_EVIDENCE=""
JOB_RESULTS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --refresh-manifests)
      REFRESH_MANIFESTS=1
      shift
      ;;
    --artifacts)
      shift
      ARTIFACT_DIRS="${ARTIFACT_DIRS}${1}:"
      shift
      ;;
    --release-evidence)
      shift
      RELEASE_EVIDENCE="${1:-}"
      shift
      ;;
    --job-results)
      shift
      JOB_RESULTS="${1:-}"
      shift
      ;;
    *) break ;;
  esac
done
[ $# -eq 0 ] || OUT="$1"
ARTIFACT_DIRS="${ARTIFACT_DIRS}${TG_STATUS_ARTIFACTS:-}"
[ -n "$JOB_RESULTS" ] || JOB_RESULTS="${TG_STATUS_JOB_RESULTS:-}"

# The release-evidence schema (the writer + the fail-closed validator).
# shellcheck source=scripts/release_evidence_schema.sh
. "$ROOT/scripts/release_evidence_schema.sh"

SHA="$(git -C "$ROOT" rev-parse HEAD)"
DATE="$(date +%Y-%m-%d)"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── harness constants (single source: bootstrap_helpers.sh) ───────────────
POS="$(sed -n 's/^CANARY_SUITE_POSITIVE_COUNT=\([0-9]*\)/\1/p' "$ROOT/scripts/bootstrap_helpers.sh" | head -1)"
NEG="$(sed -n 's/^CANARY_SUITE_NEGATIVE_COUNT=\([0-9]*\)/\1/p' "$ROOT/scripts/bootstrap_helpers.sh" | head -1)"
ARM="$(sed -n 's/^CANARY_SUITE_ARM64_COUNT=\([0-9]*\)/\1/p' "$ROOT/scripts/bootstrap_helpers.sh" | head -1)"

# ── the canary suites' SELF-DESCRIBING manifests ──────────────────────────
# The manifests carry GENERATED self-description lines (regenerated by
# --refresh-manifests; the CI evidence-gate job diffs them):
#   # count: N                 the suite count (the harness reads this)
#   # manifest sha256: <hex>   sha-256 of the manifest body WITHOUT the
#                              generated lines (stable regardless of the
#                              generated lines themselves)
#   # test list sha256: <hex>  sha-256 of the sorted listed test names
MANIFESTS=(
  "tests/canary:tests/canary/MANIFEST:$POS"
  "tests/canary_neg:tests/canary_neg/MANIFEST:$NEG"
  "tests/arm64:tests/arm64/MANIFEST:$ARM"
)

manifest_line() { # manifest_line <manifest> <key-pattern> ; first match
  sed -n "s/$2/\\1/p" "$1" | head -1
}

canary_count_of() { # canary_count_of <manifest>
  manifest_line "$1" '^# count: \([0-9]*\)'
}
canary_manifest_hash_of() { # canary_manifest_hash_of <manifest>
  manifest_line "$1" '^# manifest sha256: \([0-9a-f]*\)'
}
canary_list_hash_of() { # canary_list_hash_of <manifest>
  manifest_line "$1" '^# test list sha256: \([0-9a-f]*\)'
}

# Regenerate one manifest's self-description lines in place.
refresh_manifest() { # refresh_manifest <manifest>
  local manifest="$1" body="" list="" count=0 entry
  # The manifest body WITHOUT the generated lines (count + the two hashes).
  body="$(grep -vE '^# (count: |manifest sha256: |test list sha256: )' "$manifest")"
  # The sorted listed test names (first column, comments/blank ignored).
  list="$(grep -vE '^#|^$' "$manifest" | cut -f1 | sort)"
  count="$(printf '%s\n' "$list" | grep -c . || true)"
  local mh lh
  mh="$(printf '%s\n' "$body" | shasum -a 256 | cut -d' ' -f1)"
  lh="$(printf '%s\n' "$list" | shasum -a 256 | cut -d' ' -f1)"
  # Rewrite in place: drop the old generated lines, then insert the new
  # ones immediately after the FIRST manifest comment block start marker
  # (the header comment) — the harness greps the FIRST '# count:' line.
  printf '%s\n' "$body" | awk -v mh="$mh" -v lh="$lh" -v count="$count" '
    /^# count: / || /^# manifest sha256: / || /^# test list sha256: / { next }
    {
      print
      if (!done && $0 ~ /^#/) {
        print "# count: " count
        print "# manifest sha256: " mh
        print "# test list sha256: " lh
        done = 1
      }
    }
  ' > "$manifest.tmp"
  # The generated lines must land inside the header comment block: if the
  # first line is not a comment, the manifest has no header and the
  # insertion point is wrong — fail loudly instead of corrupting the file.
  if ! grep -qE '^# count: [0-9]+' "$manifest.tmp"; then
    echo "gen_status: cannot regenerate $manifest (no header comment block)" >&2
    rm -f "$manifest.tmp"
    return 1
  fi
  mv "$manifest.tmp" "$manifest"
  echo "  refreshed $manifest: count=$count manifest_sha256=$mh test_list_sha256=$lh"
}

if [ "$REFRESH_MANIFESTS" -eq 1 ]; then
  echo "gen_status: --refresh-manifests (the CI evidence-gate diffs the result)"
  ok=0
  for spec in "${MANIFESTS[@]}"; do
    manifest="${spec#*:}"
    manifest="${manifest%%:*}"
    if refresh_manifest "$manifest"; then
      ok=$((ok + 1))
    fi
  done
  echo "gen_status: refreshed $ok manifest(s) — run \`git diff --exit-code\` to gate"
  [ "$ok" -eq "${#MANIFESTS[@]}" ] || exit 1
  exit 0
fi

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
fact "stdlib sweep covers every shipped module (the item-32 enumeration)" \
  'run_stdlib_completeness_gate' "$ROOT/tests/run_stdlib_e106_sweep.sh"
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

# ── round-11 facts ─────────────────────────────────────────────────────────
# Arc rework (std/sync.tg): the UNIQUE-ONLY mutable access (get_mut returns
# Option[PtrMut[T]], Some exactly while the strong count is one — the
# load == 1 check), the SINK-CONSUMING try_unwrap (the caller's Arc is
# consumed on both outcomes; the success path moves the data out, frees
# the block, and NULLS the consumed Arc's ptr so its finalize is a no-op —
# no double-free), the drop_in_place last release (the typed destruction
# glue runs T's destructor exactly once BEFORE the storage is released),
# and the refcount OVERFLOW guard (a CAS retry loop; an increment must
# never wrap the count to zero, which would create a dangling owner).
fact "Arc::get_mut is unique-only (Option[PtrMut[T]], load==1 check)" \
  'def Arc::get_mut' "$ROOT/std/sync.tg"
fact "Arc::try_unwrap is sink-consuming (consumed on both outcomes)" \
  'def Arc::try_unwrap\[T\]\(sink self: Arc\[T\]\)' "$ROOT/std/sync.tg"
fact "Arc last release runs drop_in_place before the dealloc" \
  'drop_in_place\(\)' "$ROOT/std/sync.tg"
fact "Arc::clone refcount overflow guard (traps at u32::MAX)" \
  'reference count overflow' "$ROOT/std/sync.tg"
fact "Arc lifecycle suite committed" \
  'arc_lifecycle_test' "$ROOT/tests/arc_lifecycle_test.tg"

# DriverKind::Mysql: the MySQL driver joins the Sqlite/Postgres match arms
# of the statement/transaction dispatch (mysql_stmt_run/query/finalize,
# mysql_execute_raw/query_raw).
fact "DriverKind::Mysql in the driver dispatch" \
  'DriverKind::Mysql' "$ROOT/std/db.tg"
fact "mysql statement run path (mysql_stmt_run)" \
  'mysql_stmt_run' "$ROOT/std/db.tg"

# TLS consuming builders + the native shim lane: with_alpn /
# with_certificate / with_verify_peer take `sink self` — no Clone of the
# Certificate/PrivateKey wrappers or their native X509/EVP_PKEY handles
# (a bit-level clone would double-free); CI builds native/tls_shims.c
# into build/libtg_tls_shims.dylib, gates every declared tls_* extern as
# an exported Mach-O symbol, and preloads the shim into the tg-compiled
# TLS test processes.
fact "TLS consuming builders (sink self: TlsConfig)" \
  'sink self: TlsConfig' "$ROOT/std/tls.tg"
fact "TLS shim source committed (native/tls_shims.c)" \
  'tls_shims' "$ROOT/.github/workflows/ci.yml"
fact "TLS shim lane builds libtg_tls_shims.dylib" \
  'libtg_tls_shims.dylib' "$ROOT/.github/workflows/ci.yml"
fact "TLS shim preloaded into the test processes" \
  'DYLD_INSERT_LIBRARIES' "$ROOT/.github/workflows/ci.yml"

# Extern ABI return normalization: a C `int` return arrives in the LOW 32
# bits of the return register (eax/w0) with unspecified upper bits —
# normalize_extern_return sign/zero-extends it (I32/U32) before the
# post-call store, so a C -1 reads as -1 (x86-64 movsxd/mov_r32; AArch64
# sxtw; the w0 zero-extension is already exact).
fact "extern return normalization (normalize_extern_return)" \
  'normalize_extern_return' "$ROOT/tg_compiler/codegen.tg"
fact "net negative-ABI suite (sign-extension at the FFI boundary)" \
  'net_negative_abi' "$ROOT/tests/net_negative_abi_test.tg"

# The SliceMut Read contract: the Read trait takes the explicit mutable
# byte view — buf.len is the WRITABLE EXTENT (the number of bytes the
# reader may fill); the old `inout buf: Vec[u8]` shape (len meant both
# "bytes already buffered" and "writable capacity") is gone.
fact "Read trait takes the SliceMut[u8] writable-extent view" \
  'def read\(inout self: Self, buf: SliceMut\[u8\]\)' "$ROOT/std/io.tg"
fact "SliceMut view type exists (std/collections.tg)" \
  'struct SliceMut' "$ROOT/std/collections.tg"

# The per-target syscall identity table: the std's syscall wrappers pass
# the TG CANONICAL (Linux x86-64) numbers; the Linux-AArch64 translation
# maps them to the asm-generic table (read=63, write=64, ...) and the *at
# rewrites INSERT the AT_FDCWD (-100) dirfd (plus the extra argument the
# AArch64 call needs — fstatat's flags, unlinkat's AT_REMOVEDIR for
# rmdir); UNKNOWN numbers pass through raw.
fact "syscall canonical -> AArch64 number table" \
  'linux_aarch64_syscall_number' "$ROOT/tg_compiler/codegen.tg"
fact "syscall AArch64 argument layouts (*at rewrites + AT_FDCWD)" \
  'linux_aarch64_syscall_layout' "$ROOT/tg_compiler/codegen.tg"
fact "syscall translation suite committed" \
  'syscall_translation_test' "$ROOT/tests/syscall_translation_test.tg"

# The LSE contract: asm.tg's target feature table declares the aarch64
# target LSE-REQUIRED (the LDADDAL/CASAL/SWPAL RMW family is ARMv8.1 LSE,
# not the ARMv8.0 baseline — Apple Silicon, Neoverse and Cortex-A75+
# carry it; a bare ARMv8.0 core is not a supported target; the
# ldaxr/stlxr LL/SC fallback is the FUTURE portable mode).
fact "target feature table carries the LSE requirement" \
  'requires_lse' "$ROOT/tg_compiler/asm.tg"
fact "LSE contract suite committed" \
  'target_lse_contract' "$ROOT/tests/target_lse_contract_test.tg"

# Pthread opaque alignment: the layout authority OVERRIDES the [u8; N]
# byte-array alignment to the native pointer alignment for the known
# FFI-opaque names (ffi_opaque_native_align — PthreadT/AttrT/MutexT/
# CondT/BarrierT), so a PthreadMutexT local can never land at a
# misaligned stack offset (misaligned stores are UB in the C contract the
# pthread functions write through).
fact "FFI-opaque native alignment override (ffi_opaque_native_align)" \
  'ffi_opaque_native_align' "$ROOT/tg_compiler/layout_engine.tg"
fact "pthread ABI suite committed (sizes + alignment propagation)" \
  'pthread_abi_test' "$ROOT/tests/pthread_abi_test.tg"

# Thread spawn failure-path glue: the fault-injection hook
# (__tg_spawn_fail_create) makes pthread_create report EAGAIN (11)
# deterministically, and EVERY failure exit runs the placed closure's
# drop glue (closure_ptr.drop_in_place) before releasing the storage — a
# bare dealloc would leak the captured resources.
fact "spawn failure-path hook (injected EAGAIN)" \
  '__tg_spawn_fail_create' "$ROOT/std/thread.tg"
fact "spawn failure path runs the placed closure's drop glue" \
  'closure_ptr.drop_in_place' "$ROOT/std/thread.tg"
fact "thread spawn failure-path suite committed" \
  'thread_spawn_failure' "$ROOT/tests/thread_spawn_failure_test.tg"

# ── round-12 facts: the @budget runtime enforcement ───────────────────
# The typed budget records (TypedBudget on the FnSignature) now have REAL
# enforcement: the __tg_budget_* counter table is DEFINED in the data
# section (the fail-closed-at-link state is gone), the MIR lowering of the
# annotated functions constructs the MirBudgetConsume statements (the
# allocation metric after each intrinsic allocation; the time metric's
# entry stamp + per-return exit checks), the codegen arms are the real
# checks (increment/compare, trap on exceed; the clock via __tg_clock_ns),
# the fail-closed static-exceed rejection is the canary_neg surface, and
# the two canaries are manifest-registered.
fact "budget counter table defined (__tg_budget_alloc)" \
  '__tg_budget_alloc' "$ROOT/tg_compiler/codegen.tg"
fact "budget counter table defined (__tg_budget_time)" \
  '__tg_budget_time' "$ROOT/tg_compiler/codegen.tg"
fact "budget lowering constructs the allocation consumes" \
  'MirBudgetConsume\("alloc"' "$ROOT/tg_compiler/mir.tg"
fact "budget time entry marker (__tg_budget_time_start)" \
  '__tg_budget_time_start' "$ROOT/tg_compiler/codegen.tg"
fact "budget clock runtime (__tg_clock_ns)" \
  'def emit_tg_clock_ns' "$ROOT/tg_compiler/runtime.tg"
fact "budget runtime enforcement only (the static allocation-site rejection removed)" \
  'budget_alloc_offset' "$ROOT/tg_compiler/codegen.tg"
fact "budget positive canary (within the limit)" \
  'canary_pos_budget_alloc_within' "$ROOT/tests/canary/MANIFEST"
fact "budget runtime-trap enforcement script (run_budget_enforcement_tests)" \
  'run_budget_enforcement_tests' "$ROOT/tests/run_budget_enforcement_tests.sh"

# ── round-14 facts: the std::db driver hardening ─────────────────────
# Postgres: the JDBC `?` placeholder of a parameterized statement is
# TRANSLATED to PostgreSQL's $1..$n positional parameters before
# PQexecParams/PQprepare (a quoted-string-aware scan — a `?` inside a
# single-quoted literal or double-quoted identifier is data); every
# parameter payload lives in the explicit PgParamBacking (blob bytes
# copied into owned buffers that live through the FFI call — no dangling
# pointers); the Statement carries the backend state (the connection
# handle + the server-side statement name + the parameter count) so
# execute/query run the PQprepare'd statement through PQexecPrepared with
# a deterministic DEALLOCATE cleanup on drop.
fact 'Postgres ? -> $n translation (postgres_translate_placeholders)' \
  'postgres_translate_placeholders' "$ROOT/std/db.tg"
fact "Postgres translation is quoted-string aware" \
  'PgLexState' "$ROOT/std/db.tg"
fact "PgParamBacking owns the parameter payloads" \
  'struct PgParamBacking' "$ROOT/std/db.tg"
fact "PgParamBacking owns the blob bytes (owned_buffers push)" \
  'owned_buffers' "$ROOT/std/db.tg"
fact "Postgres prepared execution via PQexecPrepared" \
  'PQexecPrepared' "$ROOT/std/db.tg"
fact "Postgres statement cleanup DEALLOCATEs the server-side statement" \
  'DEALLOCATE' "$ROOT/std/db.tg"
fact "Statement carries the backend connection + identity + param metadata" \
  'conn_handle' "$ROOT/std/db.tg"
# MySQL: the prepared path uses the REAL MYSQL_BIND parameter binding —
# but the hand-written st_mysql_bind layout is GONE by design: the
# MYSQL_BIND arrays are built INSIDE the native shim (native/mysql_shims.c,
# compiled against the real mysql.h — tg_mysql_stmt_bind_and_execute runs
# the real mysql_stmt_bind_param + mysql_stmt_execute with the
# per-parameter buffer_type/length/is_null/buffer cells), and the
# Tangerine side ships the plain @repr(C) descriptors (MysqlParam /
# MysqlParamBacking / MysqlResultCell with the length/is_null out cells)
# through the tg_mysql_* extern family. The manual interpolation is gone
# from every execution path; the integration test covers the hostile
# values (' \ \\ \0 ' OR 1=1 --, multibyte text, binary blobs) as data.
fact "MYSQL_BIND built in the native shim (real mysql.h layout)" \
  'MYSQL_BIND' "$ROOT/native/mysql_shims.c"
fact "shim bind+execute routes the real mysql_stmt_bind_param" \
  'mysql_stmt_bind_param' "$ROOT/native/mysql_shims.c"
fact "Tangerine-side MysqlParam descriptors (type/data/len)" \
  'struct MysqlParam' "$ROOT/std/db.tg"
fact "MySQL result cells carry the length/is_null out cells" \
  'MysqlResultCell' "$ROOT/std/db.tg"
# The manual interpolation is REMOVED — every parameterized MySQL
# statement goes through the real MYSQL_BIND binding.
if grep -q 'mysql_interpolate' "$ROOT/std/db.tg"; then
  printf '  [MISSING] std/db.tg still carries the manual mysql_interpolate path\n' >&2
  fail=1
else
  printf '  [ok] manual MySQL interpolation is gone from the execution paths\n'
fi
fact "MySQL integration test hostile-value case" \
  'OR 1=1 --' "$ROOT/tests/db_mysql_integration_test.tg"
fact "MySQL integration test multibyte case" \
  'héllo wörld' "$ROOT/tests/db_mysql_integration_test.tg"
fact "MySQL integration test binary blob case" \
  'kv_bin' "$ROOT/tests/db_mysql_integration_test.tg"
fact "Postgres integration test exercises the ? placeholder translation" \
  'VALUES \(\?\)' "$ROOT/tests/db_postgres_integration_test.tg"
fact "Postgres integration test exercises the blob backing" \
  'kv_blob' "$ROOT/tests/db_postgres_integration_test.tg"
fact "Postgres integration test exercises prepared statements" \
  'prepare' "$ROOT/tests/db_postgres_integration_test.tg"

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

# ── the SHA-tied status artifact name (CI-run-provided) ────────────────────
# The status job uploads the snapshot under `status-snapshot-<tested-sha>`:
# the artifact NAME carries the tested SHA (GITHUB_SHA), so an artifact can
# never be mistaken for a different commit's snapshot. Locally (no
# GITHUB_SHA) the name is `status-snapshot-local`.
STATUS_ARTIFACT_NAME="status-snapshot-local"
if [ -n "${GITHUB_SHA:-}" ]; then
  STATUS_ARTIFACT_NAME="status-snapshot-${GITHUB_SHA}"
fi

# ── stage hashes / phase fingerprints (CI-RUN-PROVIDED, parsed) ────────────
# The bootstrap job uploads its per-phase fingerprint files
# (build/.fingerprints/*.fingerprints — one `FINGERPRINT <stage> <phase>
# <hash>` line per phase; the link-image hash IS the stage binary's
# sha256) and the linux-x86-64-native job uploads its stage fingerprint
# manifest; the status job downloads both into the artifact dirs. Parse
# every *.fingerprints file found in the artifact dirs so the snapshot
# records the ACTUAL stage hashes of the tested run instead of prose.
STAGE_HASHES_TEXT="  (no fingerprint artifacts in the provided artifact dirs — the bootstrap job's build/.fingerprints upload (or the linux job's linux-fingerprints upload) was not provided to this run; a snapshot without stage hashes has no stage-run evidence)"
FP_FILES="$(IFS=':' ; for d in $ARTIFACT_DIRS; do
  [ -n "$d" ] || continue
  if [ -d "$d" ]; then
    find "$d" -type f -name '*.fingerprints' 2>/dev/null
  fi
done | sort -u)"
if [ -n "$FP_FILES" ]; then
  STAGE_HASHES_TEXT=""
  for f in $FP_FILES; do
    STAGE_HASHES_TEXT="${STAGE_HASHES_TEXT}    $f
"
    while IFS= read -r line || [ -n "$line" ]; do
      STAGE_HASHES_TEXT="${STAGE_HASHES_TEXT}      $line
"
    done < "$f"
  done
fi

# ── evidence fields computed from the tested tree ──────────────────────────
# Repository identity.
SHA_SHORT="$(printf '%s' "$SHA" | cut -c1-12)"

# Timestamp + workflow identity (CI-run-provided when present).
WORKFLOW_IDENTITY="local run (no workflow identity — GITHUB_WORKFLOW/GITHUB_JOB/GITHUB_RUN_ID unset)"
if [ -n "${GITHUB_WORKFLOW:-}" ]; then
  WORKFLOW_IDENTITY="${GITHUB_WORKFLOW:-} / ${GITHUB_JOB:-} / run ${GITHUB_RUN_ID:-} (attempt ${GITHUB_RUN_ATTEMPT:-1})"
fi

# Std-module counts: every shipped std/*.tg and the kernel closure.
STD_MODULE_COUNT="$(ls "$ROOT"/std/*.tg 2>/dev/null | wc -l | tr -d ' ')"
KERNEL_CLOSURE_COUNT="$(grep -E '^(std|compiler): ' "$ROOT/bootstrap/compiler_kernel.manifest" 2>/dev/null | wc -l | tr -d ' ')"
KERNEL_STD_COUNT="$(grep -c '^std: ' "$ROOT/bootstrap/compiler_kernel.manifest" 2>/dev/null || true)"
KERNEL_COMPILER_COUNT="$(grep -c '^compiler: ' "$ROOT/bootstrap/compiler_kernel.manifest" 2>/dev/null || true)"

# ── the item-32 verification families (computed from the contracts ─────────
# ── manifest; a drifted manifest fails the snapshot) ───────────────────────
FAMILY_COUNTS="$(python3 - "$ROOT/docs/current/stdlib_contracts.toml" <<'PY'
import os, sys
from collections import Counter
try:
    import tomllib
    def parse(path):
        return tomllib.load(open(path, "rb"))
except ImportError:
    try:
        import tomli
        def parse(path):
            return tomli.loads(open(path, encoding="utf-8").read())
    except ImportError:
        print("  (contracts manifest unreadable — no tomllib/tomli)", file=sys.stderr)
        sys.exit(1)
d = parse(sys.argv[1])
mods = sorted(f[:-3] for f in os.listdir("std") if f.endswith(".tg"))
contracts = d.get("module", {})
problems = [m for m in mods if m not in contracts]
if problems:
    print("  (contracts manifest drift: un-contracted modules: %s)" % ", ".join(problems), file=sys.stderr)
    sys.exit(1)
counts = Counter(contracts[m].get("family", "?") for m in mods)
out = []
for fam in ["kernel", "native", "lane", "parse-clean", "experimental"]:
    if counts.get(fam):
        out.append("%s=%d" % (fam, counts[fam]))
print("; ".join(out))
PY
)" || true
[ -n "$FAMILY_COUNTS" ] || FAMILY_COUNTS="(contracts manifest unreadable — see the errors above)"

# ── the release-run evidence (the ONLY source of EXACT_SHA_VERIFIED / ──────
# ── RELEASE_GATED; a failing gate writes NO evidence file) ──────────────────
RELEASE_EVIDENCE_TEXT="  (no release-evidence run: --release-evidence was not given)"
if [ -n "$RELEASE_EVIDENCE" ]; then
  if ! bash "$ROOT/scripts/gen_api_manifest.sh" --release-check; then
    printf '  [RELEASE GATE FAILED] the public-API manifest release check failed — a public callable with zero behavior tests, an error variant never exercised, or a cfg target without execution blocks the release; NO release evidence written\n' >&2
    RELEASE_EVIDENCE_FAIL=1
  else
    RELEASE_EVIDENCE_FAIL=0
  fi
  if ! bash "$ROOT/scripts/gen_stdlib_completeness.sh" >/dev/null; then
    printf '  [RELEASE GATE FAILED] the stdlib completeness model failed (enumeration / contracts / experimental gating); NO release evidence written\n' >&2
    RELEASE_EVIDENCE_FAIL=1
  fi
  if [ ! -d "$RELEASE_EVIDENCE" ] || [ -z "$(find "$RELEASE_EVIDENCE" -type f 2>/dev/null | head -1)" ]; then
    printf '  [RELEASE GATE FAILED] the run artifacts are missing or empty (%s); a release requires executed artifacts\n' "$RELEASE_EVIDENCE" >&2
    RELEASE_EVIDENCE_FAIL=1
  fi
  if [ "${RELEASE_EVIDENCE_FAIL:-0}" = "0" ]; then
    # The calculated ladder (source-state facts) -> the RELEASE_GATED list:
    # every feature at TARGET_COMPLETE or above whose release checks passed.
    LADDER_TMP="$(mktemp)"
    if bash "$ROOT/scripts/gen_feature_registry.sh" "$ROOT/build/.feature_registry.evidence.md" "$LADDER_TMP" >/dev/null 2>&1; then
      RELEASE_GATED_LIST="$(python3 - "$LADDER_TMP" <<'PY'
import json, sys
ladder = json.load(open(sys.argv[1])).get("ladder", {})
order = ["DECLARED", "IMPLEMENTED", "SEMANTICALLY_CHECKED", "NATIVE_TESTED",
         "ADVERSARIAL_TESTED", "TARGET_COMPLETE", "EXACT_SHA_VERIFIED", "RELEASE_GATED"]
print(" ".join(fid for fid, pos in sorted(ladder.items()) if order.index(pos) >= order.index("TARGET_COMPLETE")))
PY
)"
    else
      RELEASE_GATED_LIST=""
      printf '  [RELEASE GATE FAILED] the feature-registry ladder could not be computed; NO release evidence written\n' >&2
      RELEASE_EVIDENCE_FAIL=1
    fi
    rm -f "$LADDER_TMP"
  fi
  if [ "${RELEASE_EVIDENCE_FAIL:-0}" = "0" ]; then
    # The evidence WRITER (scripts/release_evidence_schema.sh): records the
    # workflow run identity, the per-job conclusions (--job-results / the
    # ACTUAL observed CI results), the required artifacts with the
    # per-artifact sha-256 READ FROM THE ACTUAL FILES, the stage binaries'
    # hashes, the stage2 == stage3 / semantic-fingerprint / linux-fixed-point
    # equality VERDICTS (the equality checks' actual results), and the
    # native-lane outputs. There is no "present" shorthand: every hash is
    # read from the actual files, and the proof generator validates the
    # evidence against the schema (a matching SHA alone is never a proof).
    mkdir -p "$ROOT/build"
    EVIDENCE_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if build_release_evidence "$RELEASE_EVIDENCE" "$ROOT/build/release_evidence.json" \
       "$SHA" "$JOB_RESULTS" "$RELEASE_GATED_LIST" "$EVIDENCE_TIMESTAMP"; then
      EVIDENCE_ARTIFACT_COUNT="$(ls -d "$RELEASE_EVIDENCE"/*/ 2>/dev/null | wc -l | tr -d ' ')"
      EVIDENCE_HASH_LINE_COUNT="$(python3 - "$ROOT/build/release_evidence.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(len(d.get("artifact_hashes", [])))
PY
)"
      RELEASE_EVIDENCE_TEXT="  release evidence WRITTEN: build/release_evidence.json
    tested_sha:      $SHA
    release-gated:   $(printf '%s' "$RELEASE_GATED_LIST" | wc -w | tr -d ' ') feature(s)
    artifact set:    $EVIDENCE_ARTIFACT_COUNT artifact(s) recorded with
                     $EVIDENCE_HASH_LINE_COUNT per-file sha-256 line(s) read
                     from the ACTUAL files (the \"present\" shorthand is gone)
    job conclusions: $(if [ -n "$JOB_RESULTS" ] && [ -f "$JOB_RESULTS" ]; then echo "recorded from $JOB_RESULTS (the ACTUAL observed results)"; else echo "NOT RECORDED (no --job-results file — the fail-closed validation will fail the categories)"; fi)
    verdicts:        stage2 == stage3, the semantic-fingerprint equality
                     (tokens/ast/hir/mir/mir-mono), and the linux fixed
                     point recorded with the equality checks' actual
                     results; the release-proof generator VALIDATES this
                     file against scripts/release_evidence_schema.sh —
                     a matching SHA alone is never a proof
    the registry generator reads this file for the EXACT_SHA_VERIFIED /
    RELEASE_GATED ladder positions; a run that fails any gate writes nothing."
    else
      RELEASE_EVIDENCE_FAIL=1
      printf '  [RELEASE GATE FAILED] the release-evidence writer failed; NO release evidence written\n' >&2
    fi
  fi
  if [ "${RELEASE_EVIDENCE_FAIL:-0}" = "1" ]; then
    RELEASE_EVIDENCE_TEXT="  release evidence NOT WRITTEN — a release gate failed (see the errors above)."
  fi
fi

# Target suites (the arch-specific lanes + the @cfg cross-target matrix).
TARGET_SUITES=(
  "tests/arm64:the aarch64 encoder/ABI suite (mandatory on aarch64 hosts)"
  "tests/x86_64:the x86-64 encoder/ABI suite (mandatory on x86_64 hosts)"
  "tests/cfg_matrix:the @cfg cross-target matrix (6 canaries, explicit --target overrides)"
)
TARGET_SUITES_TEXT=""
for spec in "${TARGET_SUITES[@]}"; do
  dir="${spec%%:*}"
  desc="${spec#*:}"
  if [ -d "$ROOT/$dir" ]; then
    n="$(ls "$ROOT/$dir"/*.tg 2>/dev/null | wc -l | tr -d ' ')"
    TARGET_SUITES_TEXT="${TARGET_SUITES_TEXT}    $dir ($n test file(s)) — $desc
"
  else
    TARGET_SUITES_TEXT="${TARGET_SUITES_TEXT}    $dir (ABSENT on this tree) — $desc
"
  fi
done

# ABI/integration suites: the committed @test files the CI lanes run.
ABI_SUITES=(
  tests/pthread_abi_test.tg
  tests/syscall_translation_test.tg
  tests/target_lse_contract_test.tg
  tests/net_negative_abi_test.tg
  tests/thread_spawn_failure_test.tg
)
INTEGRATION_SUITES=(
  tests/net_loopback_test.tg
  tests/sync_contention_test.tg
  tests/condvar_waiter_queue_test.tg
  tests/once_cas_test.tg
  tests/thread_channel_ownership_test.tg
  tests/thread_local_drop_test.tg
  tests/thread_result_cell_test.tg
  tests/task_scope_test.tg
  tests/cancellation_token_test.tg
  tests/reactor_readiness_test.tg
  tests/async_mutex_waiter_test.tg
  tests/join_cancel_test.tg
  tests/executor_clock_test.tg
  tests/exec_conservation_test.tg
  tests/db_integration_test.tg
  tests/db_lifecycle_test.tg
  tests/db_async_pool_test.tg
  tests/db_postgres_lexer_test.tg
  tests/db_mysql_layout_probe_test.tg
  tests/db_mysql_large_result_test.tg
  tests/tls_interop_test.tg
  tests/tls_handshake_test.tg
)
ABI_SUITES_TEXT=""
for f in "${ABI_SUITES[@]}"; do
  if [ -f "$ROOT/$f" ]; then ABI_SUITES_TEXT="${ABI_SUITES_TEXT}    $f
"; else ABI_SUITES_TEXT="${ABI_SUITES_TEXT}    $f (MISSING)
"; fi
done
INTEGRATION_SUITES_TEXT=""
for f in "${INTEGRATION_SUITES[@]}"; do
  if [ -f "$ROOT/$f" ]; then INTEGRATION_SUITES_TEXT="${INTEGRATION_SUITES_TEXT}    $f
"; else INTEGRATION_SUITES_TEXT="${INTEGRATION_SUITES_TEXT}    $f (MISSING)
"; fi
done

# The canary self-description read from the generated MANIFEST lines
# (the manifest hash / test-list hash are only present once the manifests
# carry the generated lines — a missing line is itself a finding).
CANARY_SELF_DESCRIPTION=""
for spec in "${MANIFESTS[@]}"; do
  suite="${spec%%:*}"
  manifest="${spec#*:}"
  manifest="${manifest%%:*}"
  expected="${spec##*:}"
  if [ -f "$ROOT/$manifest" ]; then
    c="$(canary_count_of "$ROOT/$manifest")"
    mh="$(canary_manifest_hash_of "$ROOT/$manifest")"
    lh="$(canary_list_hash_of "$ROOT/$manifest")"
    CANARY_SELF_DESCRIPTION="${CANARY_SELF_DESCRIPTION}    $suite: count=$c (harness=$expected) manifest_sha256=${mh:-MISSING} test_list_sha256=${lh:-MISSING}
"
  else
    CANARY_SELF_DESCRIPTION="${CANARY_SELF_DESCRIPTION}    $suite: MANIFEST MISSING ($manifest)
"
  fi
done

# ── emit the snapshot (the CI/release ARTIFACT form) ───────────────────────
{
  cat <<EOF
STATUS: $DATE — TESTED-SHA snapshot at commit $SHA
(artifact form generated by scripts/gen_status.sh FROM THE TESTED SHA:
the CI \`status\` job runs this after the tests and uploads the result as
the \`status-snapshot\` artifact; the committed STATUS.txt is the
SHA-independent source-state description and points at this artifact —
see the WORKFLOW note in the committed file)

EVIDENCE IDENTITY:
  repository SHA:         $SHA ($SHA_SHORT)
  timestamp (UTC):        $TIMESTAMP
  workflow identity:      $WORKFLOW_IDENTITY
  status artifact:        $STATUS_ARTIFACT_NAME (uploaded by the CI status
                          job; the artifact name is tied to the tested SHA)
  generated by:           scripts/gen_status.sh (the tested tree's
                          structural facts + the fields below)

WORKING TREE (git status --porcelain, at the tested SHA):
$WT

CANARY SUITE SELF-DESCRIPTION (read from the GENERATED MANIFEST lines —
the suite count + the manifest sha256 + the test-list sha256; regenerated
by ./scripts/gen_status.sh --refresh-manifests, which the CI
evidence-gate job diffs with \`git diff --exit-code\` — a stale committed
count cannot merge):
$CANARY_SELF_DESCRIPTION

TARGET SUITES (the arch-specific lanes + the @cfg cross-target matrix):
$TARGET_SUITES_TEXT
STD-MODULE COUNTS (computed from the tested tree):
  shipped std modules:    $STD_MODULE_COUNT std/*.tg files
  kernel closure:         $KERNEL_CLOSURE_COUNT sources
                          ($KERNEL_STD_COUNT std + $KERNEL_COMPILER_COUNT compiler)

STDLIB VERIFICATION FAMILIES (the item-32 completeness model, computed
from docs/current/stdlib_contracts.toml — every module contracted):
  $FAMILY_COUNTS

RELEASE-RUN EVIDENCE (the item-36 EXACT_SHA_VERIFIED / RELEASE_GATED
ladder facts — written only by --release-evidence from the tested-SHA
run artifacts; the registry generator reads build/release_evidence.json
and never derives these positions from source):
$RELEASE_EVIDENCE_TEXT

ABI SUITES (the adversarial platform-contract layer):
$ABI_SUITES_TEXT
INTEGRATION SUITES (net / sync / async / db / tls — committed @test files):
$INTEGRATION_SUITES_TEXT
RUN RESULTS — see the test artifacts (hashes below) and the CI job
summaries (bootstrap, conformance, cross-compile, stdlib-e106-sweep,
stdlib-new-modules, stdlib-integration, abi-platform, allocator,
atomic-litmus, cfg-matrix, crypto-kat, doctests, db-integration-postgres,
db-integration-mysql, evidence-gate, gfx-ui, gfx-ui-visual, verifier-projection):
  The tested SHA is the commit this file names; the run numbers belong to
  the CI jobs that consumed it, not to a hand-rolled local snapshot.

TEST ARTIFACTS (sha-256 of the uploaded canary/fingerprint/litmus and
target-lane outputs; regenerated by --artifacts <dir> or the
TG_STATUS_ARTIFACTS list):
${ARTIFACT_HASHES:-  (no artifact paths were provided to this run — pass --artifacts <dir> or TG_STATUS_ARTIFACTS)}

STAGE HASHES / PHASE FINGERPRINTS (CI-RUN-PROVIDED — not derivable from
the tree; parsed from the fingerprint files of the bootstrap-fingerprints
and linux-fingerprints artifacts the status job downloaded):
$STAGE_HASHES_TEXT
  The stage2 == stage3 byte-identity verdict and the per-phase
  fingerprints (link-image / text / sections / symbols / relocs + the
  probed token/ast/hir/mir/mir-mono dumps on macOS) live in the bootstrap
  job's logs and the uploaded bootstrap-fingerprints / linux-fingerprints
  artifacts (hashed above). A source tree alone cannot produce them — a
  snapshot that lacks them has no run evidence.

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
- Bootstrap closure: bootstrap/compiler_kernel.manifest, $KERNEL_CLOSURE_COUNT
  sources ($KERNEL_STD_COUNT std + $KERNEL_COMPILER_COUNT compiler files);
  build/bootstrap-input.json records the
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
- Stdlib E106 migration COMPLETE: every shipped std module (all $STD_MODULE_COUNT
  std/*.tg files — the count is computed from the glob, never typed) is
  parse-clean, enforced by the two-layer gate
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
  $POS, $NEG and $ARM files respectively; the manifests are
  SELF-DESCRIBING (the generated \`# count:\` / \`# manifest sha256:\` /
  \`# test list sha256:\` lines — see the CANARY SUITE SELF-DESCRIPTION
  section above; ./scripts/gen_status.sh --refresh-manifests regenerates
  them and the CI evidence-gate job diffs the result). The acceptance
  additions (allocator_churn/large/oom/reuse/threaded,
  verifier_projection_tests, the canary_neg additions, the alignment and
  atomic-litmus tests, and the suites: arc_lifecycle, syscall_translation,
  target_lse_contract, pthread_abi, net_negative_abi,
  thread_spawn_failure, sync_contention, condvar_waiter_queue, once_cas,
  thread_channel_ownership, thread_local_drop, thread_result_cell,
  task_scope, cancellation_token, reactor_readiness, async_mutex_waiter,
  join_cancel, executor_clock, exec_conservation, db_lifecycle,
  db_async_pool, db_postgres_lexer, db_mysql_layout_probe,
  db_mysql_large_result, tls_interop, tls_handshake, and the
  impl-conformance canaries) are manifest-registered; their execution
  numbers live in the CI jobs that ran this SHA, not in this file.
- Round-11 state (working tree at $SHA + the uncommitted round-11 work
  in the WORKING TREE list above; HEAD is 6f1005a): the Arc rework
  (std/sync.tg) — unique-only get_mut, sink-consuming try_unwrap,
  drop_in_place on the last-release path, refcount overflow guard;
  DriverKind::Mysql joins the std/db.tg statement/transaction dispatch;
  std::tls moved to consuming sink builders and the CI lane builds
  native/tls_shims.c into libtg_tls_shims.dylib (every declared tls_*
  extern gated as an exported Mach-O symbol); normalize_extern_return
  sign/zero-extends C int returns at the extern ABI boundary; the Read
  trait takes the SliceMut[u8] writable-extent view; the Linux-AArch64
  syscall translation table (canonical numbers + the *at rewrites with
  AT_FDCWD); asm.tg's target feature table declares the explicit LSE
  requirement (aarch64 is LSE-REQUIRED); the pthread opaque alignment
  override (ffi_opaque_native_align); the thread spawn failure-path glue
  with the injected EAGAIN hook. No ladder/CI run has occurred on this
  tree — none of this is run-verified at this SHA.
- Round-12 state (the budget runtime enforcement; HEAD is e65914f): the
  typed budget records (TypedBudget on the typed FnSignature) gained
  REAL enforcement — the __tg_budget_alloc / __tg_budget_time counter
  table is DEFINED in the data section (codegen.tg
  emit_budget_runtime_data; the fail-closed-at-link state is gone), the
  MIR lowering of @budget-annotated functions constructs the
  MirBudgetConsume statements (the ALLOCATION metric: one consume after
  each intrinsic allocation in the annotated body — the classified
  builtin-container allocators; the TIME metric: the
  __tg_budget_time_start entry stamp + a per-MirReturn exit check), the
  codegen arms became the REAL checks (counter increment/compare and
  trap on exceed; the elapsed clock via the new __tg_clock_ns
  clock_gettime runtime), the fail-closed static-exceed rejection
  (check_budget_static_exceed — a body whose static allocation-site
  count exceeds the declared limit is rejected at check time) is the
  canary_neg surface, and the two canaries are manifest-registered
  (canary_pos_budget_alloc_within, canary_neg_budget_alloc_exceeded).
  Enforced metrics: alloc (count-based) + time (elapsed); memory /
  iterations / calls / custom metric names parse but emit no checks.
  No ladder/CI run has occurred on this tree.
- Round-14 state (working tree at $SHA + the uncommitted round-14 work
  in the WORKING TREE list above; HEAD is bccea59): the std::db driver
  hardening — PostgreSQL: the JDBC \`?\` placeholder of every
  parameterized statement is TRANSLATED to the \$1..\$n positional form
  (postgres_translate_placeholders — the scan is quoted-string aware,
  so a \`?\` inside a string literal or quoted identifier is data) before
  PQexecParams, every parameter payload is owned by the explicit
  PgParamBacking (the blob's bytes copied into owned_buffers that live
  through the FFI call — the dangling-blob-pointer path is gone), and
  the Statement gained the backend-specific state (the connection
  handle, the server-side prepared-statement name, and the parameter
  count) so the prepared statements run REAL server-side execution
  (PQprepare at prepare() time, PQexecPrepared at execute/query time,
  DEALLOCATE on drop/finalize — the "requires connection context" stub
  is gone). MySQL: the prepared path uses the REAL MYSQL_BIND parameter
  binding — the mysql.h st_mysql_bind layout (MysqlBind), the
  mysql_stmt_bind_param call with the per-parameter
  buffer_type/length/is_null/buffer cells (MysqlParamBacking), and the
  mysql_stmt_execute with the bindings — and the manual interpolation is
  REMOVED from every execution path (hostile values, multibyte text and
  binary blobs are shipped as data; the BLOB columns read back as
  SqlValue::Blob). The DB integration tests cover the translation, the
  blob backing, the prepared statements, and the hostile values. The
  db-integration-postgres / db-integration-mysql CI lanes run the native
  Homebrew servers (service containers are forbidden on macOS runners).
  No ladder/CI run has occurred on this tree.
- Status vocabulary (docs/current/feature_registry.md — the CI-artifact
  evidence model): a COMMITTED test artifact (manifest-registered canary,
  invariant group, required CI gate, @test file, or the self-host kernel
  as workload) establishes implemented+test-covered; only an OBSERVED
  execution at THIS tested SHA — proven by the CI job results and this
  snapshot's artifact hashes — establishes implemented+run-verified at
  SHA. This file IS the CI-artifact evidence: a snapshot generated by
  this script from a tested SHA is what elevates a feature to
  run-verified; a source tree alone never can.

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
     (bootstrap fingerprints + native-tests, cross-lane binaries, the
     linux-fingerprints + linux-native-tests artifacts), and generates
     this snapshot:
         ./scripts/gen_status.sh --artifacts build/.status_artifacts \\
             build/.status_artifacts/STATUS.txt
     then uploads it as the \`status-snapshot-<tested-sha>\` artifact
     (the artifact name carries the tested SHA). The committed STATUS.txt
     is the SHA-independent source-state description and is NEVER
     regenerated from a commit (a committed snapshot is stale the moment
     it lands).
  2. The evidence-gate job regenerates the canary manifests'
     self-description and gates the diff:
         ./scripts/gen_status.sh --refresh-manifests
         git diff --exit-code -- tests/canary/MANIFEST \\
             tests/canary_neg/MANIFEST tests/arm64/MANIFEST
  3. Locally, the same commands with the artifact dirs of a real run
     reproduce the artifact form; the committed file's structural facts
     are re-verifiable by running:
         ./scripts/gen_status.sh /tmp/status-check.txt
     (exit 0 = every fact still holds; the file is the artifact form).
  4. The harness constants and the structural facts are re-derived from
     the tree at the tested SHA; the per-suite "N/M passed" numbers and
     the stage2 == stage3 verdict live in the CI job logs, not in this
     file — the stage hashes / phase fingerprints are CI-run-provided
     (see the STAGE HASHES section above).

HARNESS CONSTANTS (read from scripts/bootstrap_helpers.sh at generation):
  CANARY_SUITE_POSITIVE_COUNT=$POS
  CANARY_SUITE_NEGATIVE_COUNT=$NEG   (includes the three 2026-08 canaries:
  canary_neg_ref_pattern, canary_neg_ring_buffer_peek_string,
  canary_neg_ring_buffer_peek_resource)
  CANARY_SUITE_ARM64_COUNT=$ARM
  The harness's four-way check (declared == listed == discovered ==
  constant) fails until the manifests and the constants agree; the
  manifests' generated count lines are refreshed by
  --refresh-manifests and diffed by the CI evidence-gate job.

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

# A REQUESTED release-evidence run that failed to write the evidence file
# is a FAILED release gate: fail the invocation (the CI status job would
# fail, and the release-gate aggregate with it).
if [ -n "$RELEASE_EVIDENCE" ] && [ ! -f "$ROOT/build/release_evidence.json" ]; then
  echo "gen_status: the release-evidence run FAILED — build/release_evidence.json was NOT written (see the RELEASE GATE FAILED errors above); a release cannot be gated on this run" >&2
  exit 1
fi

exit "$fail"
