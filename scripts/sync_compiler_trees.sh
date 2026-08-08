#!/usr/bin/env bash
# sync_compiler_trees.sh — Keep tg_compiler/ and stage0_swift/tg_compiler/ in sync.
#
# The stage0 Swift compiler reads its self-hosted compiler source from
# stage0_swift/tg_compiler/ (a nested mirror), while the actual bootstrap
# toolchain reads from tg_compiler/ at the repo root. These two trees MUST
# be byte-identical (or at least produce identical post-MIR code) or the
# bootstrap pipeline produces divergent binaries at each stage.
#
# Usage:
#   scripts/sync_compiler_trees.sh           # copy tg_compiler -> stage0_swift/tg_compiler
#   scripts/sync_compiler_trees.sh --check   # verify they are in sync (exit 1 if not)
#   scripts/sync_compiler_trees.sh --reverse # copy stage0_swift/tg_compiler -> tg_compiler
#
# The script:
#   1. Hashes every .tg file in the source tree (relative paths)
#   2. Compares the hash sets of both trees
#   3. Reports any files that differ or are missing in one tree
#   4. On a normal run, copies the source -> destination
#
# Exit codes:
#   0 — trees are in sync (or were successfully synced)
#   1 — trees are out of sync (only with --check)
#   2 — source tree is missing required directories

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/tg_compiler"
DEST_DIR="$ROOT_DIR/stage0_swift/tg_compiler"

MODE="sync"  # sync | check | reverse
case "${1:-sync}" in
  --check)  MODE="check" ;;
  --reverse) MODE="reverse" ;;
  sync|"")  MODE="sync" ;;
  -h|--help)
    sed -n '2,28p' "$0"
    exit 0
    ;;
  *)
    echo "Unknown option: $1" >&2
    echo "Usage: $0 [--check | --reverse]" >&2
    exit 2
    ;;
esac

if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "ERROR: source directory missing: $SOURCE_DIR" >&2
  exit 2
fi

# Compute hashes of every .tg file under a given directory, keyed by relative path.
# Output format: one line "<sha256>  <relative-path>" per file.
hash_tree() {
  local root="$1"
  if [[ ! -d "$root" ]]; then
    echo ""
    return
  fi
  ( cd "$root" && find . -type f -name '*.tg' -print0 \
    | xargs -0 -I{} sh -c 'printf "%s  %s\n" "$(shasum -a 256 "{}" | awk "{print \$1}")" "{}"' \
    | sort -k 2 )
}

SOURCE_HASHES="$(hash_tree "$SOURCE_DIR")"
DEST_HASHES="$(hash_tree "$DEST_DIR")"

# Compute symmetric difference of file sets.
SOURCE_FILES="$(echo "$SOURCE_HASHES" | awk '{print $2}' | sort)"
DEST_FILES="$(echo "$DEST_HASHES"   | awk '{print $2}' | sort)"

ONLY_IN_SOURCE="$(comm -23 <(echo "$SOURCE_FILES") <(echo "$DEST_FILES") || true)"
ONLY_IN_DEST="$(comm -13 <(echo "$SOURCE_FILES") <(echo "$DEST_FILES") || true)"
COMMON_FILES="$(comm -12 <(echo "$SOURCE_FILES") <(echo "$DEST_FILES") | sort || true)"

# For common files, check the hashes agree.
MISMATCHED=""
while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  src_h="$(echo "$SOURCE_HASHES" | awk -v r="$rel" '$2==r{print $1; exit}')"
  dst_h="$(echo "$DEST_HASHES"   | awk -v r="$rel" '$2==r{print $1; exit}')"
  if [[ "$src_h" != "$dst_h" ]]; then
    MISMATCHED+="$rel\n"
  fi
done <<< "$COMMON_FILES"

TOTAL_DIFFS=0
[[ -n "$ONLY_IN_SOURCE" ]] && TOTAL_DIFFS=$((TOTAL_DIFFS + $(echo "$ONLY_IN_SOURCE" | wc -l | tr -d ' ')))
[[ -n "$ONLY_IN_DEST"   ]] && TOTAL_DIFFS=$((TOTAL_DIFFS + $(echo "$ONLY_IN_DEST"   | wc -l | tr -d ' ')))
[[ -n "$MISMATCHED"     ]] && TOTAL_DIFFS=$((TOTAL_DIFFS + $(echo -e "$MISMATCHED" | grep -c . || true)))

if [[ "$TOTAL_DIFFS" -eq 0 ]]; then
  echo "OK: tg_compiler/ and stage0_swift/tg_compiler/ are in sync ($($echo_command wc -l <<< "$SOURCE_FILES") files)"
  if [[ "$MODE" == "check" ]]; then
    exit 0
  fi
  exit 0
fi

echo "ERROR: compiler trees are out of sync ($TOTAL_DIFFS differences)" >&2

if [[ -n "$ONLY_IN_SOURCE" ]]; then
  echo "" >&2
  echo "  Files only in $SOURCE_DIR (will be added to dest):" >&2
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    echo "    + $f" >&2
  done <<< "$ONLY_IN_SOURCE"
fi

if [[ -n "$ONLY_IN_DEST" ]]; then
  echo "" >&2
  echo "  Files only in $DEST_DIR (will be removed from dest if reverse, otherwise flagged):" >&2
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    echo "    - $f" >&2
  done <<< "$ONLY_IN_DEST"
fi

if [[ -n "$MISMATCHED" ]]; then
  echo "" >&2
  echo "  Files that differ (will be overwritten if syncing):" >&2
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    echo "    * $f" >&2
  done <<< "$(echo -e "$MISMATCHED" | grep .)"
fi

if [[ "$MODE" == "check" ]]; then
  exit 1
fi

# --sync (or default): SOURCE -> DEST.
# --reverse: DEST -> SOURCE.
if [[ "$MODE" == "reverse" ]]; then
  SRC="$DEST_DIR"
  DST="$SOURCE_DIR"
  LABEL="stage0_swift/tg_compiler -> tg_compiler"
else
  SRC="$SOURCE_DIR"
  DST="$DEST_DIR"
  LABEL="tg_compiler -> stage0_swift/tg_compiler"
fi

echo ""
echo "Syncing: $LABEL"
mkdir -p "$DST"

# Copy every .tg file using the relative paths under the source root.
while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  src_path="$SRC/${rel#./}"
  dst_path="$DST/${rel#./}"
  mkdir -p "$(dirname "$dst_path")"
  cp "$src_path" "$dst_path"
done < <(cd "$SRC" && find . -type f -name '*.tg')

# For --reverse, also remove files that exist in source but not in dest,
# because the source tree is the one being overwritten.
if [[ "$MODE" == "reverse" ]]; then
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    dst_path="$DST/${rel#./}"
    rm -f "$dst_path"
  done <<< "$ONLY_IN_DEST"
fi

echo "Done."
