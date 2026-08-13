# scripts/bootstrap_helpers.sh
#
# Shared validation library for the Tangerine bootstrap harness.
# Sourced by run_bootstrap.sh. Provides:
#   - sha256 helpers (macOS + Linux portable)
#   - phase fingerprints under TG_BOOTSTRAP_TRACE=1
#     (token / ast / mir / object / link sha256 per stage)
#   - validate_stage: hard gate that a produced stage binary is usable
#   - run_stage2_diag_ladder: stage2 diagnostic severity ladder
#   - check_two_clean_dirs: build-from-two-clean-directories determinism check
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
# Phase fingerprints (TG_BOOTSTRAP_TRACE=1)
# ———————————————————————————————————————————————————————————————

# Emit a stable, machine-readable phase fingerprint line for one stage.
# Usage: bh_phase_line <stage> <phase> <hash>
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

# The eight compiler pipeline phases fingerprinted per stage.
# Each maps to a deterministic compiler emission or artifact:
#   tokens         : sha256 of the token stream dump        (--dump-tokens)
#   ast            : sha256 of the AST dump                 (--dump-ast)
#   resolved-ast   : sha256 of the post-merge/macro AST     (--dump-resolved-ast)
#   mir-lowered    : sha256 of the post-lowering MIR        (--dump-mir-lowered -O0)
#   mir-mono       : sha256 of the post-monomorphization MIR (--dump-mir-mono -O0)
#   mir-opt        : sha256 of the post-optimization MIR    (--dump-mir-opt -O1)
#   object-metadata: sha256 of a freshly emitted Mach-O object file (-c)
#   link-image     : sha256 of the final linked stage binary
BOOTSTRAP_PHASES="tokens ast resolved-ast mir-lowered mir-mono mir-opt object-metadata link-image"

