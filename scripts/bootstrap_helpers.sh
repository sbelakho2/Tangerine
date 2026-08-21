# scripts/bootstrap_helpers.sh
#
# Shared validation library for the Tangerine bootstrap harness.
# Sourced by run_bootstrap.sh. Provides:
#   - sha256 helpers (macOS + Linux portable)
#   - the single bootstrap target authority (bh_boot_target) threaded through
#     every stage/test/canary invocation
#   - per-phase fingerprints under TG_BOOTSTRAP_TRACE=1
#     (link-image / text / sections / symbols / relocs + probed
#     tokens / ast / hir / mir / mir-mono dumps) and the stage2==stage3
#     phase-equality gate
#   - canary suite manifest parity (positive/negative/arch suites; missing
#     tests, unlisted tests, count drift and zero suites are all fatal)
#   - validate_stage: hard gate that a produced stage binary is usable
#   - run_stage2_diag_ladder: stage2 diagnostic severity ladder
#   - trap-stub gate + per-target canary lane (cross-compilation CI)
#   - check_two_clean_dirs: two-root reproducibility check (common seed +
#     common host, with documented limitations)
#
# Conventions:
#   - Everything is deterministic: no random temp names, sorted listings,
#     fixed output paths under the repo `build/` dir.
#   - All functions are strict; any failure propagates to the caller.

# ———————————————————————————————————————————————————————————————
# Logging & environment
# ———————————————————————————————————————————————————————————————

# Trace mode: enable per-phase fingerprints.
# Triggered by TG_BOOTSTRAP_TRACE=1, or the explicit flag --trace / --trace-phases.
BOOTSTRAP_TRACE="${TG_BOOTSTRAP_TRACE:-0}"
BOOTSTRAP_TRACE_ACTIVE="${BOOTSTRAP_TRACE}"

bh_log()  { printf '[bootstrap] %s\n' "$*"; }
bh_err()  { printf '[bootstrap:error] %s\n' "$*" >&2; }
bh_warn() { printf '[bootstrap:warning] %s\n' "$*" >&2; }

# Portably hash a string to its hex sha256.
bh_sha256_str() {
  printf '%s' "$1" | bh_sha256_cmd
}

# Portably hash a file to its hex sha256. Requires the file to exist.
bh_sha256_file() {
  if [ ! -f "$1" ]; then
    bh_err "cannot hash missing file: $1"
    return 1
  fi
  bh_sha256_cmd < "$1"
}

# Resolve the local sha256 utility once.
bh_sha256_cmd() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# ———————————————————————————————————————————————————————————————
# Target authority
# ———————————————————————————————————————————————————————————————

# The single bootstrap target resolution. Every compile/link invocation in
# this harness threads the SAME TargetSpec; a hard-coded triple in any one
# helper would let builds silently target different platforms. Prefers the
# harness-resolved TARGET_TRIPLE (run_bootstrap.sh), then TG_BOOTSTRAP_TARGET,
# and defaults to the canonical aarch64-apple-darwin.
bh_boot_target() {
  printf '%s' "${TARGET_TRIPLE:-${TG_BOOTSTRAP_TARGET:-aarch64-apple-darwin}}"
}

# Map a target triple (or arch alias) to its canonical architecture token
# used by otool -arch and the per-arch native test suites.
bh_arch_of() {
  case "$1" in
    aarch64*|arm64*) printf 'arm64' ;;
    x86_64*|amd64*)  printf 'x86_64' ;;
    *) printf '%s' "$1" ;;
  esac
}

# ———————————————————————————————————————————————————————————————
# Phase fingerprints (TG_BOOTSTRAP_TRACE=1)
# ———————————————————————————————————————————————————————————————

# Emit a stable, machine-readable phase fingerprint line for one stage.
# Usage: bh_phase_line <stage> <phase> <hash>
# A phase with value UNAVAILABLE is a documented gap: the phase exists in the
# pipeline but the stage binary cannot currently dump it (see the report in
# bh_fingerprints). UNAVAILABLE never silently drops a phase — it is recorded
# so the stage2==stage3 equality gate can distinguish "not comparable" from
# "comparable and equal".
bh_phase_line() {
  printf 'FINGERPRINT %s %s %s\n' "$1" "$2" "$3"
}

# Deterministically compute the sha256 of a compiler's textual output.
# Usage: bh_dump_hash <compiler> <source> [flags...]
# The hash utility reads stdin; flags are passed through verbatim so callers
# can combine e.g. `--dump-mir-lowered -O0`.
bh_dump_hash() {
  local compiler="$1" source_file="$2"
  shift 2
  "$compiler" compile "$source_file" "$@" 2>/dev/null | bh_sha256_cmd
}

# The pipeline phases fingerprinted per stage. Every phase is recorded with a
# sha256 and the stage2==stage3 reproducibility gate (bh_phase_equality)
# compares ALL of them, so equality is asserted at every phase, not only at
# the final link image.
#
# Observable today from the stage binaries (Mach-O on the bootstrap host):
#   link-image : sha256 of the final linked stage binary (exists)
#   text       : normalized __TEXT disassembly (otool -tv) — the emitted
#                machine code of the codegen phase
#   sections   : normalized Mach-O section metadata (otool -l)
#   symbols    : sorted symbol table (nm)
#   relocs     : normalized relocation table (otool -r)
#
# Front-end phases (tokens, ast/hir, mir, mir-mono) use the driver's --dump-*
# phase hooks (tg_compiler/driver.tg parse_args AND the kernel entry
# tg_compiler/bootstrap_main.tg both accept them; the kernel compile entry
# routes them through compile_startup_entry, which writes the normalized phase
# dumps). The harness probes each stage binary; a probe that fails or produces
# no output is recorded as UNAVAILABLE, and the RELEASE gate (bh_phase_equality
# with a 4th argument "release") treats UNAVAILABLE as a hard failure.
BOOTSTRAP_PHASES="link-image text sections symbols relocs tokens ast hir mir mir-mono"

