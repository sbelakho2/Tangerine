#!/usr/bin/env bash
#
# gen_bootstrap_input.sh — Deterministic bootstrap-unit generator.
#
# Consumes bootstrap/compiler_kernel.manifest as the single source of truth for
# the self-hosting bootstrap closure, validates every listed path, canonicalizes
# the entry order, computes per-source SHA-256 hashes plus an aggregate hash, and
# writes build/bootstrap-input.json.
#
# Stage0, stage1 and stage2 all consume this same definition; no second
# prelude_files()/hardcoded list describes bootstrap semantics.
#
# Usage:
#   scripts/gen_bootstrap_input.sh [--write]
#   --write  writes build/bootstrap-input.json (default: validate + print)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

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

# Build the canonical set of manifest source paths for membership checks.
MANIFEST_SET=()
for rel in "${REL_PATHS[@]}"; do
  MANIFEST_SET+=("$rel")
done

# Reject any transitive import outside the manifest closure. Tangerine imports
# use `use std::foo` and `use tg_compiler::foo` (double-colon module paths, not
# slashes). The kernel must be closed: every import of every listed source must
# resolve to a path that is itself a member of compiler_kernel.manifest, and the
# check iterates to a fixed point over newly-discovered sources.
imports_of() {
  # Emit normalized source paths (std/foo.tg, tg_compiler/foo.tg) for every
  # `use std::foo` / `use tg_compiler::foo` import in the file.
  grep -oE "use (std|tg_compiler)::[a-z0-9_]+" "$1" 2>/dev/null \
    | sed -E 's/^use (std|tg_compiler)::/\1\//; s/$/.tg/' || true
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
# The self-host bootstrap harness is macOS/AArch64-only. The target is threaded
# from the harness via TG_BOOTSTRAP_TARGET when set, else the canonical default.
BOOT_TARGET="${TG_BOOTSTRAP_TARGET:-aarch64-apple-darwin}"

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

echo "[bootstrap-unit] validated ${#SORTED_REL[@]} kernel sources from $MANIFEST"
echo "[bootstrap-unit] aggregate_source_hash: $(grep aggregate_source_hash "$OUT_JSON")"
echo "[bootstrap-unit] wrote $OUT_JSON"
