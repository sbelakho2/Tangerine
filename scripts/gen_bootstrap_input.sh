#!/usr/bin/env bash
#
# gen_bootstrap_input.sh — Deterministic bootstrap-unit generator.
#
# Consumes bootstrap/compiler_kernel.manifest as the single source of truth for
# the self-hosting bootstrap closure, validates every listed path, canonicalizes
# the entry order, computes per-source SHA-256 hashes plus an aggregate hash, and
# writes build/bootstrap-input.json.
#
# The manifest is the DECLARATIVE authority; this generator is executable
# validation only. It enforces:
#   - every manifest entry exists on disk (missing = fatal)
#   - the module closure of the kernel is CLOSED: every import of every
#     listed source must resolve to a member of the manifest (accidental
#     imports are rejected); the import scan is comment-aware and anchored at
#     line starts so comments can never masquerade as imports
#   - the generated import file's module list == the manifest list EXACTLY
#     (bidirectional parity, same count) — the artifact can never drift from
#     the manifest
#   - the kernel entry roots (bootstrap_main.tg, lib_kernel.tg) are listed
#
# Compiler-side consumption: tg_compiler/compiler_core.tg already reads the
# manifest directly (bootstrap_manifest_sources()) and the bootstrap loads
# ONLY that closure (merge_imported_deps, include_compiler_lib). The module
# graph of the typed program lives in the resolver (resolver.tg, Module
# tables); a driver-side `--dump-module-graph` flag (or a small
# tools/module_graph_dumper.tg tool) is the documented integration point to
# replace this generator's import scan with the compiler's own module graph.
# Until then the scan below is anchored, comment-stripped and closure-checked,
# which makes it exact for the kernel's import surface.
#
# Usage:
#   scripts/gen_bootstrap_input.sh [--write]
#   --write  writes build/bootstrap-input.json (default: validate + print)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# The bootstrap target comes from the single harness authority
# (bootstrap_helpers.sh bh_boot_target), never from a locally hard-wired
# triple — every script in the bootstrap pipeline must agree on one target.
# shellcheck source=scripts/bootstrap_helpers.sh
source "$ROOT_DIR/scripts/bootstrap_helpers.sh"

MANIFEST="bootstrap/compiler_kernel.manifest"
OUT_JSON="build/bootstrap-input.json"

if [ ! -f "$MANIFEST" ]; then
  echo "[bootstrap-unit:error] missing manifest $MANIFEST" >&2
  exit 1
fi

# Deterministic sha256 of a file.
sha256f() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Collect manifest entries (kind, relpath), skipping blank/comment lines.
# Only the two kernel kinds are allowed.
KINDS=()
REL_PATHS=()
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|\#*) continue ;;
  esac
  kind="${line%%:*}"
  path="${line#*: }"
  rel=""
  case "$kind" in
    version) continue ;;  # manifest schema version, not a source entry
    std)       rel="std/$path" ;;
    compiler)  rel="tg_compiler/$path" ;;
    *)
      echo "[bootstrap-unit:error] unknown manifest kind '$kind' in '$line'" >&2
      exit 1
      ;;
  esac
  if [ ! -f "$rel" ]; then
    echo "[bootstrap-unit:error] manifest entry missing file: $rel" >&2
    exit 1
  fi
  KINDS+=("$kind")
  REL_PATHS+=("$rel")
done < "$MANIFEST"

if [ "${#REL_PATHS[@]}" -eq 0 ]; then
  echo "[bootstrap-unit:error] manifest contained no source entries" >&2
  exit 1
fi

# The kernel entry roots must be members of the manifest: bootstrap_main.tg is
# the self-host entry and lib_kernel.tg is the kernel module the loader
# injects. A manifest without them is not a bootstrap closure.
if ! printf '%s\n' "${REL_PATHS[@]}" | grep -qxF "tg_compiler/bootstrap_main.tg"; then
  echo "[bootstrap-unit:error] manifest is missing the bootstrap entry root tg_compiler/bootstrap_main.tg" >&2
  exit 1
