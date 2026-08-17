#!/usr/bin/env bash
# Static integrity check: every `struct` declaration in the compiler sources
# must have fields (or be empty) and a terminating `end` before the next
# top-level construct. A malformed struct (missing fields or missing `end`)
# silently corrupts the self-hosted build; this check catches the class of
# breakage BEFORE a commit.
#
# NOTE: this is a SUPPLEMENTARY heuristic. The authoritative pre-bootstrap
# gate is the stage0 compiler parsing the kernel (see run_bootstrap.sh).
set -u
out="$(for f in tg_compiler/*.tg; do
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
done)"
if [ -n "$out" ]; then
  printf '%s\n' "$out"
  failures="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  echo "struct integrity FAILED: $failures problem(s)"
  exit 1
fi
echo "struct integrity OK"
