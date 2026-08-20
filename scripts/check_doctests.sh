#!/usr/bin/env bash
#
# scripts/check_doctests.sh — the documentation doctest gate.
#
# Every fenced Tangerine example in the six doctested documents either
# compiles under the current grammar or is annotated `compile_fail: <the
# expected diagnostic substring>`. This script extracts the fenced blocks
# and machine-checks that contract:
#
#   Documents (docs/current/):
#     language.md, grammar.md, memory_model.md, stabilized_subset.md,
#     feature_matrix.md, feature_registry.md
#
#   Block classification:
#     - a fence labeled ```tangerine OR unlabeled (bare ```) is a doctest;
#     - any other label (ebnf, text, bash, c, ...) is NOT a doctest (the
#       round-10 sweep relabeled every non-code fence — ASCII diagrams,
#       keyword lists, quoted diagnostic output — so no unlabeled fence is
#       left that is not Tangerine source);
#     - a doctest whose FIRST line is `# compile_fail: <substring>` is a
#       rejection example: it must be rejected and the rejection must
#       contain <substring> in the diagnostic text;
#     - an unannotated doctest must be accepted (no rejection).
#
#   Structural mode (always runs; the authoritative gate when no current
#   compiler binary exists): every unannotated block is scanned for the
#   forbidden legacy forms after stripping `#` comments and string/char
#   literals (the same sanitization the self-host grammar gate uses):
#       - `x: &T` / `x: &mut T` parameter type markers  (E100)
#       - `-> &T` return-position references              (E106)
#       - `fn(&T)` / `fn(mut T)` / `fn(move T)` / `fn(own T)` (E100)
#       - `&x:` / `&mut x:` / `mut x:` / `move x:` / `own x:` param
#         prefixes (E100)
#       - `&self` / `&mut self` receivers                (E100)
#       - `ref x` pattern binders                        (E106)
#       - the convention-AFTER-colon spelling `x: sink T` /
#         `x: inout T` / `x: set T` (the canonical form is the prefix
#         `sink x: T`; the suffix spelling is not parseable)
#     Any hit in an unannotated block is a doctest failure.
#     For a compile_fail block the scan must find at least one forbidden
#     form AND the expected substring must match one of the known
#     parse-stage diagnostic phrases below — so the annotation is verified
#     against the compiler's diagnostic texts, not hand-waved.
#
#   Compiler mode (when a probe-validated binary exists — it must check a
#   good probe AND reject a legacy-spelling probe, so a stale pre-E100
#   binary never false-passes): each unannotated block is compiled with
#   `check`. Blocks with no top-level-only item keyword (extern, cap,
#   effect, macro, module, mod, edition, rationale, trait, pub, private,
#   const, static, resource, @) are wrapped in a probe function so
#   statement-level fragments parse; a parse-stage diagnostic (E100-E108)
#   is a hard failure, while a semantic-only failure of an illustrative
#   fragment (unresolved names in API-only examples) is a warning. Each
#   compile_fail block must be rejected with the expected substring in
#   the diagnostics.
#
# Usage: scripts/check_doctests.sh [compiler]
#   compiler defaults to the first probe-validated build/tg_stage{1,2,3}
#   binary (checked in that order).
# Exit status: 0 when every doctest passes; non-zero otherwise.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCS=(language.md grammar.md memory_model.md stabilized_subset.md feature_matrix.md feature_registry.md)

# ── known parse-stage diagnostic phrases (the compiler's texts) ────────────
# Structural-mode verification of `compile_fail:` annotations: the expected
# substring must contain one of these (substring match). These mirror the
# diagnostic strings emitted by the current parser/type checker.
KNOWN_PHRASES=(
  "legacy parameter spelling"                      # E100 (parse_param / parse_fn_type_param)
  "safe reference types are not first-class"       # E106 (diag_safe_ref_not_first_class)
  "ref patterns are not supported"                 # E106 (diag_ref_pattern_not_supported)
  "access marker"                                  # ExprAccess misuse (types.tg)
  "unresolved name"                                # resolution (fail-closed)
)