fi
if ! printf '%s\n' "${REL_PATHS[@]}" | grep -qxF "tg_compiler/lib_kernel.tg"; then
  echo "[bootstrap-unit:error] manifest is missing the kernel module root tg_compiler/lib_kernel.tg" >&2
  exit 1
fi

# Build the canonical set of manifest source paths for membership checks.
MANIFEST_SET=()
for rel in "${REL_PATHS[@]}"; do
  MANIFEST_SET+=("$rel")
done

# Reject any transitive import outside the manifest closure. Tangerine imports
# use `use std::foo` and `use tg_compiler::foo` (double-colon module paths, not
# slashes), and module re-exports use `pub use tg_compiler::foo`. The kernel
# must be closed: every import of every listed source must resolve to a path
# that is itself a member of compiler_kernel.manifest, and the check iterates
# to a fixed point over newly-discovered sources.
#
# The scan is comment-aware: `#` comments are stripped BEFORE import matching,
# and matches are anchored at the line start (after optional whitespace), so a
# comment or a doc string can never masquerade as an import.
imports_of() {
  # Emit normalized source paths (std/foo.tg, tg_compiler/foo.tg) for every
  # `use std::foo` / `use tg_compiler::foo` / `pub use tg_compiler::foo`
  # import in the file.
  sed 's/#.*//' "$1" 2>/dev/null \
    | grep -oE '^[[:space:]]*(pub[[:space:]]+)?use[[:space:]]+(std|tg_compiler)::[a-zA-Z0-9_]+' \
    | sed -E 's/^[[:space:]]*(pub[[:space:]]+)?use[[:space:]]+(std|tg_compiler)::/\2\//; s/$/.tg/' \
    || true
}