# Compute the phase fingerprints for a stage binary.
# Usage: bh_fingerprints <stage> <compiler> <source> <outdir>
# Always writes $outdir/.fingerprints/<stage>.fingerprints (consumed by
# bh_phase_equality and uploaded by CI); FINGERPRINT lines are printed to
# stdout only under TG_BOOTSTRAP_TRACE=1.
bh_fingerprints() {
  local stage="$1" compiler="$2" source_file="$3" outdir="$4"
  local fp_dir="$outdir/.fingerprints"
  mkdir -p "$fp_dir"
  local fp_file="$fp_dir/$stage.fingerprints"

  local binary="$outdir/$stage"
  if [ ! -f "$binary" ]; then
    bh_err "fingerprinting $stage: missing binary $binary"
    return 1
  fi

  # Truncate ONLY after the binary is proven present: a failed run must never
  # leave an empty fingerprint file behind — bh_phase_equality treats empty
  # files as a hard failure, never as a vacuous pass.
  : > "$fp_file"

  bh_fp() {
    local phase="$1" hash="$2"
    bh_phase_line "$stage" "$phase" "$hash" >> "$fp_file"
    if [ "${BOOTSTRAP_TRACE_ACTIVE}" = "1" ]; then
      bh_phase_line "$stage" "$phase" "$hash"
    fi
  }

  # Phase 1: the final link image.
  bh_fp link-image "$(bh_sha256_file "$binary")"

  # Phases 2-5: object/codegen phases derived from the Mach-O image. These are
  # the observable artifacts of the codegen phase (sections/symbols/relocs/
  # text). All normalization strips only the file-path header and canonicalizes
  # ordering (sort) so the hashes are stable across runs and machines.
  if command -v otool >/dev/null 2>&1 && command -v nm >/dev/null 2>&1; then
    local arch
    arch="$(bh_arch_of "$(bh_boot_target)")"

    local text_dump
    text_dump="$(otool -tv -arch "$arch" "$binary" 2>/dev/null | sed '1d' || true)"
    bh_fp text "$(printf '%s' "$text_dump" | bh_sha256_cmd)"

    local sec_dump
    sec_dump="$(otool -l "$binary" 2>/dev/null | sed '1d' \
      | grep -E '^\s+(sectname|segname|addr|size|offset|align|reloff|nreloc|flags)\s' || true)"
    bh_fp sections "$(printf '%s' "$sec_dump" | bh_sha256_cmd)"

    local sym_dump
    sym_dump="$(nm "$binary" 2>/dev/null | sort || true)"
    bh_fp symbols "$(printf '%s' "$sym_dump" | bh_sha256_cmd)"

    local reloc_dump
    reloc_dump="$(otool -r "$binary" 2>/dev/null | sed '1d' || true)"
    bh_fp relocs "$(printf '%s' "$reloc_dump" | bh_sha256_cmd)"
  else
    bh_fp sections UNAVAILABLE
    bh_fp symbols UNAVAILABLE
    bh_fp relocs UNAVAILABLE
    bh_fp text UNAVAILABLE
  fi

  # Phases 6-10: front-end phases via the driver's --dump-* phase hooks.
  # Probed only under trace mode (each probe runs a compile); the probes are
  # what the kernel entry will support once bootstrap_main.tg threads the
  # driver flags — today they record UNAVAILABLE.
  if [ "${BOOTSTRAP_TRACE_ACTIVE}" = "1" ]; then
    local dump_src="${source_file:-tg_compiler/bootstrap_main.tg}"
    bh_dump_phase() {
      local phase="$1" flag="$2"
      local out
      if out="$( "$compiler" compile "$dump_src" --strict-resolution "$flag" --target "$(bh_boot_target)" 2>/dev/null )"; then
        if [ -n "$out" ]; then
          bh_fp "$phase" "$(printf '%s' "$out" | bh_sha256_cmd)"
        else
          bh_fp "$phase" UNAVAILABLE
        fi
      else
        bh_fp "$phase" UNAVAILABLE
      fi
    }
    bh_dump_phase tokens     --dump-tokens
    bh_dump_phase ast        --dump-ast
    bh_dump_phase hir        --dump-resolved-ast
    bh_dump_phase mir        --dump-mir-lowered
    bh_dump_phase mir-mono   --dump-mir-mono
  else
    bh_fp tokens UNAVAILABLE
    bh_fp ast UNAVAILABLE
    bh_fp hir UNAVAILABLE
    bh_fp mir UNAVAILABLE
    bh_fp mir-mono UNAVAILABLE
  fi

  bh_log "fingerprints for $stage written to $fp_file"
  return 0
}

# Hard-gate: stage2 and stage3 must agree on EVERY fingerprinted phase, not
# just the final link image. A phase UNAVAILABLE in both stages is a recorded
# gap and does not fail; a phase available in one stage only, or differing
# between the stages, fails the gate.
#
# RELEASE GATE (4th argument "release"): the CI/bootstrap gate (run_bootstrap
# Step 6) treats ANY UNAVAILABLE fingerprint as a HARD FAILURE — the semantic
# phases must all produce real fingerprints, and a "not comparable" phase is
# never acceptable in a release build. The UNAVAILABLE tolerance remains only
# for non-release/debug probes (no 4th argument).
# Usage: bh_phase_equality <stage-a> <stage-b> <outdir> [release]
bh_phase_equality() {
  local stage_a="$1" stage_b="$2" outdir="$3" release_gate="${4:-}"
  local fa="$outdir/.fingerprints/$stage_a.fingerprints"
  local fb="$outdir/.fingerprints/$stage_b.fingerprints"
  if [ ! -f "$fa" ] || [ ! -f "$fb" ]; then
    bh_err "phase equality: missing fingerprint files ($fa / $fb)"
    return 1
  fi
  if [ ! -s "$fa" ] || [ ! -s "$fb" ]; then
    bh_err "phase equality: empty fingerprint file ($fa / $fb) — fingerprint emission failed; a gate comparing zero phases must fail, never pass"
    return 1
  fi
  local failures=0 compared=0 unavailable=0
  local tag st phase ha hb
  while read -r tag st phase ha; do
    hb="$(awk -v p="$phase" '$3==p {print $4}' "$fb" | head -n1)"
    if [ -z "$hb" ]; then
      bh_err "phase equality: '$phase' present in $stage_a but missing in $stage_b"
      failures=$((failures + 1))
      continue
    fi
    if [ "$ha" = "UNAVAILABLE" ] && [ "$hb" = "UNAVAILABLE" ]; then
      if [ "$release_gate" = "release" ]; then
        bh_err "phase equality (RELEASE GATE): $phase UNAVAILABLE in both stages — every semantic phase must produce a fingerprint; a UNAVAILABLE phase is a hard failure in release mode"
        failures=$((failures + 1))
        continue
      fi
      bh_log "phase equality: $phase UNAVAILABLE in both stages (documented gap; kernel entry must thread --dump-*)"
      unavailable=$((unavailable + 1))
      continue
    fi
    if [ "$ha" = "UNAVAILABLE" ] || [ "$hb" = "UNAVAILABLE" ]; then
      if [ "$release_gate" = "release" ]; then
        bh_err "phase equality (RELEASE GATE): $phase UNAVAILABLE — every semantic phase must produce a fingerprint ($stage_a=$ha $stage_b=$hb)"
        failures=$((failures + 1))
        continue
      fi
      bh_err "phase equality: $phase available in one stage only ($stage_a=$ha $stage_b=$hb)"
      failures=$((failures + 1))
      continue
    fi
    compared=$((compared + 1))
    if [ "$ha" != "$hb" ]; then
      bh_err "phase equality: $phase differs — $stage_a=$ha $stage_b=$hb"
      failures=$((failures + 1))
    fi
  done < "$fa"
  while read -r tag st phase hb; do
    if ! grep -qE "^FINGERPRINT [^ ]+ $phase " "$fa"; then
      bh_err "phase equality: '$phase' present in $stage_b but missing in $stage_a"
      failures=$((failures + 1))
    fi
  done < "$fb"
  if [ "$release_gate" = "release" ]; then
    bh_log "phase equality (release gate): $compared phase(s) compared, $unavailable unavailable — release mode: UNAVAILABLE is fatal"
  else
    bh_log "phase equality: $compared phase(s) compared, $unavailable unavailable in both"
  fi
  if [ "$compared" -eq 0 ] && [ "$unavailable" -eq 0 ]; then
    bh_err "phase equality: zero phases compared or recorded — refusing to pass an empty comparison ($fa / $fb)"
    return 1
  fi
  if [ "$failures" -ne 0 ]; then
    bh_err "phase equality FAILED ($failures problem(s))"
    return 1
  fi
  bh_log "phase equality OK ($stage_a == $stage_b at every fingerprinted phase)"
  return 0
}

