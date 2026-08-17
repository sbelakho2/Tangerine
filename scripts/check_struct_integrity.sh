#!/usr/bin/env bash
# Static integrity check: every `struct` declaration in the compiler sources
# must have fields (or be empty) and a terminating `end` before the next
# top-level construct. A malformed struct (missing fields or missing `end`)
# silently corrupts the self-hosted build; this check catches the class of
# breakage BEFORE a commit.
set -u
failures=0
for f in tg_compiler/*.tg; do
  # Collect top-level struct declarations with their extents.
  awk '
    /^struct [A-Za-z_][A-Za-z0-9_]*$/ { name=$2; in_struct=1; got_end=0; n=0 }
    in_struct { n++ }
    in_struct && /^end$/ { got_end=1 }
    in_struct && !/^end$/ && /^(def |pub def |enum |struct |const )/ && n > 1 {
      printf "%s: struct %s lacks a terminating end before %s\n", FILENAME, name, $0
      in_struct=0
    }
    in_struct && got_end { in_struct=0 }
  ' "$f"
done | while IFS= read -r line; do
  echo "FAIL: $line"
  failures=$((failures + 1))
done
if [ "$failures" -ne 0 ]; then
  exit 1
fi
echo "struct integrity OK"
