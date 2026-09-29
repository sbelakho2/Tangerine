#!/usr/bin/env bash
# prebootstrap_quick.sh — the seconds-scale PRE-BOOTSTRAP decision ladder
# (audit P1-11).
#
# check_ocaml_seed_health.sh is a broad development-health suite with
# individual lanes capped at 900-4200 s; it is NOT the right thing to run
# every time the question is "should I pay for the bootstrap now?".
# This script runs only the tests with the highest blocker-detection per
# second, fail-closed and with exact evidences:
#
#   TIER 0 (sub-second, no build):
#     - worktree cleanliness (a bootstrap candidate is a clean tree)
#     - shell syntax for run_bootstrap.sh + scripts/*.sh
#     - repository artifact hygiene (no tracked native artifact)
#     - kernel struct integrity
#     - accepted-debt policy regression lane
#     - degraded escape-valve rejection (prebootstrap_env_gate)
#     - selfcheck-sentinel verifier meta-test
#     - static invariants: no root gate artifact; no module_type_names
#       remove/clear without an index-maintenance change; ResolvedNames
#       construction centralized; no conflict markers
#     - manifest structure: exact 45 records (14 std + 31 compiler), no
#       duplicates, bootstrap_main exactly once, every file present,
#       readable and non-symlink, no path escapes
#
#   TIER 1 (seconds-to-minutes, warm build):
#     - dune build
#     - the EXACT unit-test inventory (230 passed, 0 failed)
#     - the cheap blocker selfchecks, each required to exit 0 AND print
#       EXACTLY ONE sentinel (TANGERINE_SELFCHECK_PASS name=... version=1):
#       tg_bootstrap_accepted, tg_manifest, tg_subset, tg_verify,
#       tg_vmsem, tg_sigid, tg_placechain, tg_boxnominal, tg_type_props
#
#   --with-medium (adds the 10-minute-class lanes):
#     tg_parse_parity, tg_resolution_parity, the self-host grammar gate;
#     and when the typecheck debt is zero, the full closure gate.
#
#   --final (the pre-bootstrap authorization run):
#     requires zero typecheck debt, runs check_ocaml_bootstrap_complete.sh
#     (full closure + canonical resolution parity + the kernel-in-VM
#     self-host preflight) — the last test before the real bootstrap.
#
# Usage: scripts/prebootstrap_quick.sh [--with-medium|--final] [--allow-dirty]
# Exit: 0 every selected test passed, 1 any failure.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="quick"
ALLOW_DIRTY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --with-medium) MODE="medium" ;;
    --final) MODE="final" ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    -h | --help)
      sed -n '2,45p' "$0"
      exit 0
      ;;
    *)
      echo "prebootstrap_quick: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

FAILURES=0
CHECKS=0
fail() {
  echo "PREBOOTSTRAP-QUICK: FAIL — $*" >&2
  FAILURES=$((FAILURES + 1))
}
step() { printf '\n== %s\n' "$*"; }
run_check() { # run_check <label> <command...>
  local label="$1"
  shift
  CHECKS=$((CHECKS + 1))
  if "$@"; then
    echo "  PASS: ${label}"
  else
    fail "${label}"
  fi
}

readonly FAST_SELFCHECKS=(
  tg_bootstrap_accepted
  tg_manifest
  tg_subset
  tg_verify
  tg_vmsem
  tg_sigid
  tg_placechain
  tg_boxnominal
  tg_type_props
)

# ── TIER 0 ────────────────────────────────────────────────────────────
step "TIER 0 — static invariants, hygiene, manifest structure"

if [ "$ALLOW_DIRTY" = "1" ]; then
  echo "  note: worktree cleanliness skipped (--allow-dirty)"
else
  run_check "worktree clean (bootstrap candidate)" test -z "$(git status --porcelain=v1)"
fi

