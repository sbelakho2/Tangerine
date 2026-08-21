#!/usr/bin/env bash
# ———————————————————————————————————————————————————————————————
# scripts/run_two_root_repro.sh — the reproducibility proof
# (the reviewer's two-root reproducibility item).
#
# THE REPRODUCIBILITY DEFINITION (documented): a Tangerine build is
# reproducible iff two fresh source copies whose ABSOLUTE ROOT PATHS
# DIFFER (different names, different lengths — any absolute-path
# leakage in codegen/linker/generators changes the artifacts) produce
# byte-identical artifacts, with NO normalization beyond the declared
# NON-REPRODUCIBLE METADATA set — which is EMPTY: every artifact
# compared below is byte-for-byte (sha-256). The only artifact not
# compared is the timestamped STATUS.txt artifact form, which is not
# generated here by construction.
#
# TWO MODES (the honest ladder-dependent split):
#
#   LADDER MODE — when a stage binary exists (--with-binary, else the
#   build/tg_stage3 -> tg_stage2 -> tg_stage1 search, the grammar-gate
#   precedent). Each root runs the stage ladder FROM THE SAME SEED:
#       seed  -> root.stage1   (the seed compiles tg_compiler/
#                                bootstrap_main.tg)
#       stage1 -> stage2       (stage1 compiles the kernel)
#       stage2 -> stage3       (stage2 compiles the kernel)
#   and the proof asserts:
#       A.stage2 == A.stage3   (the self-host fixed point in root A)
#       B.stage2 == B.stage3   (the self-host fixed point in root B)
#       A.stage3 == B.stage3   (the cross-root reproducibility)
#   plus the generation comparisons below.
#
#   STRUCTURAL MODE — the current snapshot (no stage binary; NO LADDER
#   RUN): the structural fallback asserts the MANIFEST identity and the
#   GENERATION comparisons:
#       (1) the source closure identity: every copied source file's
#           sha-256 is identical between A and B (sorted hash lists);
#       (2) bootstrap/compiler_kernel.manifest: A == B byte-identical;
#       (3) the deterministic generations run in EACH root and compared
#           byte-for-byte: the public-API manifest, the feature
#           registry, the stdlib-completeness document, the refreshed
#           canary MANIFESTs, and the invariant-verification output.
#
# The generation comparisons run in BOTH modes (the generated artifacts
# must be reproducible regardless of the ladder state).
#
# Usage: scripts/run_two_root_repro.sh [--with-binary <stage-binary>]
#                                      [--root-base <dir>] [--out <file>]
#   --with-binary  the common seed stage binary for the ladder mode
#                  (default: auto-detect build/tg_stage3/2/1; absent ->
#                  structural mode).
#   --root-base    where the two fresh roots are created (default: a
#                  fresh mktemp dir; --keep leaves the roots in place).
#   --keep         keep the roots (the default cleans them up).
#   --out          write the proof report to a file (also printed).
# Exit status: 0 = every assertion holds (the proof passes); 1 = any
# comparison failed or a root build failed.
# ———————————————————————————————————————————————————————————————
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || { echo "run_two_root_repro: cannot cd to repo root" >&2; exit 2; }

BINARY=""
ROOT_BASE=""
KEEP=0
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --with-binary)
      shift
      BINARY="${1:-}"
      shift
      ;;
    --root-base)
      shift
      ROOT_BASE="${1:-}"
      shift
      ;;
    --keep)
      KEEP=1
      shift
      ;;
    --out)
      shift
      OUT="${1:-}"
      shift
      ;;
    *) break ;;
  esac
done

# The two fresh roots — DIFFERENT absolute paths (name AND length).
if [ -z "$ROOT_BASE" ]; then
  ROOT_BASE="$(mktemp -d "${TMPDIR:-/tmp}/tg_two_root.XXXXXX")"
  TEMP_BASE=1
else
  TEMP_BASE=0
  mkdir -p "$ROOT_BASE"
fi
ROOT_A="$ROOT_BASE/repro_root_a_path_alpha"
ROOT_B="$ROOT_BASE/repro_root_b_path_beta"
if [ "$KEEP" -eq 0 ]; then
  trap 'rm -rf "$ROOT_BASE"' EXIT
fi
rm -rf "$ROOT_A" "$ROOT_B"
mkdir -p "$ROOT_A" "$ROOT_B"

# ———————————————————————————————————————————————————————————————
# Step 1 — the fresh source copies (the identical relative layout at
#          different absolute roots)
# ———————————————————————————————————————————————————————————————
copy_tree() { # copy_tree <dest>
  local dest="$1"
  for d in tg_compiler std bootstrap docs scripts tests; do
    rsync -a "$ROOT/$d/" "$dest/$d/"
  done
  for f in features.toml invariants.toml; do
    cp -p "$ROOT/$f" "$dest/$f"
  done
}
copy_tree "$ROOT_A"
copy_tree "$ROOT_B"

