#!/bin/sh
# Verify the installed OCaml/Dune toolchain against bootstrap/ocaml-toolchain.lock.
set -u
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT_DIR/bootstrap/ocaml-toolchain.lock"

lock_ver() { awk -F' = ' -v k="$1" '$1 == k { gsub(/"/, "", $2); print $2 }' "$LOCK"; }
want_ocaml="$(lock_ver ocaml)"
want_dune="$(lock_ver dune)"
want_arch="$(lock_ver arch)"

have_ocaml="$(ocamlopt -version 2>/dev/null | head -1)"
have_dune="$(dune --version 2>/dev/null | head -1)"
have_arch="$(uname -m 2>/dev/null || true)"
case "$have_arch" in
  arm64|aarch64) have_arch="arm64" ;;
  x86_64|amd64) have_arch="x86_64" ;;
esac

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
if [ -n "$want_arch" ] && [ -n "$have_arch" ] && [ "$have_arch" != "$want_arch" ]; then
  echo "error: host architecture $have_arch, locked architecture is $want_arch" >&2
  fail=1
fi
if [ "$fail" -eq 0 ]; then
  echo "toolchain ok: OCaml $have_ocaml, dune $have_dune, arch $have_arch"
fi
exit "$fail"