for f in run_bootstrap.sh scripts/*.sh; do
  CHECKS=$((CHECKS + 1))
  if bash -n "$f" 2>/dev/null; then
    :
  else
    fail "shell syntax: $f"
  fi
done
if [ "$FAILURES" -eq 0 ]; then echo "  PASS: shell syntax (run_bootstrap.sh + scripts/*.sh)"; fi

run_check "repository artifact hygiene" scripts/check_repo_artifact_hygiene.sh
run_check "kernel struct integrity" scripts/check_struct_integrity.sh
run_check "accepted-debt policy regression lane" scripts/test_ocaml_seed_debt_policy.sh
run_check "degraded escape-valve rejection" scripts/prebootstrap_env_gate.sh
run_check "selfcheck-sentinel verifier meta-test" scripts/test_selfcheck_sentinel.sh

# static invariants (each is a one-line grep/stat; sub-second)
CHECKS=$((CHECKS + 1))
if [ -e bootstrap_gate.out ]; then
  fail "root gate artifact exists (bootstrap_gate.out) — build/ is the only output location"
else
  echo "  PASS: no root gate artifact"
fi
CHECKS=$((CHECKS + 1))
if git grep -q -n 'module_type_names\.\(remove\|clear\)' -- tg_compiler; then
  fail "module_type_names removal/clear without index maintenance (the suffix index must be rebuilt in lockstep)"
else
  echo "  PASS: no unmaintained suffix-index map mutation"
fi
CHECKS=$((CHECKS + 1))
rn_literals="$(git grep -n 'ResolvedNames {' -- tg_compiler | sed 's/^[^:]*:[0-9]*://' | grep -vc '^[[:space:]]*#' || true)"
if [ "${rn_literals:-0}" -le 1 ]; then
  echo "  PASS: ResolvedNames construction centralized (${rn_literals} literal(s) outside comments)"
else
  fail "ResolvedNames has ${rn_literals} scattered literals; route them through resolved_names_empty()/Clone"
fi
CHECKS=$((CHECKS + 1))
if git grep -qE '^(<<<<<<<|=======|>>>>>>>)' -- std tg_compiler stage0_ocaml; then
  fail "conflict markers present in std/tg_compiler/stage0_ocaml"
else
  echo "  PASS: no conflict markers"
fi

# manifest structure: exact composition, no duplicates, files present
CHECKS=$((CHECKS + 1))
manifest_check() {
  local manifest="bootstrap/compiler_kernel.manifest"
  [ -f "$manifest" ] || {
    echo "  manifest missing: $manifest"
    return 1
  }
  local entries std_n compiler_n total
  entries="$(grep -E '^(std|compiler):' "$manifest")"
  std_n="$(printf '%s\n' "$entries" | grep -c '^std:' || true)"
  compiler_n="$(printf '%s\n' "$entries" | grep -c '^compiler:' || true)"
  total="$((std_n + compiler_n))"
  [ "$total" -eq 45 ] || {
    echo "  manifest records: ${total} (expected exactly 45 = 14 std + 31 compiler)"
    return 1
  }
  [ "$std_n" -eq 14 ] || {
    echo "  std records: ${std_n} (expected exactly 14)"
    return 1
  }
  [ "$compiler_n" -eq 31 ] || {
    echo "  compiler records: ${compiler_n} (expected exactly 31)"
    return 1
  }
  local dupes
  dupes="$(printf '%s\n' "$entries" | awk '{print $2}' | sort | uniq -d)"
  [ -z "$dupes" ] || {
    echo "  duplicate manifest paths: ${dupes}"
    return 1
  }
  [ "$(printf '%s\n' "$entries" | grep -c 'bootstrap_main\.tg$')" -eq 1 ] || {
    echo "  bootstrap_main.tg must appear exactly once"
    return 1
  }
  local line kind rel path
  while IFS= read -r line; do
    case "$line" in '' | '#'*) continue ;; esac
    kind="${line%% *}"
    rel="${line#* }"
    case "$kind" in
      std:) path="std/${rel}" ;;
      compiler:) path="tg_compiler/${rel}" ;;
      *)
        echo "  unknown manifest kind: ${line}"
        return 1
        ;;
    esac
    case "$path" in
      *..* | /*)
        echo "  manifest path escape: ${path}"
        return 1
        ;;
    esac
    if [ -L "$path" ]; then
      echo "  manifest entry is a symlink: ${path}"
      return 1
    fi
    if [ ! -f "$path" ] || [ ! -r "$path" ]; then
      echo "  manifest entry missing/unreadable: ${path}"
      return 1
    fi
  done <<<"$entries"
  return 0
}
if manifest_check; then
  echo "  PASS: manifest structure (45 records = 14 std + 31 compiler, no duplicates, all readable)"
else
  fail "manifest structure"
fi

# ── TIER 1 ────────────────────────────────────────────────────────────
step "TIER 1 — build + unit inventory + cheap selfchecks"

if [ -x scripts/check_ocaml_toolchain.sh ]; then
  run_check "pinned OCaml/Dune toolchain" scripts/check_ocaml_toolchain.sh
fi

if [ "$FAILURES" -eq 0 ]; then
  CHECKS=$((CHECKS + 1))
  if (cd stage0_ocaml && dune build); then
    echo "  PASS: dune build"
  else
    fail "dune build"
  fi
fi

if [ "$FAILURES" -eq 0 ]; then
  CHECKS=$((CHECKS + 1))
  if (cd stage0_ocaml && timeout 300 "_build/default/test/test_main.exe") >/tmp/prebootstrap_quick_test_main.out 2>&1; then
    if grep -q '230 passed, 0 failed' /tmp/prebootstrap_quick_test_main.out; then
      echo "  PASS: unit inventory (230 passed, 0 failed)"
    else
      fail "unit inventory is not the exact 230 passed, 0 failed (see /tmp/prebootstrap_quick_test_main.out)"
    fi
  else
    fail "unit suite exited non-zero (see /tmp/prebootstrap_quick_test_main.out)"
  fi
fi

for name in "${FAST_SELFCHECKS[@]}"; do
  [ "$FAILURES" -eq 0 ] || break
  CHECKS=$((CHECKS + 1))
  out="/tmp/prebootstrap_quick_${name}.out"
  if ! (cd stage0_ocaml && timeout 420 "_build/default/selfcheck/${name}.exe") >"$out" 2>&1; then
    fail "selfcheck ${name} exited non-zero (see ${out})"
  elif ! scripts/check_selfcheck_sentinel.sh "$name" "$out"; then
    fail "selfcheck ${name} exited 0 without its exact sentinel (see ${out})"
  else
    echo "  PASS: selfcheck ${name} (exit 0 + sentinel)"
  fi
done

# ── MEDIUM / FINAL ────────────────────────────────────────────────────
if [ "$MODE" = "medium" ] || [ "$MODE" = "final" ]; then
  step "MEDIUM — parity lanes + grammar gate"
  for name in tg_parse_parity tg_resolution_parity; do
    [ "$FAILURES" -eq 0 ] || break
    CHECKS=$((CHECKS + 1))
    out="/tmp/prebootstrap_quick_${name}.out"
    if ! (cd stage0_ocaml && timeout 2400 "_build/default/selfcheck/${name}.exe" ..) >"$out" 2>&1; then
      fail "selfcheck ${name} exited non-zero (see ${out})"
    elif ! scripts/check_selfcheck_sentinel.sh "$name" "$out"; then
      fail "selfcheck ${name} exited 0 without its exact sentinel (see ${out})"
    else
      echo "  PASS: selfcheck ${name} (exit 0 + sentinel)"
    fi
  done
  [ "$FAILURES" -eq 0 ] &&
    run_check "self-host grammar gate (no parity skip)" scripts/run_selfhost_grammar_gate.sh
fi

if [ "$MODE" = "final" ]; then
  step "FINAL — pre-bootstrap authorization (full closure + self-host preflight)"
  # The closure gate is the authority: it reports NOT YET (exit 1) while
  # any typecheck debt remains, and at zero debt it must produce the
  # full-closure PASS *and* the kernel-in-VM self-host preflight PASS.
  [ "$FAILURES" -eq 0 ] &&
    run_check "full closure + canonical parity + self-host preflight" scripts/check_ocaml_bootstrap_complete.sh
fi


# ── verdict ───────────────────────────────────────────────────────────
step "VERDICT"
if [ "$FAILURES" -ne 0 ]; then
  echo "PREBOOTSTRAP QUICK: FAIL — ${FAILURES} failing check(s) (${CHECKS} selected)"
  echo "DO NOT START A BOOTSTRAP on this tree."
  exit 1
fi
case "$MODE" in
  quick) echo "PREBOOTSTRAP QUICK: PASS — ${CHECKS} check(s); seconds-scale ladder green" ;;
  medium) echo "PREBOOTSTRAP MEDIUM: PASS — ${CHECKS} check(s); parity lanes green" ;;
  final) echo "PREBOOTSTRAP FINAL: PASS — ${CHECKS} check(s); pre-bootstrap authorization evidence complete" ;;
esac
exit 0