# ———————————————————————————————————————————————————————————————
# Step 2 — the mode selection (a stage binary exists?)
# ———————————————————————————————————————————————————————————————
if [ -n "$BINARY" ]; then
  [ -x "$BINARY" ] || { echo "run_two_root_repro: the seed binary is not executable: $BINARY" >&2; exit 2; }
elif [ -x "$ROOT/build/tg_stage3" ]; then
  BINARY="$ROOT/build/tg_stage3"
elif [ -x "$ROOT/build/tg_stage2" ]; then
  BINARY="$ROOT/build/tg_stage2"
elif [ -x "$ROOT/build/tg_stage1" ]; then
  BINARY="$ROOT/build/tg_stage1"
fi

FAILURES=0
FAILED_AS=""

fail_assert() { # fail_assert <assertion> <detail>
  echo "  [FAIL] $1 — $2"
  FAILURES=$((FAILURES + 1))
  FAILED_AS="${FAILED_AS} $1"
}

# ———————————————————————————————————————————————————————————————
# Step 3 — the generation comparisons (BOTH modes; byte-for-byte, no
#          normalization)
# ———————————————————————————————————————————————————————————————
run_generations() { # run_generations <root>  ; generates + refreshes
  local r="$1"
  ( cd "$r" && mkdir -p build
    bash scripts/gen_api_manifest.sh build/public_api_manifest.json >/dev/null 2>&1
    bash scripts/gen_feature_registry.sh docs/current/feature_registry.md /dev/null >/dev/null 2>&1
    bash scripts/gen_stdlib_completeness.sh docs/current/stdlib_completeness.md >/dev/null 2>&1
    bash scripts/gen_status.sh --refresh-manifests >/dev/null 2>&1
    bash scripts/verify_invariants.sh > build/invariants_out.txt 2>&1
  )
}

sha256_of() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

# (3a) the source closure identity
CLOSURE_DIFF=0
if ! diff -q <(cd "$ROOT_A" && find tg_compiler std bootstrap docs scripts tests -type f | sort) \
             <(cd "$ROOT_B" && find tg_compiler std bootstrap docs scripts tests -type f | sort) >/dev/null; then
  CLOSURE_DIFF=1
fi
if [ "$CLOSURE_DIFF" -eq 0 ]; then
  HA="$(cd "$ROOT_A" && find tg_compiler std bootstrap docs scripts tests -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)"
  HB="$(cd "$ROOT_B" && find tg_compiler std bootstrap docs scripts tests -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)"
  if [ "$HA" = "$HB" ]; then
    echo "  [PASS] source closure identity: A and B carry the identical file set (combined sha-256 $HA)"
  else
    fail_assert "source closure identity" "combined hashes differ: A=$HA B=$HB"
  fi
else
  fail_assert "source closure identity" "the file SETS differ between the roots"
fi

# (3b) the manifest identity
if cmp -s "$ROOT_A/bootstrap/compiler_kernel.manifest" "$ROOT_B/bootstrap/compiler_kernel.manifest"; then
  echo "  [PASS] bootstrap/compiler_kernel.manifest: A == B byte-identical"
else
  fail_assert "bootstrap/compiler_kernel.manifest" "the manifest closure differs between the roots"
fi

# (3c) the generated artifacts (deterministic by construction)
run_generations "$ROOT_A"
run_generations "$ROOT_B"

GEN_PAIRS=(
  "build/public_api_manifest.json|the public-API manifest"
  "docs/current/feature_registry.md|the feature registry"
  "docs/current/stdlib_completeness.md|the stdlib-completeness document"
  "tests/canary/MANIFEST|the canary MANIFEST"
  "tests/canary_neg/MANIFEST|the canary_neg MANIFEST"
  "tests/arm64/MANIFEST|the arm64 MANIFEST"
  "build/invariants_out.txt|the invariant-verification output"
)
for pair in "${GEN_PAIRS[@]}"; do
  rel="${pair%%|*}"
  label="${pair#*|}"
  HA="$(sha256_of "$ROOT_A/$rel")"
  HB="$(sha256_of "$ROOT_B/$rel")"
  if [ -n "$HA" ] && [ "$HA" = "$HB" ]; then
    echo "  [PASS] $label: A == B byte-identical (sha-256 $HA)"
  else
    fail_assert "$label" "A=$HA B=$HB — the generation is NOT reproducible across the roots"
  fi
done

