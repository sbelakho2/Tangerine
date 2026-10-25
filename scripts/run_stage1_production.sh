#!/usr/bin/env bash
# Produce/validate the kernel Stage1 artifact directly from the OCaml seed.
# No seed-VM self-host preflight: Stage1 production compiles the closure once.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/bootstrap_helpers.sh"
TARGET="$(bh_boot_target)"
STAGE1="$ROOT/build/tg_stage1"
SEED="$ROOT/stage0_ocaml/_build/default/bin/tg_stage0.exe"
mkdir -p "$ROOT/build"

if bh_stage1_provenance_ok "$STAGE1" "$TARGET"; then
  echo "stage1 production: resume accepted (provenance matches)"
  exit 0
fi

bh_export_stage1_vm_limits
echo "stage1 production: steps=$TANGERINE_BOOTSTRAP_VM_MAX_STEPS host_calls=$TANGERINE_BOOTSTRAP_VM_MAX_HOST_CALLS rss_mb=$TANGERINE_BOOTSTRAP_VM_MAX_RSS_MB alloc=$TANGERINE_BOOTSTRAP_VM_MAX_ALLOC OCAMLRUNPARAM=$OCAMLRUNPARAM"
# Deliberate live phase trace: the MIR markers are only useful if the flag
# and log exist before the seed's kernel VM starts.
touch "$ROOT/build/phase_trace.flag"
: > "$ROOT/build/kernel_phase.log"
rm -f "$STAGE1"

# Host-memory-pressure guard: RSS-only limits did not catch a process whose
# cold heap had been evicted to swap (RSS stayed ~3GB while swap hit ~35GB).
# Abort only on sustained high swap AND collapsed CPU, never on one sample.
memory_watchdog() {
  local runner_pid="$1" low=0 used total pct pid cpu
  while kill -0 "$runner_pid" 2>/dev/null; do
    read -r used total < <(sysctl -n vm.swapusage | awk -F'[ =M]+' '{print $4, $2}')
    pct=0
    if [ "${total:-0}" != "0" ] && [ -n "${used:-}" ]; then
      pct=$(awk -v u="$used" -v t="$total" 'BEGIN { printf "%d", (u*100)/t }')
    fi
    pid="$(pgrep -f 'tg_stage0.exe compile --repo-root' | head -1)"
    cpu="$(ps -p "${pid:-0}" -o %cpu= 2>/dev/null | tr -d ' ')"
    cpu="${cpu:-0}"
    if [ "$pct" -ge 90 ] && awk -v c="$cpu" 'BEGIN { exit !(c < 10) }'; then
      low=$((low + 1))
    else
      low=0
    fi
    if [ "$low" -ge 3 ]; then
      echo "stage1 production: ABORT host memory pressure (swap=${used}/${total}MB cpu=${cpu}%)" >&2
      [ -n "$pid" ] && kill "$pid" 2>/dev/null
      return 42
    fi
    sleep 30
  done
}
memory_watchdog $$ &
watchdog_pid=$!
trap 'kill "$watchdog_pid" 2>/dev/null || true' EXIT
bh_ocaml_seed_compile "$SEED" "$ROOT" "$TARGET" "$STAGE1" 2>&1 | tee "$ROOT/build/stage1_production.log"
rc=${PIPESTATUS[0]}
if [ "$rc" -ne 0 ] || [ ! -x "$STAGE1" ]; then
  echo "stage1 production: FAIL rc=$rc artifact=$([ -x "$STAGE1" ] && echo present || echo missing)" >&2
  exit "${rc:-1}"
fi
bh_write_stage1_provenance "$STAGE1" "$TARGET"
if ! validate_stage tg_stage1 "$STAGE1"; then
  echo "stage1 production: validation FAILED" >&2
  exit 1
fi
echo "stage1 production: PASS ($STAGE1)"
