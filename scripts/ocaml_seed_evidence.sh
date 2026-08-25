#!/usr/bin/env bash
#
# scripts/ocaml_seed_evidence.sh — record deterministic per-phase pipeline
# evidence for the OCaml bootstrap seed (stage0_ocaml).
#
# WHAT THIS RECORDS
#   The OCaml seed runs its bootstrap pipeline in phases, and
#   stage0_ocaml/selfcheck/tg_evidence.exe replays those phases with the
#   same functions the driver uses (Bootstrap_manifest.load ->
#   fingerprint -> Module_graph.create_with_sources -> Resolver.resolve ->
#   typecheck fixpoint -> lowering -> mono) and emits one
#   `evidence <phase> ...` line per phase, in fixed order:
#
#     manifest  SHA-256 fingerprint over the canonical manifest sequence
#               (manifest content, version, and per-entry logical module
#               path / relative source path / source byte length / source
#               SHA-256) — the same fingerprint the driver prints and
#               tg_fingerprint checks
#     graph     module graph node/item counts
#     resolver  manifest closure entries + resolver definition counts
#               (defs = expr+type+field+variant; calls = call candidates)
#     typecheck total typecheck errors and fixpoint rounds (registration is
#               non-fatal; modules retry against the growing env)
#     mono      lowered-template / specialized-instance counts (skipped=1
#               while the typecheck gate fails; lowering is not attempted)
#     gates     frontend/structural/mono gate verdicts (FAIL/SKIPPED/PASS)
#     run       unix-epoch seconds — the ONLY line that varies across runs
#
#   The evidence lines are byte-identical across runs except the run= line,
#   and tg_evidence.exe exits 0 even when gates fail: evidence is recorded,
#   not gated.
#
# HOW THIS WILL BE USED (Swift -> OCaml migration comparison)
#   The audit's migration plan compares the Swift seed (stage1-S) pipeline
#   against the OCaml seed (stage1-O) phase by phase.  Both seeds consume
#   the same bootstrap/compiler_kernel.manifest closure, so the phase
#   fingerprints MUST MATCH between seeds for equivalent phases: the
#   manifest fingerprint line must agree (same canonical sequence over the
#   same closure), and the graph/resolver/typecheck/mono counts are the
#   behavioral comparators.  Each run is archived under
#   bootstrap/evidence/ocaml/ so consecutive runs can be diffed (proving
#   determinism: all non-run lines identical) and later diffed against the
#   Swift seed's evidence archive for the same manifest state.
#
# USAGE
#   scripts/ocaml_seed_evidence.sh
#
# Behavior: (a) verifies the locked OCaml/Dune toolchain via
# scripts/check_ocaml_toolchain.sh; (b) builds the seed with `dune build`;
# (c) runs stage0_ocaml/_build/default/selfcheck/tg_evidence.exe with the
# repo root; (d) appends the evidence lines minus the run= line to a
# timestamped file bootstrap/evidence/ocaml/<YYYY-MM-DDTHHMMSS>.evidence
# (the content is deterministic, so a same-second re-run leaves the
# existing file untouched — the script is idempotent and safe to re-run);
# (e) prints the full evidence record (including the run= line) to stdout.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# (a) Toolchain check: fail fast when the locked OCaml/Dune versions
# (bootstrap/ocaml-toolchain.lock) are not installed.
"$ROOT_DIR/scripts/check_ocaml_toolchain.sh"

# (b) Build the seed. The tree treats warnings as errors, so a clean
# build here is also the compile gate for tg_evidence.exe.
(cd "$ROOT_DIR/stage0_ocaml" && dune build)

# (c) Run the evidence executable against the repo root. set -e aborts on
# a nonzero exit, so a pipeline hard failure never records evidence.
EVIDENCE_EXE="$ROOT_DIR/stage0_ocaml/_build/default/selfcheck/tg_evidence.exe"
EVIDENCE_OUT="$( "$EVIDENCE_EXE" "$ROOT_DIR" )"

# (d) Archive the evidence without the run= line (the only
# non-deterministic line) in a timestamped per-run file.
STAMP="$(date +%Y-%m-%dT%H%M%S)"
EVIDENCE_DIR="$ROOT_DIR/bootstrap/evidence/ocaml"
EVIDENCE_FILE="$EVIDENCE_DIR/$STAMP.evidence"
mkdir -p "$EVIDENCE_DIR"
if [ ! -f "$EVIDENCE_FILE" ]; then
  printf '%s\n' "$EVIDENCE_OUT" | grep -v '^evidence run=' > "$EVIDENCE_FILE"
fi

# (e) Print the full evidence record (with the run= line) to stdout.
printf '%s\n' "$EVIDENCE_OUT"