# ———————————————————————————————————————————————————————————————
# Step 4 — the ladder mode (only when a USABLE stage binary exists)
# ———————————————————————————————————————————————————————————————
LADDER_RAN=0
SEED_UNUSABLE=""
if [ -n "$BINARY" ]; then
  # The seed-usability probe (the grammar-gate precedent): a usable seed
  # must (a) CHECK a trivial valid program successfully and (b) REJECT a
  # legacy-spelling probe — a stale binary built before the E100 removal
  # silently accepts the probe and would run the ladder with the WRONG
  # grammar; a leftover binary that crashes (SIGILL) never qualifies.
  PROBE_DIR="$ROOT_BASE/probe"
  mkdir -p "$PROBE_DIR"
  printf 'def tg_two_root_good_probe() -> Int\n  0\nend\n' > "$PROBE_DIR/good.tg"
  printf 'def tg_two_root_probe(x: &Int) -> Int\n  x\nend\n' > "$PROBE_DIR/legacy.tg"
  probe_check() { ( "$1" check "$2" >/dev/null 2>&1; exit $? ) 2>/dev/null; }
  if probe_check "$BINARY" "$PROBE_DIR/good.tg" && ! probe_check "$BINARY" "$PROBE_DIR/legacy.tg"; then
    TARGET="${TARGET_TRIPLE:-${TG_BOOTSTRAP_TARGET:-aarch64-apple-darwin}}"
    echo ""
    echo "ladder mode: the common seed is $BINARY (usable: current grammar confirmed by probe rejection; target $TARGET)"
    run_ladder() { # run_ladder <root> ; seed -> stage1 -> stage2 -> stage3
      local r="$1"
      mkdir -p "$r/build"
      cp -p "$BINARY" "$r/build/tg_seed"
      ( cd "$r" \
        && ./build/tg_seed compile --strict-resolution tg_compiler/bootstrap_main.tg -o build/tg_stage1 --target "$TARGET" >/dev/null 2>&1 \
        && ./build/tg_stage1 compile --strict-resolution tg_compiler/bootstrap_main.tg -o build/tg_stage2 --target "$TARGET" >/dev/null 2>&1 \
        && ./build/tg_stage2 compile --strict-resolution tg_compiler/bootstrap_main.tg -o build/tg_stage3 --target "$TARGET" >/dev/null 2>&1 )
    }
    if run_ladder "$ROOT_A" && run_ladder "$ROOT_B"; then
      LADDER_RAN=1
      A2="$(sha256_of "$ROOT_A/build/tg_stage2")"
      A3="$(sha256_of "$ROOT_A/build/tg_stage3")"
      B2="$(sha256_of "$ROOT_B/build/tg_stage2")"
      B3="$(sha256_of "$ROOT_B/build/tg_stage3")"
      echo "  stage hashes: A.stage2=$A2 A.stage3=$A3 B.stage2=$B2 B.stage3=$B3"
      if [ -n "$A2" ] && [ "$A2" = "$A3" ]; then
        echo "  [PASS] A.stage2 == A.stage3 (the self-host fixed point in root A)"
      else
        fail_assert "A.stage2 == A.stage3" "A.stage2=$A2 A.stage3=$A3"
      fi
      if [ -n "$B2" ] && [ "$B2" = "$B3" ]; then
        echo "  [PASS] B.stage2 == B.stage3 (the self-host fixed point in root B)"
      else
        fail_assert "B.stage2 == B.stage3" "B.stage2=$B2 B.stage3=$B3"
      fi
      if [ -n "$A3" ] && [ "$A3" = "$B3" ]; then
        echo "  [PASS] A.stage3 == B.stage3 (the cross-root reproducibility)"
      else
        fail_assert "A.stage3 == B.stage3" "A.stage3=$A3 B.stage3=$B3"
      fi
    else
      fail_assert "the stage ladder in both roots" "one of the root ladders failed to complete (a stage compile failed)"
    fi
  else
    SEED_UNUSABLE="$BINARY (stale grammar, broken, or crashes — rejected by the usability probe; the grammar-gate precedent)"
    echo "  [note] the detected stage binary is NOT usable: $SEED_UNUSABLE — the ladder is NOT run; the structural fallback is the honest snapshot"
  fi
fi

# ———————————————————————————————————————————————————————————————
# Step 5 — the proof report
# ———————————————————————————————————————————————————————————————
{
  echo ""
  echo "======================================================"
  echo "TWO-ROOT REPRODUCIBILITY PROOF"
  echo "======================================================"
  echo "definition: a build is reproducible iff two fresh source copies at"
  echo "  DIFFERENT absolute root paths ($ROOT_A vs $ROOT_B) produce"
  echo "  byte-identical artifacts; NORMALIZATION: NONE (the declared"
  echo "  non-reproducible metadata set is empty — every artifact compared"
  echo "  is byte-for-byte sha-256; the timestamped STATUS.txt artifact"
  echo "  form is not generated here by construction)."
  echo "mode:        $([ "$LADDER_RAN" -eq 1 ] && echo 'ladder (seed -> stage1 -> stage2 -> stage3 in each root)' || echo 'structural (no USABLE stage binary in this tree — the manifest + the generation comparisons; A.stage2 == A.stage3 / B.stage2 == B.stage3 / A.stage3 == B.stage3 are PENDING-UNTIL-LADDER)')"
  if [ -n "$SEED_UNUSABLE" ]; then
    echo "seed note:   $SEED_UNUSABLE (the ladder is not run with a seed that fails the usability probe)"
  fi
  echo "assertions:  $( [ "$FAILURES" -eq 0 ] && echo 'ALL PASS' || echo "$FAILURES FAILED:$FAILED_AS")"
  echo "======================================================"
} | tee "${OUT:-/dev/stdout}"

[ "$FAILURES" -eq 0 ]