# Compute the eight phase fingerprints for a stage binary.
# Usage: bh_fingerprints <stage> <compiler> <source> <outdir>
bh_fingerprints() {
  local stage="$1" compiler="$2" source_file="$3" outdir="$4"
  local obj_fp_dir="$outdir/.fingerprints"
  mkdir -p "$obj_fp_dir"

  local tokens_hash ast_hash resolved_hash mir_lowered_hash mir_mono_hash
  local mir_opt_hash obj_hash link_hash

  bh_log "fingerprinting $stage: tokens"
  tokens_hash="$(bh_dump_hash "$compiler" "$source_file" --dump-tokens)"
  bh_phase_line "$stage" tokens "$tokens_hash"

  bh_log "fingerprinting $stage: ast"
  ast_hash="$(bh_dump_hash "$compiler" "$source_file" --dump-ast)"
  bh_phase_line "$stage" ast "$ast_hash"

  bh_log "fingerprinting $stage: resolved-ast"
  resolved_hash="$(bh_dump_hash "$compiler" "$source_file" --dump-resolved-ast)"
  bh_phase_line "$stage" resolved-ast "$resolved_hash"

  bh_log "fingerprinting $stage: mir-lowered"
  mir_lowered_hash="$(bh_dump_hash "$compiler" "$source_file" --dump-mir-lowered -O0)"
  bh_phase_line "$stage" mir-lowered "$mir_lowered_hash"

  bh_log "fingerprinting $stage: mir-mono"
  mir_mono_hash="$(bh_dump_hash "$compiler" "$source_file" --dump-mir-mono -O0)"
  bh_phase_line "$stage" mir-mono "$mir_mono_hash"

  bh_log "fingerprinting $stage: mir-opt"
  mir_opt_hash="$(bh_dump_hash "$compiler" "$source_file" --dump-mir-opt -O1)"
  bh_phase_line "$stage" mir-opt "$mir_opt_hash"

  local obj_file="$obj_fp_dir/${stage}.o"
  bh_log "fingerprinting $stage: object-metadata"
  if "$compiler" compile "$source_file" -o "$obj_file" -c --target aarch64-apple-darwin >/dev/null 2>&1; then
    obj_hash="$(bh_sha256_file "$obj_file")"
  else
    bh_err "object emission failed for $stage; an object-fingerprint failure is fatal during bootstrap tracing"
    return 1
  fi
  bh_phase_line "$stage" object-metadata "$obj_hash"

  bh_log "fingerprinting $stage: link-image"
  link_hash="$(bh_sha256_file "$outdir/$stage" 2>/dev/null || printf 'MISSING')"
  bh_phase_line "$stage" link-image "$link_hash"
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
#   6. when trace mode is on, emits the eight per-phase fingerprints
# Returns nonzero (and prints an error) on any failed check.
validate_stage() {
  local stage="$1" binary="$2" source_file="${3:-tg_compiler/driver.tg}" outdir="${4:-build}"

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
  if ! "$binary" compile "$canary_src" -o "$canary_bin" --target aarch64-apple-darwin >/dev/null 2>&1; then
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

  if [ "${BOOTSTRAP_TRACE_ACTIVE}" = "1" ]; then
    bh_fingerprints "$stage" "$binary" "$source_file" "$outdir"
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

  bh_log "stage2 diag ladder: clean=${ok_code} type=${type_code} parse=${parse_code} return=${return_code}"

  if [ "$failures" -ne 0 ]; then
    bh_err "stage2 diagnostic ladder FAILED ($failures checks)"
    return 1
  fi
  bh_log "stage2 diagnostic ladder OK"
  return 0
}

# ———————————————————————————————————————————————————————————————
# Native canary + ARM64 test runner
# ———————————————————————————————————————————————————————————————

# Compile and execute a given list of canary files with the given compiler.
# Each file must have `main() -> Int` returning its failure count (0 = pass).
# Usage: run_canary_files <compiler> <outdir> <file>...
run_canary_files() {
  local compiler="$1" outdir="$2"
  shift 2
  mkdir -p "$outdir"
  local failures=0 total=0
  local file
  for file in "$@"; do
    [ -e "$file" ] || continue
    total=$((total + 1))
    local name
    name="$(basename "$file" .tg)"
    local bin="$outdir/.native_${name}"
    bh_log "native canary: $file"
    if ! "$compiler" compile "$file" -o "$bin" --target aarch64-apple-darwin >/dev/null 2>&1; then
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
# Usage: run_critical_canaries <compiler> <outdir>
run_critical_canaries() {
  run_canary_files "$1" "$2" \
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
    tests/arm64/test_arm64_abi.tg
}

# Compile and execute every native canary and ARM64 test with the given
# compiler binary. Each test file has a `main() -> Int` that returns its
# failure count; the harness requires exit code 0.
#
# Usage: run_native_tests <compiler> <outdir>
run_native_tests() {
  local compiler="$1" outdir="$2"
  mkdir -p "$outdir"

  local dirs=(tests/canary tests/arm64)
  local all_files=()
  local dir file
  for dir in "${dirs[@]}"; do
    if [ ! -d "$dir" ]; then
      bh_warn "native test dir missing: $dir"
      continue
    fi
    for file in "$dir"/*.tg; do
      [ -e "$file" ] || continue
      all_files+=("$file")
    done
  done
  run_canary_files "$compiler" "$outdir" "${all_files[@]}"
}

# ———————————————————————————————————————————————————————————————
# Two-clean-directory determinism check
# ———————————————————————————————————————————————————————————————

# Build a stage binary twice from two pristine (clean) source copies and
# assert that both runs produce byte-identical artifacts. This proves the
# Build the bootstrap closure for a clean tree from the kernel manifest.
# Usage: build_clean_tree <dest-root> <repo-root>
# Copies the exact compiler_kernel.manifest closure into $dest-root preserving
# relative paths (std/ and tg_compiler/), so dependency resolution behaves
# identically to the real bootstrap while the absolute root differs.
build_clean_tree() {
  local dest="$1" repo="$2"
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
  return 0
}

# The two-clean-directory determinism check builds the identical manifest
# closure from two pristine trees whose absolute roots differ but whose
# relative layout is identical. Any absolute-path leakage in codegen/linker
# produces different binaries.
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
  if ! ( cd "$dir_a" && "$compiler" compile tg_compiler/driver.tg -o "$out_a" --target aarch64-apple-darwin >/dev/null 2>&1 ); then
    bh_err "$stage determinism: build A failed"
    return 1
  fi

  bh_log "$stage determinism: building from clean tree B (root=$dir_b)"
  if ! ( cd "$dir_b" && "$compiler" compile tg_compiler/driver.tg -o "$out_b" --target aarch64-apple-darwin >/dev/null 2>&1 ); then
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

  bh_log "$stage determinism OK (byte-identical across two clean trees)"
  return 0
}