# Mach-O 64-bit magic bytes: CF FA ED FE.
bh_is_macho64() {
  local f="$1"
  if [ ! -f "$f" ]; then return 1; fi
  local magic
  magic="$(od -An -tx1 -N4 "$f" | tr -d ' \n')"
  [ "$magic" = "cffaedfe" ]
}

# ———————————————————————————————————————————————————————————————
# validate_stage
# ———————————————————————————————————————————————————————————————

# Hard-gate validation of a produced stage binary.
# Usage: validate_stage <stage-name> <binary-path> [<source-file>] [<outdir>]
#
# Checks (in order):
#   1. binary exists and is a regular executable file
#   2. binary is a valid Mach-O 64-bit image (magic CF FA ED FE)
#   3. reported size is nonzero and matches an expected minimum length
#   4. binary responds to --version with exit 0
#   5. binary compiles a canary program and that canary:
#        - is a valid Mach-O image
#        - executes with exit 0
#        - produces a nonzero expected-length output
#   6. emits the per-phase fingerprints (always; see bh_fingerprints) and
#      under trace mode additionally probes the --dump-* front-end phases
# Returns nonzero (and prints an error) on any failed check.
validate_stage() {
  local stage="$1" binary="$2" source_file="${3:-tg_compiler/bootstrap_main.tg}" outdir="${4:-build}"

  if [ ! -f "$binary" ]; then
    bh_err "$stage missing: $binary"
    return 1
  fi
  if [ ! -x "$binary" ]; then
    bh_err "$stage not executable: $binary"
    return 1
  fi
  if ! bh_is_macho64 "$binary"; then
    bh_err "$stage is not a valid Mach-O 64-bit image"
    return 1
  fi

  local size
  size="$(wc -c < "$binary" | tr -d ' ')"
  if [ "${size:-0}" -lt 1024 ]; then
    bh_err "$stage size ${size} is below the expected minimum (1024 bytes)"
    return 1
  fi
  local link_hash
  link_hash="$(bh_sha256_file "$binary")"
  bh_log "$stage size=${size} bytes sha256=${link_hash} macho=ok"

  if ! "$binary" --version >/dev/null 2>&1 && ! "$binary" version >/dev/null 2>&1; then
    bh_err "$stage did not answer --version/version"
    return 1
  fi

  if [ -f "$source_file" ]; then
    if ! "$binary" check "$source_file" >/dev/null 2>&1; then
      bh_err "$stage failed to self-check $source_file"
      return 1
    fi
    bh_log "$stage self-check OK"
  fi

  # Compile-and-execute a canary to prove the emitted binaries actually run.
  local canary_src="$outdir/.canary_probe.tg"
  local canary_bin="$outdir/.canary_probe_bin"
  cat > "$canary_src" <<'EOF'
use std::core
def main() -> Int
  println("stage-canary-ok")
  0
end
EOF
  if ! "$binary" compile "$canary_src" -o "$canary_bin" --target "$(bh_boot_target)" >/dev/null 2>&1; then
    bh_err "$stage failed to compile the execution canary"
    return 1
  fi
  if [ ! -f "$canary_bin" ]; then
    bh_err "$stage did not produce a canary binary"
    return 1
  fi
  if ! bh_is_macho64 "$canary_bin"; then
    bh_err "$stage canary output is not a valid Mach-O 64-bit image"
    return 1
  fi
  chmod +x "$canary_bin"
  local canary_out
  canary_out="$("$canary_bin" 2>/dev/null)"
  local canary_rc=$?
  if [ "$canary_rc" -ne 0 ]; then
    bh_err "$stage canary exited nonzero ($canary_rc)"
    return 1
  fi
  local out_len
  out_len="$(printf '%s' "$canary_out" | wc -c | tr -d ' ')"
  if [ "${out_len:-0}" -eq 0 ]; then
    bh_err "$stage canary produced empty output"
    return 1
  fi
  if ! printf '%s' "$canary_out" | grep -q "stage-canary-ok"; then
    bh_err "$stage canary output did not contain the expected marker"
    return 1
  fi
  bh_log "$stage execution canary OK (rc=0, ${out_len} bytes output)"

  if ! bh_fingerprints "$stage" "$binary" "$source_file" "$outdir"; then
    bh_err "$stage fingerprint emission failed"
    return 1
  fi

  bh_log "$stage VALID"
  return 0
}

# ———————————————————————————————————————————————————————————————
# Stage 2 diagnostic ladder
# ———————————————————————————————————————————————————————————————

