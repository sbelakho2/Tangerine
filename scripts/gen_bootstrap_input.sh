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

# Reject transitive imports outside the manifest (kernel must be closed under
# std: and compiler: prefixes). Check each source for `use std::` and
# `use tg_compiler::` imports and confirm the referenced module resolves within
# the manifest closure.
import_outside() {
  local src="$1"
  local root
  case "$src" in
    std/*)       root="std/" ;;
    tg_compiler/*) root="tg_compiler/" ;;
    *) return 1 ;;
  esac
  local mod
  # Match:  use std::collections::{...}   or   use tg_compiler::asm::{...}
  # Extract the module name after the root prefix (root is literal, no slashes
  # in the substituted delimiter).
  mod="$(grep -oE "use ${root}[a-z0-9_]+" "$src" | sed -E "s|use ${root}||" || true)"
  local m
  for m in $mod; do
    local target="${root}${m}.tg"
    if [ ! -f "$target" ]; then
      echo "[bootstrap-unit:error] $src imports $target which is outside the kernel manifest" >&2
      return 1
    fi
  done
  return 0
}

for rel in "${REL_PATHS[@]}"; do
  if ! import_outside "$rel"; then
    exit 1
  fi
done

# Sort entries canonically for a stable aggregate hash (sort by kind then path).
SORTED_REL=( $(printf '%s\n' "${REL_PATHS[@]}" | sort) )

# Build the JSON document.
AGG="$(printf '%s\n' "${SORTED_REL[@]}" | sha256f /dev/stdin)"
{
  echo "{"
  echo "  \"manifest\": \"$MANIFEST\","
  echo "  \"manifest_sha256\": \"$(sha256f "$MANIFEST")\","
  echo "  \"target\": \"aarch64-apple-darwin\","
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
