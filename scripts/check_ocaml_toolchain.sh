#!/bin/sh
# Verify the installed OCaml/Dune toolchain against bootstrap/ocaml-toolchain.lock.
set -u
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT_DIR/bootstrap/ocaml-toolchain.lock"

lock_ver() { awk -F' = ' -v k="$1" '$1 == k { gsub(/"/, "", $2); print $2 }' "$LOCK"; }
want_ocaml="$(lock_ver ocaml)"
want_dune="$(lock_ver dune)"

have_ocaml="$(ocamlopt -version 2>/dev/null | head -1)"
have_dune="$(dune --version 2>/dev/null | head -1)"

fail=0
[ -n "$have_ocaml" ] || { echo "error: ocamlopt unavailable" >&2; fail=1; }
[ -n "$have_dune" ] || { echo "error: dune unavailable" >&2; fail=1; }
if [ -n "$have_ocaml" ] && [ "$have_ocaml" != "$want_ocaml" ]; then
  echo "error: OCaml $have_ocaml installed, locked version is $want_ocaml" >&2
  fail=1
fi
if [ -n "$have_dune" ] && [ "$have_dune" != "$want_dune" ]; then
  echo "error: dune $have_dune installed, locked version is $want_dune" >&2
  fail=1
fi
if [ "$fail" -eq 0 ]; then
  echo "toolchain ok: OCaml $have_ocaml, dune $have_dune"
fi
exit "$fail"