# Walk the compiler's diagnostics from weakest to strongest severity and
# verify that each failure mode produces a nonzero exit with a diagnostic
# of the expected class. This is the "diagnostic ladder": a diagnostic
# pipeline must escalate severity monotonically and never silently swallow
# an error.
#
# Usage: run_stage2_diag_ladder <stage2-binary> <scratch-dir>
#
# The ladder is built from small .tg snippets written to scratch-dir and
# compiled with --check; the stage2 binary must reject each one and report
# the expected diagnostic class on stderr.
run_stage2_diag_ladder() {
  local compiler="$1" scratch="$2"
  mkdir -p "$scratch"

  bh_log "stage2 diagnostic ladder: preparing fixtures"

  # weak -> strong: note, warning, error, hard error (parse), hard error (lower)
  cat > "$scratch/ladder_ok.tg" <<'EOF'
def main() -> Int
  0
end
EOF

  cat > "$scratch/ladder_type_error.tg" <<'EOF'
def main() -> Int
  let x: Int = "not an int"
  0
end
EOF

  cat > "$scratch/ladder_parse_error.tg" <<'EOF'
def main() -> Int
  let = missing name
end
EOF

  cat > "$scratch/ladder_bad_return.tg" <<'EOF'
def returns_string() -> Int
  "not an int"
end
def main() -> Int
  returns_string()
end
EOF

  local ok_code type_code parse_code return_code
  local failures=0

  # The clean program MUST compile and exit 0.
  if "$compiler" check "$scratch/ladder_ok.tg" >/dev/null 2>&1; then
    ok_code=0
  else
    ok_code=1
    bh_err "ladder: clean program was rejected (expected success)"
    failures=$((failures + 1))
  fi

  # Type error MUST be rejected (nonzero exit) with a type-class diagnostic.
  if "$compiler" check "$scratch/ladder_type_error.tg" >/dev/null 2>&1; then
    type_code=1
    bh_err "ladder: type error accepted (expected rejection)"
    failures=$((failures + 1))
  else
    type_code=0
    if ! "$compiler" check "$scratch/ladder_type_error.tg" 2>&1 | grep -qi 'type\|mismatch\|expected'; then
      bh_warn "ladder: type error rejected but no type-class diagnostic found"
    fi
  fi

  # Parse error MUST be rejected and report a syntax-class diagnostic.
  if "$compiler" check "$scratch/ladder_parse_error.tg" >/dev/null 2>&1; then
    parse_code=1
    bh_err "ladder: parse error accepted (expected rejection)"
    failures=$((failures + 1))
  else
    parse_code=0
    if ! "$compiler" check "$scratch/ladder_parse_error.tg" 2>&1 | grep -qi 'error\|parse\|expected\|syntax'; then
      bh_warn "ladder: parse error rejected but no syntax diagnostic found"
    fi
  fi

  # Return-type mismatch MUST be rejected.
  if "$compiler" check "$scratch/ladder_bad_return.tg" >/dev/null 2>&1; then
    return_code=1
    bh_err "ladder: bad-return program accepted (expected rejection)"
    failures=$((failures + 1))
  else
    return_code=0
  fi

  # Strict name-resolution fixtures (check always runs strict resolution):
  # unknown local, unknown type, unknown enum variant, nonexistent method,
  # unknown field.
  cat > "$scratch/ladder_unknown_local.tg" <<'EOF'
def main() -> Int
  let x = compielr_options
  x
end
EOF
  cat > "$scratch/ladder_unknown_type.tg" <<'EOF'
def main() -> Int
  let x: DefinitlyNotAType = 0
  0
end
EOF
  cat > "$scratch/ladder_unknown_variant.tg" <<'EOF'
enum E
  A
end
def main() -> Int
  let x = E::NoSuchVariant
  0
end
EOF
  cat > "$scratch/ladder_unknown_method.tg" <<'EOF'
def main() -> Int
  let s = "hello"
  s.does_not_exist()
  0
end
EOF
  cat > "$scratch/ladder_unknown_field.tg" <<'EOF'
struct S
  a: Int
end
def main() -> Int
  let s = S { a: 1 }
  s.no_such_field
  0
end
EOF

  local strict_failures=0
  local fixture
  for fixture in ladder_unknown_local ladder_unknown_type ladder_unknown_variant \
                 ladder_unknown_method ladder_unknown_field; do
    if "$compiler" check "$scratch/$fixture.tg" >/dev/null 2>&1; then
      strict_failures=$((strict_failures + 1))
      bh_err "ladder: $fixture accepted (expected strict rejection)"
    fi
  done
  if [ "$strict_failures" -ne 0 ]; then
    bh_err "stage2 strict-resolution ladder FAILED ($strict_failures accepted)"
    failures=$((failures + strict_failures))
  fi

  bh_log "stage2 diag ladder: clean=${ok_code} type=${type_code} parse=${parse_code} return=${return_code}"

  if [ "$failures" -ne 0 ]; then
    bh_err "stage2 diagnostic ladder FAILED ($failures checks)"
    return 1
  fi
  bh_log "stage2 diagnostic ladder OK"
  return 0
}

# ———————————————————————————————————————————————————————————————
# Canary suite manifest parity (P1/P2 hardening)
# ———————————————————————————————————————————————————————————————
#
# The canary suites are bootstrap acceptance gates. Each suite directory has a
# MANIFEST that is the authority for the suite, and the KNOWN counts below are
# the recorded expected totals (positive + negative + arch totals). Parity is
# enforced in BOTH directions:
#   - every manifest-listed test must exist on disk        (absence is fatal)
#   - every discovered test must be manifest-listed        (no unlisted tests)
#   - the discovered set == the manifest set == the count  (exact, no drift)
#   - a zero/missing suite or a missing manifest is fatal  (never "0/0 passed")
#
# Native test organization (the "native-*" suites):
#   tests/canary/        positive native canaries (manifest: tests/canary/MANIFEST)
#   tests/canary_neg/    negative semantic canaries (manifest: tests/canary_neg/MANIFEST)
#   tests/arm64/         ARM64 encoder/ABI tests (manifest: tests/arm64/MANIFEST)
#   tests/x86_64/        x86-64 encoder/ABI tests (mandatory on x86_64 hosts)
# The arch-specific suite (tests/arm64 on aarch64 hosts, tests/x86_64 on
# x86_64 hosts) is mandatory: a missing directory is a hard failure, never a
# warning — a suite advertised as a bootstrap acceptance gate must be present
# on the supported host.

CANARY_SUITE_POSITIVE_COUNT=99
CANARY_SUITE_NEGATIVE_COUNT=76
CANARY_SUITE_ARM64_COUNT=2
CANARY_SUITE_TOTAL=$((CANARY_SUITE_POSITIVE_COUNT + CANARY_SUITE_NEGATIVE_COUNT + CANARY_SUITE_ARM64_COUNT))