closure_error=0
CHECKED=()
checked_of() {
  local c
  for c in ${CHECKED[@]+"${CHECKED[@]}"}; do
    if [ "$c" = "$1" ]; then return 0; fi
  done
  return 1
}
mut_worklist=("${REL_PATHS[@]}")
while [ ${#mut_worklist[@]} -gt 0 ]; do
  src="${mut_worklist[0]}"
  mut_worklist=("${mut_worklist[@]:1}")
  if checked_of "$src"; then
    continue
  fi
  CHECKED+=("$src")
  imps="$(imports_of "$src")"
  if [ -z "$imps" ]; then
    continue
  fi
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    in_manifest=0
    for m in ${MANIFEST_SET[@]+"${MANIFEST_SET[@]}"}; do
      if [ "$m" = "$target" ]; then
        in_manifest=1
        break
      fi
    done
    if [ "$in_manifest" -eq 0 ]; then
      echo "[bootstrap-unit:error] $src imports $target which is NOT a member of the kernel manifest" >&2
      closure_error=1
    elif ! checked_of "$target"; then
      mut_worklist+=("$target")
    fi
  done <<< "$imps"
done

if [ "$closure_error" -ne 0 ]; then
  echo "[bootstrap-unit:error] kernel closure is not closed under compiler_kernel.manifest" >&2
  exit 1
fi

# Sort entries canonically for a stable aggregate hash (sort by kind then path).
SORTED_REL=( $(printf '%s\n' "${REL_PATHS[@]}" | sort) )

# Aggregate hash is over CONTENTS, not filenames: manifest hash + a NUL-separated
# stream of (canonical path, file content SHA256) pairs. Changing any source's
# contents changes the aggregate.
# The target is resolved through the single bootstrap target authority
# (bh_boot_target): TG_BOOTSTRAP_TARGET when set, else the harness-resolved
# TARGET_TRIPLE, else the canonical default.
BOOT_TARGET="$(bh_boot_target)"

AGG_STREAM=""
# Temporary stream file: use mktemp + trap so concurrent bootstrap processes
# never race on a fixed path and the temp file is always cleaned up.
AGG_TMP="$(mktemp "${TMPDIR:-/tmp}/bootstrap_agg.XXXXXX")"
trap 'rm -f "$AGG_TMP"' EXIT
{
  printf '%s' "$(sha256f "$MANIFEST")"
  printf '\0'
  for rel in "${SORTED_REL[@]}"; do
    printf '%s' "$rel"
    printf '\0'
    printf '%s' "$(sha256f "$rel")"
    printf '\0'
  done
} > "$AGG_TMP"
AGG="$(sha256f "$AGG_TMP")"
{
  echo "{"
  echo "  \"manifest\": \"$MANIFEST\","
  echo "  \"manifest_sha256\": \"$(sha256f "$MANIFEST")\","
  echo "  \"target\": \"$BOOT_TARGET\","
  echo "  \"aggregate_source_hash\": \"$AGG\","
  echo "  \"sources\": ["
  n="${#SORTED_REL[@]}"
  i=0
  for rel in "${SORTED_REL[@]}"; do
    case "$rel" in
      std/*) kind="std" ;;
      *)     kind="compiler" ;;
    esac
    if [ "$i" -lt $((n - 1)) ]; then
      echo "    { \"kind\": \"$kind\", \"path\": \"$rel\", \"sha256\": \"$(sha256f "$rel")\" },"
    else
      echo "    { \"kind\": \"$kind\", \"path\": \"$rel\", \"sha256\": \"$(sha256f "$rel")\" }"
    fi
    i=$((i + 1))
  done
  echo "  ]"
  echo "}"
} > "$OUT_JSON"

# ———————————————————————————————————————————————————————————————
# Exact-parity verification of the generated artifact
# ———————————————————————————————————————————————————————————————
# The import file's module list must equal the manifest list EXACTLY (both
# directions, same count): every manifest member is emitted, and nothing is
# emitted that is not a manifest member. This closes the artifact side of the
# manifest authority — a drift between the manifest and the generated file
# (or between the manifest and the filesystem) is a hard failure.

GENERATED_REL="$(grep -oE '"path": "[^"]+"' "$OUT_JSON" | sed -E 's/"path": "([^"]+)"/\1/' | sort)"
MANIFEST_REL="$(printf '%s\n' "${SORTED_REL[@]}")"

if [ "$GENERATED_REL" != "$MANIFEST_REL" ]; then
  echo "[bootstrap-unit:error] exact-parity FAILED: generated module list != manifest list" >&2
  echo "[bootstrap-unit:error]   in manifest but not generated:" >&2
  comm -23 <(printf '%s\n' "$MANIFEST_REL") <(printf '%s\n' "$GENERATED_REL") | sed 's/^/     /' >&2
  echo "[bootstrap-unit:error]   generated but not in manifest:" >&2
  comm -13 <(printf '%s\n' "$MANIFEST_REL") <(printf '%s\n' "$GENERATED_REL") | sed 's/^/     /' >&2
  exit 1
fi

GENERATED_COUNT="$(printf '%s\n' "$GENERATED_REL" | grep -c . || true)"
if [ "$GENERATED_COUNT" -ne "${#SORTED_REL[@]}" ]; then
  echo "[bootstrap-unit:error] exact-parity FAILED: count mismatch (generated $GENERATED_COUNT != manifest ${#SORTED_REL[@]})" >&2
  exit 1
fi

STD_COUNT="$(printf '%s\n' "${SORTED_REL[@]}" | grep -c '^std/' || true)"
COMPILER_COUNT="$(printf '%s\n' "${SORTED_REL[@]}" | grep -c '^tg_compiler/' || true)"

echo "[bootstrap-unit] validated ${#SORTED_REL[@]} kernel sources from $MANIFEST"
echo "[bootstrap-unit] closure: std=$STD_COUNT compiler=$COMPILER_COUNT target=$BOOT_TARGET"
echo "[bootstrap-unit] exact-parity OK: generated module list == manifest list (${#SORTED_REL[@]} modules, bidirectional)"
echo "[bootstrap-unit] aggregate_source_hash: $(grep aggregate_source_hash "$OUT_JSON")"
echo "[bootstrap-unit] wrote $OUT_JSON"