# ── forbidden legacy forms (structural scan) ───────────────────────────────
# The awk sanitizer strips `#` line comments, "..." strings and '...' char
# literals so prose-in-code and string payloads cannot trip the scan. The
# patterns are the grammar gate's set plus the convention-after-colon
# spelling and the `ref` binder.
SCAN_AWK='
  function sanitize(s,    i, n, out, c, in_str) {
    n = length(s)
    out = ""
    in_str = 0
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (in_str) {
        if (c == "\\") { i++ ; continue }
        if (c == "\"") { in_str = 0 }
        continue
      }
      if (c == "\"") { in_str = 1 ; out = out "\"\"" ; continue }
      if (c == 39) {
        i++
        while (i <= n) {
          cc = substr(s, i, 1)
          if (cc == "\\") { i += 2 ; continue }
          if (cc == 39) { break }
          i++
        }
        continue
      }
      if (c == "#") { break }
      out = out c
    }
    return out
  }
  {
    L = sanitize($0)
    if (L ~ /:[ \t]*&(mut[ \t]+)?[A-Za-z_<]/)                { print "legacy reference parameter marker (`: &T` / `: &mut T`)" }
    else if (L ~ /->[ \t]*&/)                                  { print "legacy reference return type (`-> &T`)" }
    else if (L ~ /(^|[^A-Za-z0-9_])fn[ \t]*\([ \t]*&/)         { print "legacy fn-type reference parameter (`fn(&T)` / `fn(&mut T)`)" }
    else if (L ~ /(^|[^A-Za-z0-9_])fn[ \t]*\([ \t]*(mut[ \t]+|move[ \t]+|own[ \t]+)[A-Za-z_<]/) { print "legacy fn-type convention prefix (`fn(mut T)` / `fn(move T)` / `fn(own T)`)" }
    else if (L ~ /([(,])[ \t]*&(mut[ \t]+)?[a-z_][A-Za-z0-9_]*[ \t]*:[ \t]*[^: \t]/) { print "legacy parameter prefix (`&x:` / `&mut x:`)" }
    else if (L ~ /([(,])[ \t]*(mut|move|own)[ \t]+[a-z_][A-Za-z0-9_]*[ \t]*:[ \t]*[^: \t]/) { print "legacy parameter prefix (`mut x:` / `move x:` / `own x:`)" }
    else if (L ~ /([(,])[ \t]*&(mut[ \t]+)?self([ \t]*[,):])/) { print "legacy receiver (`&self` / `&mut self`)" }
    else if (L ~ /(^|[^A-Za-z0-9_])ref[ \t]+[a-z_][A-Za-z0-9_]*/) { print "legacy ref pattern binder (`ref x`)" }
    else if (L ~ /:[ \t]*(sink|inout|set)[ \t]+[a-z_][A-Za-z0-9_]*/) { print "convention after the colon (`x: sink T` — write `sink x: T`)" }
  }
'

fail=0
n_blocks=0
n_annotated=0
n_failed=0
n_warned=0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tg_doctests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ── extract the fenced blocks of one document ──────────────────────────────
extract_blocks() { # extract_blocks <doc-path> <outdir>
  local doc="$1" out="$2"
  awk -v out="$out" '
    /^```/ {
      if (!in_fence) {
        in_fence = 1
        n++
        rest = substr($0, 4)
        gsub(/^[ \t]+/, "", rest)
        split(rest, a, /[ \t]/)
        label = a[1]
        printf "%s", label > (out "/" n ".label")
        close(out "/" n ".label")
      } else {
        in_fence = 0
      }
      next
    }
    in_fence { print > (out "/" n ".block") }
  ' "$doc"
}

# ── structural scan: forbidden legacy forms in a block ─────────────────────
scan_block() { # scan_block <file> ; echoes the hits, exit 0 when none
  local hits
  hits="$(awk "$SCAN_AWK" "$1")"
  if [ -z "$hits" ]; then
    return 0
  fi
  printf '%s\n' "$hits"
  return 1
}

# ── probe-validated compiler discovery ─────────────────────────────────────
find_compiler() { # find_compiler [explicit]
  local explicit="${1:-}" bin=""
  if [ -n "$explicit" ]; then
    if [ -x "$explicit" ]; then
      bin="$explicit"
    else
      echo "doctests: explicit compiler not executable: $explicit" >&2
      return 1
    fi
  else
    for cand in tg_stage3 tg_stage2 tg_stage1; do
      if [ -x "$ROOT/build/$cand" ]; then
        bin="$ROOT/build/$cand"
        break
      fi
    done
  fi
  [ -n "$bin" ] || return 1

  # Usable only when it is a real working compiler (checks a trivial good
  # probe) AND implements the CURRENT grammar (rejects a legacy probe).
  mkdir -p "$WORK"
  printf 'def doctest_good_probe() -> Int\n  0\nend\n' > "$WORK/good.tg"
  printf 'def doctest_legacy_probe(x: &Int) -> Int\n  x\nend\n' > "$WORK/legacy.tg"
  if ( "$bin" check "$WORK/good.tg" >/dev/null 2>&1 ) && \
     ! ( "$bin" check "$WORK/legacy.tg" >/dev/null 2>&1 ); then
    printf '%s' "$bin"
    return 0
  fi
  echo "doctests: $bin exists but is not a current-grammar compiler (probe not rejected) — structural mode only" >&2
  return 1
}

# ── wrap decision: does the block contain a top-level-only item keyword? ───
needs_wrap() { # needs_wrap <file> ; exit 0 when wrapping is required
  awk '
    /^[ \t]*#/ || /^[ \t]*$/ { next }
    {
      line = $0
      gsub(/^[ \t]+/, "", line)
      split(line, a, /[ \t(]/)
      kw = a[1]
      if (kw ~ /^(extern|cap|effect|macro|module|mod|edition|rationale|trait|pub|private|const|static|resource|@)$/) {
        exit 1
      }
    }
    END { exit 0 }
  ' "$1"
}

TOP_ONLY_RE='(extern|cap|effect|macro|module|mod|edition|rationale|trait|pub|private|const|static|resource|@)'

# ── compile one block (compiler mode) ──────────────────────────────────────
compile_block() { # compile_block <compiler> <block-file> ; echoes status line
  local compiler="$1" file="$2" work="$WORK/$(basename "$file").check.tg"
  if needs_wrap "$file"; then
    { printf 'def __doctest_probe() -> Unit\n'; cat "$file"; printf '\nend\n'; } > "$work"
  else
    cp "$file" "$work"
  fi
  local out
  out="$("$compiler" check "$work" 2>&1)"
  local rc=$?
  if [ $rc -eq 0 ]; then
    echo "OK"
    return 0
  fi
  if printf '%s' "$out" | grep -qE 'E10[0-8]'; then
    echo "PARSE_FAIL"
    printf '%s\n' "$out" | grep -E 'E10[0-8]' | head -4
    return 1
  fi
  echo "WARN"
  return 2
}

# ── main ───────────────────────────────────────────────────────────────────
COMPILER="$(find_compiler "${1:-}" || true)"
MODE="structural"
if [ -n "$COMPILER" ]; then
  MODE="compiler ($COMPILER)"
fi
echo "doctests: mode = $MODE"
echo "doctests: documents = ${DOCS[*]}"

for doc in "${DOCS[@]}"; do
  path="$ROOT/docs/current/$doc"
  [ -f "$path" ] || { echo "[FAIL] missing document: $path" >&2; fail=1; continue; }
  outdir="$WORK/$(basename "$doc" .md)"
  mkdir -p "$outdir"
  extract_blocks "$path" "$outdir"

  for label_file in "$outdir"/*.label; do
    [ -f "$label_file" ] || continue
    label="$(cat "$label_file")"
    n="$outdir/$(basename "$label_file" .label)"
    block="$n.block"
    [ -f "$block" ] || continue
    # Only ```tangerine and unlabeled fences are doctests.
    if [ -n "$label" ] && [ "$label" != "tangerine" ]; then
      continue
    fi
    n_blocks=$((n_blocks + 1))

    # compile_fail annotation: the FIRST line of the block.
    expected="$(sed -n '1s/^[ \t]*#*[ \t]*compile_fail:[ \t]*//p' "$block" | head -1)"
    if [ -n "$expected" ]; then
      n_annotated=$((n_annotated + 1))
      # Structural verification: the block must contain a forbidden form
      # AND the expected substring must match a known diagnostic phrase.
      hits="$(scan_block "$block" 2>/dev/null)" || true
      known=0
      for ph in "${KNOWN_PHRASES[@]}"; do
        case "$expected" in
          *"$ph"*) known=1 ;;
        esac
      done
      if [ -z "$hits" ]; then
        echo "[FAIL] $doc:block $n — compile_fail block contains no forbidden legacy form (annotation cannot be structurally verified)" >&2
        n_failed=$((n_failed + 1))
      elif [ "$known" -eq 0 ]; then
        echo "[FAIL] $doc:block $n — compile_fail expected substring \`$expected\` is not a known parse-stage diagnostic phrase (see KNOWN_PHRASES)" >&2
        n_failed=$((n_failed + 1))
      else
        # Compiler mode: must actually be rejected with the substring.
        if [ -n "$COMPILER" ]; then
          cp "$block" "$n.annotated.tg"
          out="$("$COMPILER" check "$n.annotated.tg" 2>&1)"
          rc=$?
          if [ $rc -eq 0 ]; then
            echo "[FAIL] $doc:block $n — compile_fail block compiled cleanly (expected rejection with \`$expected\`)" >&2
            n_failed=$((n_failed + 1))
          elif ! printf '%s' "$out" | grep -qF "$expected"; then
            echo "[FAIL] $doc:block $n — rejection output lacks the expected diagnostic \`$expected\`" >&2
            n_failed=$((n_failed + 1))
          else
            echo "[PASS] $doc:block $n — compile_fail (rejected with \`$expected\`)"
          fi
        else
          echo "[PASS] $doc:block $n — compile_fail (structural: forbidden form present, expected \`$expected\`)"
        fi
      fi
      continue
    fi

    # Unannotated block: must be free of every forbidden form.
    if hits="$(scan_block "$block")"; then
      if [ -n "$COMPILER" ]; then
        status="$(compile_block "$COMPILER" "$block")"
        case "$status" in
          OK) echo "[PASS] $doc:block $n — checks clean" ;;
          WARN)
            echo "[WARN] $doc:block $n — illustrative fragment: parse-clean, semantic-only failures (unresolved names etc.)"
            n_warned=$((n_warned + 1))
            ;;
          *)
            echo "[FAIL] $doc:block $n — parse-stage diagnostics (E100–E108) under $COMPILER:" >&2
            printf '%s\n' "$status" | sed 's/^/    /' >&2
            n_failed=$((n_failed + 1))
            ;;
        esac
      else
        echo "[PASS] $doc:block $n — structural scan clean"
      fi
    else
      echo "[FAIL] $doc:block $n — forbidden legacy form(s) in an unannotated doctest:" >&2
      printf '%s\n' "$hits" | sed 's/^/    /' >&2
      n_failed=$((n_failed + 1))
    fi
  done
done

echo "doctests: $n_blocks block(s), $n_annotated compile_fail, $n_failed failed, $n_warned fragment warning(s)"
if [ "$n_failed" -ne 0 ]; then
  exit 1
fi
exit 0