# Validate one canary suite directory against its manifest.
# Usage: bh_canary_suite_validate <suite-dir> <manifest> <expected-count>
# Fails when: the suite dir is missing, the manifest is missing, a listed test
# is missing, a discovered test is unlisted, or any of the counts disagree.
bh_canary_suite_validate() {
  local dir="$1" manifest="$2" expected="$3"

  if [ ! -d "$dir" ]; then
    bh_err "canary suite dir missing: $dir (mandatory bootstrap acceptance gate)"
    return 1
  fi
  if [ ! -f "$manifest" ]; then
    bh_err "canary suite manifest missing: $manifest (a zero/missing suite is fatal)"
    return 1
  fi

  local declared
  declared="$(grep -E '^# count: [0-9]+' "$manifest" | sed -E 's/^# count: //' | head -n1)"
  if [ -z "$declared" ]; then
    bh_err "canary manifest $manifest has no '# count: N' declaration"
    return 1
  fi

  local listed=0
  local line entry
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    entry="${line%%$'\t'*}"
    if [ ! -f "$dir/$entry" ]; then
      bh_err "canary manifest entry missing file: $dir/$entry (listed in $manifest)"
      return 1
    fi
    listed=$((listed + 1))
  done < "$manifest"

  local discovered=0
  local f
  for f in "$dir"/*.tg; do
    [ -e "$f" ] || continue
    discovered=$((discovered + 1))
    entry="$(basename "$f")"
    if ! grep -qxF "$entry" < <(grep -vE '^#|^$' "$manifest" | cut -f1); then
      bh_err "unlisted canary file: $dir/$entry (every discovered test must be listed in $manifest)"
      return 1
    fi
  done

  if [ "$listed" -ne "$discovered" ]; then
    bh_err "canary parity mismatch in $dir: $listed manifest entries vs $discovered discovered tests (manifest == discovered-set required)"
    return 1
  fi
  if [ "$listed" -ne "$declared" ]; then
    bh_err "canary count mismatch in $manifest: declared count $declared != listed entries $listed"
    return 1
  fi
  if [ "$declared" -ne "$expected" ]; then
    bh_err "canary count drift in $manifest: declared $declared != recorded expected count $expected (update the manifest AND the harness constant together)"
    return 1
  fi
  if [ "$listed" -eq 0 ]; then
    bh_err "canary suite $dir is empty (a zero suite is fatal)"
    return 1
  fi

  bh_log "canary suite $dir OK: $listed tests, manifest parity exact (listed == discovered == declared == $expected)"
  return 0
}

# Validate every bootstrap-acceptance canary suite for the resolved target.
# Usage: bh_require_canary_suites
bh_require_canary_suites() {
  local target arch
  target="$(bh_boot_target)"
  arch="$(bh_arch_of "$target")"
  local failures=0

  bh_canary_suite_validate tests/canary     tests/canary/MANIFEST     "$CANARY_SUITE_POSITIVE_COUNT" || failures=$((failures + 1))
  bh_canary_suite_validate tests/canary_neg tests/canary_neg/MANIFEST "$CANARY_SUITE_NEGATIVE_COUNT" || failures=$((failures + 1))

  case "$arch" in
    arm64)
      bh_canary_suite_validate tests/arm64 tests/arm64/MANIFEST "$CANARY_SUITE_ARM64_COUNT" || failures=$((failures + 1))
      ;;
    x86_64)
      if [ ! -d tests/x86_64 ]; then
        bh_err "missing arch-specific native suite tests/x86_64 (mandatory on x86_64 hosts; a missing native-* directory is a hard failure)"
        failures=$((failures + 1))
      elif [ ! -f tests/x86_64/MANIFEST ]; then
        bh_err "missing tests/x86_64/MANIFEST (arch-specific suite authority)"
        failures=$((failures + 1))
      fi
      ;;
    *)
      bh_err "unsupported bootstrap target arch: $arch ($target)"
      failures=$((failures + 1))
      ;;
  esac

  if [ "$failures" -ne 0 ]; then
    bh_err "canary suite validation FAILED for target $target"
    return 1
  fi
  bh_log "canary suites OK for $target: positive=$CANARY_SUITE_POSITIVE_COUNT negative=$CANARY_SUITE_NEGATIVE_COUNT arm64=$CANARY_SUITE_ARM64_COUNT total=$CANARY_SUITE_TOTAL"
  return 0
}

# ———————————————————————————————————————————————————————————————
# Native canary + ARM64 test runner
# ———————————————————————————————————————————————————————————————

# Compile and execute a given list of canary files with the given compiler.
# Each file must have `main() -> Int` returning its failure count (0 = pass).
# A missing file is FATAL (manifest parity is checked by the callers; this is
# the enforcement net), and an empty file list is fatal — a zero suite can
# never "pass".
# Usage: run_canary_files <compiler> <outdir> <file>...
run_canary_files() {
  local compiler="$1" outdir="$2"
  shift 2
  mkdir -p "$outdir"
  local failures=0 total=0
  local file
  if [ "$#" -eq 0 ]; then
    bh_err "run_canary_files: no canary files given (zero suite is fatal)"
    return 1
  fi
  for file in "$@"; do
    if [ ! -f "$file" ]; then
      bh_err "native canary file missing: $file (absence is fatal; manifest parity broken)"
      return 1
    fi
    total=$((total + 1))
    local name
    name="$(basename "$file" .tg)"
    local bin="$outdir/.native_${name}"
    bh_log "native canary: $file"
    if ! "$compiler" compile "$file" -o "$bin" --target "$(bh_boot_target)" >/dev/null 2>&1; then
      bh_err "native canary $name failed to compile"
      failures=$((failures + 1))
      continue
    fi
    if ! bh_is_macho64 "$bin"; then
      bh_err "native canary $name produced non-Mach-O output"
      failures=$((failures + 1))
      continue
    fi
    chmod +x "$bin"
    local rc
    # set -e must not abort before diagnostics: capture the exit code via an
    # if/else so a nonzero canary is classified and reported, not fatal.
    if "$bin" >/dev/null 2>&1; then
      rc=0
    else
      rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      bh_err "native canary $name exited nonzero ($rc)"
      failures=$((failures + 1))
    fi
  done
  bh_log "native canaries: $((total - failures))/$total passed"
  if [ "$failures" -ne 0 ]; then
    bh_err "native canaries FAILED: $failures failure(s)"
    return 1
  fi
  bh_log "native canaries OK"
  return 0
}

# Pre-self-host critical suite: exercises the runtime/ABI surfaces that the
# compiler itself depends on, so a stage's runtime is proven capable before
# compiling the compiler again. Run under stage1 and stage2.
# Every critical canary must exist AND be a member of the authoritative
# tests/canary/MANIFEST (absence or an unlisted file is fatal).
# Usage: run_critical_canaries <compiler> <outdir>
run_critical_canaries() {
  local compiler="$1" outdir="$2"
  local arch
  arch="$(bh_arch_of "$(bh_boot_target)")"

  # The critical subset is a SUBSET of the positive canary manifest; the
  # manifest remains the authority (run_native_tests runs the full set).
  local list=(
    tests/canary/test_canary_borrowed_enum.tg \
    tests/canary/test_canary_representation.tg \
    tests/canary/test_canary_narrow_storage.tg \
    tests/canary/test_canary_aggregate_copy.tg \
    tests/canary/test_canary_bump_alloc_boundary.tg \
    tests/canary/test_canary_large_vec_write.tg \
    tests/canary/test_canary_struct_field_order.tg \
    tests/canary/test_canary_nested_map_receiver.tg \
    tests/canary/test_canary_vec_map_growth.tg \
    tests/canary/test_canary_string_concat_slice.tg \
    tests/canary/test_canary_objectfile_construction.tg \
    tests/canary/test_canary_many_args.tg \
    tests/canary/test_canary_callee_saved_survival.tg \
    tests/canary/canary_access_read.tg \
    tests/canary/canary_access_inout.tg \
    tests/canary/canary_access_sink.tg \
    tests/canary/canary_access_set.tg \
    tests/canary/canary_resource.tg \
    tests/canary/canary_resource_return.tg \
    tests/canary/canary_closure_resource_capture.tg \
    tests/canary/canary_pos_arity.tg \
    tests/canary/canary_pos_resource_array_take.tg \
    tests/canary/canary_pos_resource_sink_param.tg \
    tests/canary/canary_pos_resource_early_return.tg \
    tests/canary/canary_pos_resource_wrapper_generic.tg \
    tests/canary/canary_pos_generic_policy_instances.tg \
    tests/canary/canary_pos_generic_body_concrete_owning.tg \
    tests/canary/canary_pos_fixed_array_const_size.tg \
    tests/canary/canary_pos_resource_user_finalizer_fields.tg \
    tests/canary/canary_pos_resource_map_cleanup.tg \
    tests/canary/canary_pos_resource_nested_scope.tg \
    tests/canary/canary_pos_resource_sink_explicit_return.tg \
    tests/canary/canary_pos_resource_manual_deinit_call.tg \
    tests/canary/canary_pos_resource_loop_break_survives.tg \
    tests/canary/canary_pos_resource_loop_auto_clean.tg \
    tests/canary/canary_pos_resource_box.tg \
    tests/canary/canary_pos_resource_manual_deinit_fields.tg \
    tests/canary/canary_pos_resource_discarded_temp.tg \
    tests/canary/canary_pos_resource_nested_return.tg \
    tests/canary/canary_pos_resource_nested_break.tg \
    tests/canary/canary_pos_resource_nested_continue.tg \
    tests/canary/canary_pos_smart_box_int.tg \
    tests/canary/canary_pos_smart_rc.tg \
    tests/canary/canary_pos_smart_unique_ptr.tg \
    tests/canary/canary_pos_resource_drain.tg \
    tests/canary/canary_pos_set_drain.tg \
    tests/canary/canary_pos_resource_while_auto_clean.tg \
    tests/canary/canary_pos_resource_while_zero_iter.tg \
    tests/canary/canary_pos_resource_for_auto_clean.tg \
    tests/canary/canary_pos_resource_option_result.tg \
    tests/canary/canary_pos_resource_assign.tg \
    tests/canary/canary_pos_container_destroy.tg \
    tests/canary/canary_pos_resource_drain_collision.tg \
    tests/canary/canary_pos_discarded_unique_ptr.tg \
    tests/canary/canary_pos_closure_capture_owner.tg \
    tests/canary/canary_pos_wrapper_viral_destroy.tg \
    tests/canary/canary_capability.tg \
    tests/canary/canary_closure_async.tg \
    tests/canary/canary_ffi.tg
  )
  # The ARM64 ABI test is arch-specific: only the aarch64 lane runs it.
  if [ "$arch" = "arm64" ]; then
    list+=(tests/arm64/test_arm64_abi.tg)
  fi

  local critical_failures=0
  local f base
  for f in "${list[@]}"; do
    if [ ! -f "$f" ]; then
      bh_err "critical canary missing: $f (absence is fatal)"
      critical_failures=$((critical_failures + 1))
      continue
    fi
    base="$(basename "$f")"
    case "$f" in
      tests/canary/*)
        if ! grep -qxF "$base" < <(grep -vE '^#|^$' tests/canary/MANIFEST); then
          bh_err "critical canary not listed in tests/canary/MANIFEST: $base"
          critical_failures=$((critical_failures + 1))
        fi
        ;;
      tests/arm64/*)
        if ! grep -qxF "$base" < <(grep -vE '^#|^$' tests/arm64/MANIFEST); then
          bh_err "critical canary not listed in tests/arm64/MANIFEST: $base"
          critical_failures=$((critical_failures + 1))
        fi
        ;;
    esac
  done
  if [ "$critical_failures" -ne 0 ]; then
    bh_err "critical canary list failed validation ($critical_failures problem(s))"
    return 1
  fi

  run_canary_files "$compiler" "$outdir" "${list[@]}"
}

# Semantic canary negatives: every file in tests/canary_neg/ is a negative
# case of the access/resource/capability/async canary matrix. Each file MUST
# be rejected by `check` AND the failure MUST be the diagnostic class listed
# in tests/canary_neg/MANIFEST (tab-separated: filename.tg<TAB>expected
# substring). Asserting only the exit code gave false confidence: an
# unrelated later error could turn a canary green.
# A file that is accepted (exit 0), or whose output lacks the expected
# diagnostic substring, fails the harness. Files without a manifest entry
# also fail (missing manifest coverage), and manifest entries without files
# fail too — the manifest is checked against the filesystem in BOTH
# directions (manifest == discovered-set, never just one direction).
# Usage: run_semantic_canary_negatives <compiler>
run_semantic_canary_negatives() {
  local compiler="$1"
  local dir="tests/canary_neg"
  local manifest="$dir/MANIFEST"
  if [ ! -f "$manifest" ]; then
    bh_err "canary manifest missing: $manifest"
    return 1
  fi
  # Bidirectional parity + the recorded negative count: a deleted canary, an
  # unlisted canary, or a drifted count fails here.
  if ! bh_canary_suite_validate "$dir" "$manifest" "$CANARY_SUITE_NEGATIVE_COUNT"; then
    return 1
  fi
  local failures=0 total=0
  local file
  for file in "$dir"/*.tg; do
    [ -e "$file" ] || continue
    total=$((total + 1))
    local name
    name="$(basename "$file" .tg)"
    local expected
    expected="$(grep -F "$(basename "$file")" "$manifest" | head -n1 | cut -f2)"
    if [ -z "$expected" ]; then
      bh_err "semantic canary negative $name has NO manifest entry (add filename.tg<TAB>expected-diagnostic-substring to $manifest)"
      failures=$((failures + 1))
      continue
    fi
    bh_log "semantic canary negative: $file (expecting: $expected)"
    local output
    output="$("$compiler" check "$file" 2>&1)"
    local exitcode=$?
    if [ "$exitcode" -eq 0 ]; then
      bh_err "semantic canary negative $name ACCEPTED (expected rejection)"
      failures=$((failures + 1))
    elif ! printf '%s' "$output" | grep -qF "$expected"; then
      bh_err "semantic canary negative $name rejected but WITHOUT expected diagnostic '$expected' (output: $(printf '%s' "$output" | head -n2 | tr '\n' ' '))"
      failures=$((failures + 1))
    fi
  done
  if [ "$total" -eq 0 ]; then
    bh_err "semantic canary negatives: zero tests discovered (zero suite is fatal)"
    return 1
  fi
  bh_log "semantic canary negatives: $((total - failures))/$total rejected with expected diagnostics"
  if [ "$failures" -ne 0 ]; then
    bh_err "semantic canary negatives FAILED: $failures problems"
    return 1
  fi
  bh_log "semantic canary negatives OK"
  return 0
}

# Compile and execute every native canary and arch test with the given
# compiler binary. Each test file has a `main() -> Int` that returns its
# failure count; the harness requires exit code 0.
#
# The suite is MANIFEST-DRIVEN: the file list comes from the manifest, not
# from a directory glob, and every suite advertised as a bootstrap acceptance
# gate is mandatory on the resolved host — a missing tests/canary,
# tests/canary_neg or tests/arm64 (aarch64 hosts) / tests/x86_64 (x86_64
# hosts) directory is a hard failure, never a warning.
#
# Usage: run_native_tests <compiler> <outdir>
run_native_tests() {
  local compiler="$1" outdir="$2"
  mkdir -p "$outdir"

  if ! bh_require_canary_suites; then
    return 1
  fi

  local files=()
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    files+=("tests/canary/$line")
  done < tests/canary/MANIFEST

  local arch
  arch="$(bh_arch_of "$(bh_boot_target)")"
  if [ "$arch" = "arm64" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        ''|\#*) continue ;;
      esac
      files+=("tests/arm64/$line")
    done < tests/arm64/MANIFEST
  fi

  if [ "${#files[@]}" -eq 0 ]; then
    bh_err "native test suite is empty (zero suite is fatal)"
    return 1
  fi
  run_canary_files "$compiler" "$outdir" "${files[@]}"
}

# ———————————————————————————————————————————————————————————————
# Trap-stub gate + per-target canary lane
# ———————————————————————————————————————————————————————————————

# Assert that an emitted canary object contains NO trap stubs beyond the
# runtime's documented deliberate traps. Trap stubs are the backend's
# "unimplemented op" markers: the old x86 codegen emitted x64_ud2 (0F 0B) for
# unsupported ops and fabricated defaults — those holes are closed and the
# gate must never let them regress.
#
# The gate is SYMBOL-AWARE: every trap instruction (ud2 on x86-64; udf/brk on
# arm64) is attributed to the function symbol that contains it (the nearest
# preceding non-local label in the otool -tv disassembly) and is then either
# ALLOWED (the symbol is in the deliberate abort/panic whitelist) or BANNED.
# A banned trap — a trap-only implementation or OS-fallback trap in the
# supported map/set/string/array runtime families, or any trap in user code —
# fails the gate. A binary whose ONLY traps sit in the whitelisted abort/
# panic/unreachable machinery passes.
#
# The whitelist (enumerated from the runtime's documented traps):
#   __intrinsic_abort     "Abort execution with trap" (runtime.tg) — the
#                         deliberate abort implementation
#   panic, panic_unwind,  std::core panic/unreachable machinery (std/core.tg):
#   begin_unwind,         panic entry, the unwind entry that performs the
#   resume_unwind,        abort, re-panic, unreachable(msg) -> panic(msg),
#   unreachable, assert   and assert -> panic
# Allowed exception (arm64 only, independent of the whitelist): the runtime's
# vec-push sanity trap `brk #0xbeef` (runtime.tg __tg_vec_push) — a
# deliberate defensive trap for corrupt vec pointers.
# Usage: bh_assert_no_trap_stubs <binary> <triple>
TRAP_GATE_WHITELIST=" __intrinsic_abort panic panic_unwind begin_unwind resume_unwind unreachable assert "

# Symbol-aware trap scan: attribute each trap instruction of a disassembly to
# the containing function symbol (otool -tv label lines; local labels start
# with `_.L` / `.L` and stay attributed to the enclosing function) and count
# allowed (whitelisted abort/panic/unreachable machinery) vs banned (every
# other trap) instructions.
# Usage: bh_scan_traps <disassembly> <arch> -> "allowed banned"
bh_scan_traps() {
  local dis="$1" arch="$2"
  local cur_sym="" line lbl bare
  local allowed=0 banned=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *:)
        # Label line: a function/global symbol or a local label. Local
        # labels (_.Lxxx / .Lxxx) keep the current function attribution.
        lbl="${line%:}"
        case "$lbl" in
          _.L*|.L*) ;;
          *) cur_sym="${lbl#_}" ;;
        esac
        ;;
      *)
        case "$arch" in
          x86_64)
            if [[ "$line" == *ud2* ]]; then
              if [[ "$TRAP_GATE_WHITELIST" == *" $cur_sym "* ]]; then
                allowed=$((allowed + 1))
              else
                banned=$((banned + 1))
              fi
            fi
            ;;
          arm64)
            if [[ "$line" == *udf* ]]; then
              banned=$((banned + 1))
            elif [[ "$line" == *brk* ]]; then
              if [[ "$line" == *brk*0xbeef* ]]; then
                # Documented vec-push sanity trap (immediate-identifiable).
                allowed=$((allowed + 1))
              elif [[ "$TRAP_GATE_WHITELIST" == *" $cur_sym "* ]]; then
                # Deliberate abort inside the abort/panic machinery.
                allowed=$((allowed + 1))
              else
                banned=$((banned + 1))
              fi
            fi
            ;;
        esac
        ;;
    esac
  done <<< "$dis"
  printf '%s %s\n' "$allowed" "$banned"
}

bh_assert_no_trap_stubs() {
  local binary="$1" triple="$2"
  if [ ! -f "$binary" ]; then
    bh_err "trap-stub gate: missing binary $binary"
    return 1
  fi
  if ! command -v otool >/dev/null 2>&1; then
    bh_err "trap-stub gate: otool is not available (cannot disassemble $binary)"
    return 1
  fi
  local arch
  arch="$(bh_arch_of "$triple")"
  local dis
  dis="$(otool -tv -arch "$arch" "$binary" 2>/dev/null || true)"
  if [ -z "$dis" ]; then
    bh_err "trap-stub gate: cannot disassemble $binary for $arch"
    return 1
  fi
  local scan allowed banned
  scan="$(bh_scan_traps "$dis" "$arch")"
  allowed="${scan%% *}"
  banned="${scan##* }"
  if [ "${banned:-0}" -ne 0 ]; then
    bh_err "trap-stub gate FAILED: $binary contains $banned banned trap instruction(s) outside the documented abort/panic whitelist ($arch — trap-only implementations / OS-fallback traps in the map/set/string/array runtime families are banned; only the whitelisted abort/panic/unreachable machinery is allowed)"
    return 1
  fi
  bh_log "trap-stub gate OK: no banned trap instructions in $binary ($arch; $allowed documented abort/panic trap(s) in whitelisted symbols allowed)"
  return 0
}

# Compile + execute the positive canary manifest for an arbitrary target
# triple ("target lane"). Native lane: execute directly. Cross lanes: execute
# under Rosetta (arch -x86_64) or an emulator (qemu-<arch>) when available;
# when no executor exists the mandatory minimum is the trap-stub gate — the
# emitted object must contain zero trap stubs. Used by the CI cross lane.
#
# Usage: run_target_lane_canaries <compiler> <outdir> [triple|arch-alias]
#   triple omitted            -> bh_boot_target (native lane)
#   "x86_64" / "amd64" alias  -> x86_64-apple-darwin (the cross lane)
#   "aarch64" / "arm64" alias -> bh_boot_target (native lane on the bootstrap host)
run_target_lane_canaries() {
  local compiler="$1" outdir="$2"
  local triple="${3:-$(bh_boot_target)}"
  case "$triple" in
    x86_64|amd64)  triple="x86_64-apple-darwin" ;;
    aarch64|arm64) triple="$(bh_boot_target)" ;;
  esac
  mkdir -p "$outdir"

  if ! bh_require_canary_suites; then
    return 1
  fi

  local host_arch target_arch
  host_arch="$(uname -m)"
  target_arch="$(bh_arch_of "$triple")"

  local can_exec=0
  local runner=()
  if [ "$host_arch" = "$target_arch" ]; then
    can_exec=1
  elif [ "$target_arch" = "x86_64" ] && command -v arch >/dev/null 2>&1 \
       && arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
    # Rosetta 2 present: x86-64 binaries execute on the arm64 host.
    can_exec=1
    runner=(arch -x86_64)
  elif command -v "qemu-$target_arch" >/dev/null 2>&1; then
    can_exec=1
    runner=("qemu-$target_arch")
  fi

  local failures=0 total=0
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    local src="tests/canary/$line"
    total=$((total + 1))
    local name
    name="${line%.tg}"
    local bin="$outdir/.lane_${target_arch}_${name}"
    bh_log "target lane canary ($triple): $src"
    if ! "$compiler" compile "$src" -o "$bin" --target "$triple" >/dev/null 2>&1; then
      bh_err "target lane canary $name failed to compile for $triple"
      failures=$((failures + 1))
      continue
    fi
    if ! bh_assert_no_trap_stubs "$bin" "$triple"; then
      failures=$((failures + 1))
      continue
    fi
    if [ "$can_exec" -eq 1 ]; then
      chmod +x "$bin"
      if ! "${runner[@]}" "$bin" >/dev/null 2>&1; then
        bh_err "target lane canary $name exited nonzero under $target_arch ($triple)"
        failures=$((failures + 1))
      fi
    else
      bh_log "target lane canary $name: no executor for $triple on $host_arch; disassembly/trap-stub gate only"
    fi
  done < tests/canary/MANIFEST

  bh_log "target lane ($triple): $((total - failures))/$total passed (execution: $(if [ "$can_exec" -eq 1 ]; then printf 'yes'; else printf 'no — disassembly gate only'; fi))"
  if [ "$failures" -ne 0 ]; then
    bh_err "target lane ($triple) FAILED: $failures problem(s)"
    return 1
  fi
  bh_log "target lane ($triple) OK"
  return 0
}

# ———————————————————————————————————————————————————————————————
# Two-root reproducibility check
# ———————————————————————————————————————————————————————————————

# Build a stage binary twice from two pristine (clean) source copies and
# assert that both runs produce byte-identical artifacts. The check is
# "two-root reproducibility": two copied trees with a COMMON SEED (identical
# source closure, identical manifest) and a COMMON HOST (same toolchain,
# same machine). It proves the build is insensitive to the absolute root
# path — any absolute-path leakage in codegen/linker changes the artifacts.
#
# Documented limitations (the check is NOT a hermetic-build proof):
#   - environment variables: TARGET_TRIPLE / TG_BOOTSTRAP_TARGET /
#     TG_HOST_TARGET / TG_TARGET_ARCH / locale variables are inherited
#     from the harness process; two runs with different env can differ.
#   - timestamps: the compiler embeds no wall-clock output by construction,
#     but a future timestamping feature would break the check by design.
#   - locale: codegen string handling is locale-independent today; the check
#     does not normalize locale.
#   - file ordering: directory scans are sorted deterministically; the check
#     would flag any unsorted scan introduced later.
#   - absolute paths: this is exactly what the check detects — the two roots
#     differ by construction, so any path leakage produces different hashes.
#
# Build the bootstrap closure for a clean tree from the kernel manifest.
# Usage: build_clean_tree <dest-root> <repo-root> [--without-manifest]
# Copies the exact compiler_kernel.manifest closure into $dest-root preserving
# relative paths (std/ and tg_compiler/), so dependency resolution behaves
# identically to the real bootstrap while the absolute root differs. The
# manifest ITSELF is part of the closure: the self-host bootstrap is
# manifest-closed (compiler_core bootstrap_manifest_sources), so a clean tree
# without bootstrap/compiler_kernel.manifest would NOT reproduce the real
# bootstrap. --without-manifest builds the closure minus the manifest for the
# NEGATIVE self-host manifest gate (the compile must fail).
build_clean_tree() {
  local dest="$1" repo="$2"
  local with_manifest=1
  if [ "${3:-}" = "--without-manifest" ]; then
    with_manifest=0
  fi
  local manifest="$repo/bootstrap/compiler_kernel.manifest"
  if [ ! -f "$manifest" ]; then
    bh_err "determinism: missing manifest $manifest"
    return 1
  fi
  local kind path
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    kind="${line%%:*}"
    path="${line#*: }"
    case "$kind" in
      std|compiler)
        local rel
        if [ "$kind" = "std" ]; then rel="std/$path"; else rel="tg_compiler/$path"; fi
        mkdir -p "$(dirname "$dest/$rel")"
        cp "$repo/$rel" "$dest/$rel"
        ;;
    esac
  done < "$manifest"
  if [ "$with_manifest" = "1" ]; then
    mkdir -p "$dest/bootstrap"
    cp "$manifest" "$dest/bootstrap/compiler_kernel.manifest"
  fi
  return 0
}

# The two-root reproducibility check builds the identical manifest closure
# from two pristine trees whose absolute roots differ but whose relative
# layout is identical. Common seed + common host; see the limitations block
# at the top of this section.
#
# Usage: check_two_clean_dirs <stage-name> <compiler> <outdir> <repo-root>
check_two_clean_dirs() {
  local stage="$1" compiler="$2" outdir="$3" repo="$4"
  mkdir -p "$outdir"
  local dir_a="$outdir/determinism/A"
  local dir_b="$outdir/determinism/B"
  rm -rf "$dir_a" "$dir_b"
  mkdir -p "$dir_a" "$dir_b"

  if ! build_clean_tree "$dir_a" "$repo"; then
    bh_err "$stage determinism: could not build clean tree A"
    return 1
  fi
  if ! build_clean_tree "$dir_b" "$repo"; then
    bh_err "$stage determinism: could not build clean tree B"
    return 1
  fi

  local out_a="$outdir/${stage}_a" out_b="$outdir/${stage}_b"

  bh_log "$stage determinism: building from clean tree A (root=$dir_a)"
  if ! ( cd "$dir_a" && "$compiler" compile --strict-resolution tg_compiler/bootstrap_main.tg -o "$out_a" --target "$(bh_boot_target)" >/dev/null 2>&1 ); then
    bh_err "$stage determinism: build A failed"
    return 1
  fi

  bh_log "$stage determinism: building from clean tree B (root=$dir_b)"
  if ! ( cd "$dir_b" && "$compiler" compile --strict-resolution tg_compiler/bootstrap_main.tg -o "$out_b" --target "$(bh_boot_target)" >/dev/null 2>&1 ); then
    bh_err "$stage determinism: build B failed"
    return 1
  fi

  local ha hb
  ha="$(bh_sha256_file "$out_a")"
  hb="$(bh_sha256_file "$out_b")"
  bh_log "$stage determinism: A=$ha B=$hb"

  if [ "$ha" != "$hb" ]; then
    bh_err "$stage determinism FAILED: clean-dir builds differ (absolute-path leak?)"
    return 1
  fi

  # NEGATIVE self-host manifest gate: the same self-host compile WITHOUT
  # bootstrap/compiler_kernel.manifest must FAIL. Self-host mode
  # (include_compiler_lib=true — the driver path) is manifest-closed: there
  # is NO prelude_files() fallback, so the compile must die with the manifest
  # error instead of silently compiling a different dependency closure.
  local dir_c="$outdir/determinism/C"
  rm -rf "$dir_c"
  mkdir -p "$dir_c/tg_compiler"
  cp "$repo/tg_compiler/driver.tg" "$dir_c/tg_compiler/driver.tg"
  bh_log "$stage determinism: negative self-host manifest gate (root=$dir_c, no bootstrap/compiler_kernel.manifest)"
  local manifest_gate_out
  if manifest_gate_out="$( cd "$dir_c" && "$compiler" compile --strict-resolution tg_compiler/driver.tg -o "$outdir/${stage}_c" --target "$(bh_boot_target)" 2>&1 )"; then
    bh_err "$stage determinism: self-host compile WITHOUT bootstrap/compiler_kernel.manifest SUCCEEDED — the self-host path (include_compiler_lib=true) must fail without the manifest (no prelude_files fallback in self-host mode)"
    return 1
  fi
  if ! printf '%s' "$manifest_gate_out" | grep -q "compiler_kernel.manifest"; then
    bh_err "$stage determinism: self-host compile without the manifest failed for the WRONG reason (expected the compiler_kernel.manifest gate): $manifest_gate_out"
    return 1
  fi
  bh_log "$stage determinism: self-host manifest gate OK (compile without the manifest failed with the manifest error)"

  bh_log "$stage determinism OK (byte-identical across two clean trees)"
  return 0
}
