#!/usr/bin/env python3
"""repin_bootstrap_limits.py -- measured cold+warm budget repinner.

Measurement-only tool (plan steps 13+14).  Consumes TWO KEY=VALUE metric
blocks produced by scripts/profile_record_metrics.sh from the SAME tree
(cold and warm), validates them, and proposes pinned bootstrap budgets
with the plan's margins:

    steps_limit    = ceil(max(cold_steps, warm_steps) * 1.15)
    host_calls     = ceil(max(cold_host_calls, warm_host_calls) * 1.15)
    alloc_bytes    = ceil(max(cold_alloc_bytes, warm_alloc_bytes) * 1.15)
    rss_mib        = max(peak_rss) + |cold_peak_rss - warm_peak_rss|
                     + max(1024, ceil(10% * max(peak_rss)))
    wall_timeout_s = ceil(max(phase_sum_wall) * 1.5 / 60) * 60
                     (only when BOTH logs carry WALL_PHASE_SUM_S; otherwise
                     the existing outer timeout is left unchanged with a note)

CALIBRATION EVIDENCE (unconditional, dry-run AND --apply): a metric
block is calibration material only when BOTH runs report
STATUS=COMPLETED, RUN_OUTCOME=PASS, SELFCHECK_RESULT=PASS, RUN_EXIT=0,
FAILURE_FINGERPRINT=NONE and RUN_TREE_CLEAN=1, and when every identity
field (RUN_SHA, RUN_TARGET, CLOSURE_FINGERPRINT, RUN_GC_POLICY,
SEED_SHA256, MANIFEST_SHA256) is present (non-UNKNOWN) and EQUAL across
the pair.  UNKNOWN/missing/mismatch is a HARD failure — there is no
warning fallback (an earlier revision accepted STATUS=COMPLETED plus
RUN_OUTCOME=FAIL, i.e. a failed compiler run, as calibration material).

Proposals map the block kind (LOG_KIND):
  standalone  FINAL_STEPS/HOST_CALLS/ALLOC_BYTES/PEAK_RSS_MIB and
              WALL_PHASE_SUM_S of the single preflight VM (VM B).
  aggregate   max over the relevant VM A + VM B measurements
              (VM_*_FINAL_STEPS / VM_*_HOST_CALLS / VM_*_ALLOC_BYTES /
              VM_*_PEAK_RSS_MIB) and AGGREGATE_WALL_S for GATE_TIMEOUT_S;
              when an aggregate field is absent the standalone field of
              the same metric is used with an explicit note.

The dry run is the default: it prints the proposal table and a unified
diff of the pinned constants.  --apply rewrites ONLY those constants in
the gate script (scripts/check_ocaml_bootstrap_complete.sh by default;
--gate-script overrides the path for testing).  The driver's DEFAULT
constants (stage0_ocaml/src/driver.ml env_budget lines) are updated only
with --driver-defaults (off by default; --driver-path overrides the path
for testing).

Usage:
    scripts/repin_bootstrap_limits.py [--apply] [--driver-defaults]
        [--gate-script PATH] [--driver-path PATH]
        [--sha SHA] [--target TRIPLE]
        COLD_METRICS WARM_METRICS
"""

from __future__ import annotations

import difflib
import math
import os
import re
import stat
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_GATE = REPO_ROOT / "scripts" / "check_ocaml_bootstrap_complete.sh"
DEFAULT_DRIVER = REPO_ROOT / "stage0_ocaml" / "src" / "driver.ml"

GATE_PINS = {
    "steps": r"^(export TANGERINE_BOOTSTRAP_VM_MAX_STEPS=)(\d+)$",
    "host_calls": r"^(export TANGERINE_BOOTSTRAP_VM_MAX_HOST_CALLS=)(\d+)$",
    "alloc_bytes": r"^(export TANGERINE_BOOTSTRAP_VM_MAX_ALLOC=)(\d+)$",
    "rss_mib": r"^(export TANGERINE_BOOTSTRAP_VM_MAX_RSS_MB=)(\d+)$",
    "wall_timeout_s": r"^(GATE_TIMEOUT_S=)(\d+)$",
}

DRIVER_PINS = {
    "steps": r'(env_budget "TANGERINE_BOOTSTRAP_VM_MAX_STEPS" )(\d[\d_]*)()',
    "host_calls": r'(env_budget "TANGERINE_BOOTSTRAP_VM_MAX_HOST_CALLS" )(\d[\d_]*)()',
    "alloc_bytes": r'(env_budget "TANGERINE_BOOTSTRAP_VM_MAX_ALLOC" )(\d[\d_]*)()',
    "rss_mib": r'(env_budget "TANGERINE_BOOTSTRAP_VM_MAX_RSS_MB" )(\d[\d_]*)( \* 1024 \* 1024)',
}

# Identity fields that must be present and equal across the cold+warm pair.
IDENTITY_EQUAL_FIELDS = (
    "RUN_SHA",
    "RUN_TARGET",
    "CLOSURE_FINGERPRINT",
    "RUN_GC_POLICY",
    "SEED_SHA256",
    "MANIFEST_SHA256",
)

UNKNOWN_TOKENS = ("", "UNKNOWN", "none", "NONE")


def usage(msg: str | None = None) -> "NoReturn":  # noqa: F821
    if msg:
        print(f"repin_bootstrap_limits: {msg}", file=sys.stderr)
    print(
        "usage: scripts/repin_bootstrap_limits.py [--apply] [--driver-defaults]\n"
        "           [--gate-script PATH] [--driver-path PATH] [--sha SHA]\n"
        "           [--target TRIPLE] COLD_METRICS WARM_METRICS",
        file=sys.stderr,
    )
    sys.exit(2)


def parse_args(argv: list[str]) -> dict:
    opts = {
        "apply": False,
        "driver_defaults": False,
        "gate_script": DEFAULT_GATE,
        "driver_path": DEFAULT_DRIVER,
        "sha": None,
        "target": None,
    }
    positional: list[str] = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--apply":
            opts["apply"] = True
        elif a == "--driver-defaults":
            opts["driver_defaults"] = True
        elif a in ("--gate-script", "--driver-path", "--sha", "--target"):
            if i + 1 >= len(argv):
                usage(f"{a} needs a value")
            key = {
                "--gate-script": "gate_script",
                "--driver-path": "driver_path",
                "--sha": "sha",
                "--target": "target",
            }[a]
            opts[key] = argv[i + 1]
            i += 1
        elif a in ("-h", "--help"):
            usage()
        elif a.startswith("--"):
            usage(f"unknown option {a}")
        else:
            positional.append(a)
        i += 1
    if len(positional) != 2:
        usage("exactly two metric files are required (cold then warm)")
    opts["cold"] = Path(positional[0])
    opts["warm"] = Path(positional[1])
    return opts


def read_metrics(path: Path) -> dict[str, str]:
    if not path.is_file():
        print(f"repin_bootstrap_limits: no such metric file: {path}", file=sys.stderr)
        sys.exit(2)
    out: dict[str, str] = {}
    with path.open("r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or "=" not in line:
                continue
            key, _, val = line.partition("=")
            out[key.strip()] = val.strip()
    return out


def as_int(metrics: dict[str, str], key: str) -> int | None:
    raw = metrics.get(key, "UNKNOWN")
    if raw in ("", "UNKNOWN", "none"):
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def as_float(metrics: dict[str, str], key: str) -> float | None:
    raw = metrics.get(key, "UNKNOWN")
    if raw in ("", "UNKNOWN", "none"):
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def ceil15(x: int) -> int:
    """ceil(x * 1.15), exact integer arithmetic (x * 115 / 100)."""
    return (x * 115 + 99) // 100


def ceil10pct(x: int) -> int:
    """ceil(x * 10%), exact integer arithmetic."""
    return (x + 9) // 10


def validate(cold: dict[str, str], warm: dict[str, str], opts: dict) -> list[str]:
    """Unconditional strict validation: exits 2 on ANY bad evidence.

    Both blocks must prove a completed, PASSING, clean-tree run with a
    zero exit code and no failure fingerprint, and every identity field
    must be present and equal.  There is deliberately NO warning fallback
    (a COMPLETED run whose compiler outcome FAILED is not calibration
    material).  Returns an empty warning list for callers that print it.
    """
    errors: list[str] = []
    runs = (("cold", cold), ("warm", warm))

    for name, m in runs:
        status = m.get("STATUS", "UNKNOWN")
        if status != "COMPLETED":
            errors.append(f"{name} block STATUS={status}, want COMPLETED")
        outcome = m.get("RUN_OUTCOME", "UNKNOWN")
        if outcome != "PASS":
            errors.append(f"{name} block RUN_OUTCOME={outcome}, want PASS")
        selfcheck = m.get("SELFCHECK_RESULT", "UNKNOWN")
        if selfcheck != "PASS":
            errors.append(f"{name} block SELFCHECK_RESULT={selfcheck}, want PASS")
        run_exit = m.get("RUN_EXIT", "UNKNOWN")
        if not re.fullmatch(r"\d+", run_exit) or int(run_exit) != 0:
            errors.append(f"{name} block RUN_EXIT={run_exit}, want exactly 0")
        ff = m.get("FAILURE_FINGERPRINT", "")
        if not ff:
            legacy = m.get("FIRST_FAILURE_FINGERPRINT", "")
            ff = "NONE" if legacy == "none" else legacy
        if ff != "NONE":
            errors.append(f"{name} block FAILURE_FINGERPRINT={ff or 'missing'}, want NONE")
        tree_clean = m.get("RUN_TREE_CLEAN", "UNKNOWN")
        if tree_clean != "1":
            errors.append(
                f"{name} block RUN_TREE_CLEAN={tree_clean}, want 1 (a dirty tree"
                " is not calibration material)"
            )
        kind = m.get("LOG_KIND", "UNKNOWN")
        if kind not in ("standalone", "aggregate"):
            errors.append(f"{name} block LOG_KIND={kind}, want standalone|aggregate")
        for key in IDENTITY_EQUAL_FIELDS:
            val = m.get(key, "UNKNOWN")
            if val in UNKNOWN_TOKENS:
                errors.append(f"{name} block {key}={val or 'missing'}, want a known value")

    # Cross-run equality (every field is present above, so this is exact).
    for key in IDENTITY_EQUAL_FIELDS:
        values = {cold.get(key, "UNKNOWN"), warm.get(key, "UNKNOWN")}
        if len(values) > 1:
            errors.append(f"{key} mismatch between cold and warm: {sorted(values)}")
    if cold.get("LOG_KIND") != warm.get("LOG_KIND"):
        errors.append(
            f"LOG_KIND mismatch: cold={cold.get('LOG_KIND')} warm={warm.get('LOG_KIND')}"
        )

    # Optional CLI cross-checks stay (they can only tighten the gate).
    if opts["sha"]:
        if opts["sha"] not in (cold.get("RUN_SHA"), warm.get("RUN_SHA")):
            errors.append(f"--sha {opts['sha']} does not match the measured RUN_SHA")
    if opts["target"]:
        if opts["target"] not in (cold.get("RUN_TARGET"), warm.get("RUN_TARGET")):
            errors.append(f"--target {opts['target']} does not match the measured RUN_TARGET")

    if errors:
        for e in errors:
            print(f"repin_bootstrap_limits: VALIDATION FAIL: {e}", file=sys.stderr)
        sys.exit(2)
    return []


def collect_ints(metrics: tuple[dict[str, str], ...], keys: tuple[str, ...]) -> list[int]:
    """Non-UNKNOWN positive integers for `keys` across all metric blocks."""
    vals: list[int] = []
    for m in metrics:
        for key in keys:
            v = as_int(m, key)
            if v is not None and v > 0:
                vals.append(v)
    return vals


def collect_floats(
    metrics: tuple[dict[str, str], ...], keys: tuple[str, ...]
) -> list[float]:
    vals: list[float] = []
    for m in metrics:
        for key in keys:
            v = as_float(m, key)
            if v is not None and v > 0:
                vals.append(v)
    return vals


def build_proposals(cold: dict[str, str], warm: dict[str, str]) -> dict:
    proposals: dict[str, int | None] = {}
    formulas: list[str] = []
    notes: list[str] = []
    kind = cold.get("LOG_KIND", "standalone")
    metrics = (cold, warm)

    # ── steps: aggregate prefers max(VM A, VM B) across cold+warm ─────
    vm_steps = (
        collect_ints(metrics, ("VM_A_FINAL_STEPS", "VM_B_FINAL_STEPS"))
        if kind == "aggregate"
        else []
    )
    if vm_steps:
        m = max(vm_steps)
        proposals["steps"] = ceil15(m)
        formulas.append(
            "steps_limit    = ceil(max(VM_A/VM_B FINAL_STEPS over cold+warm) * 1.15)"
            f" = ceil({m} * 1.15) = {proposals['steps']}"
        )
    else:
        if kind == "aggregate":
            notes.append(
                "aggregate per-VM step counters absent; falling back to the"
                " standalone FINAL_STEPS summary fields"
            )
        steps_c = as_int(cold, "FINAL_STEPS")
        steps_w = as_int(warm, "FINAL_STEPS")
        if steps_c is None or steps_w is None:
            proposals["steps"] = None
            formulas.append(
                "steps_limit    = SKIPPED: FINAL_STEPS UNKNOWN in "
                + ("cold " if steps_c is None else "")
                + ("warm" if steps_w is None else "")
            )
        else:
            m = max(steps_c, steps_w)
            proposals["steps"] = ceil15(m)
            formulas.append(
                f"steps_limit    = ceil(max({steps_c}, {steps_w}) * 1.15)"
                f" = ceil({m * 1.15:.1f}) = {proposals['steps']}"
            )

    # ── host calls ───────────────────────────────────────────────────
    vm_host = (
        collect_ints(metrics, ("VM_A_HOST_CALLS", "VM_B_HOST_CALLS"))
        if kind == "aggregate"
        else []
    )
    if vm_host:
        m = max(vm_host)
        proposals["host_calls"] = ceil15(m)
        formulas.append(
            "host_calls     = ceil(max(VM_A/VM_B HOST_CALLS over cold+warm) * 1.15)"
            f" = ceil({m} * 1.15) = {proposals['host_calls']}"
        )
    else:
        if kind == "aggregate":
            notes.append(
                "aggregate per-VM host-call counters absent; falling back to"
                " the standalone HOST_CALLS summary fields"
            )
        host_c = as_int(cold, "HOST_CALLS")
        host_w = as_int(warm, "HOST_CALLS")
        if host_c is None or host_w is None:
            proposals["host_calls"] = None
            formulas.append("host_calls     = SKIPPED: HOST_CALLS UNKNOWN")
        else:
            m = max(host_c, host_w)
            proposals["host_calls"] = ceil15(m)
            formulas.append(
                f"host_calls     = ceil(max({host_c}, {host_w}) * 1.15)"
                f" = ceil({m * 1.15:.1f}) = {proposals['host_calls']}"
            )

    # ── allocation ───────────────────────────────────────────────────
    vm_alloc = (
        collect_ints(metrics, ("VM_A_ALLOC_BYTES", "VM_B_ALLOC_BYTES"))
        if kind == "aggregate"
        else []
    )
    if vm_alloc:
        m = max(vm_alloc)
        proposals["alloc_bytes"] = ceil15(m)
        formulas.append(
            "alloc_bytes    = ceil(max(VM_A/VM_B ALLOC_BYTES over cold+warm) * 1.15)"
            f" = ceil({m} * 1.15) = {proposals['alloc_bytes']}"
        )
    else:
        if kind == "aggregate":
            notes.append(
                "aggregate per-VM alloc counters absent; falling back to the"
                " standalone ALLOC_BYTES summary fields"
            )
        alloc_c = as_int(cold, "ALLOC_BYTES")
        alloc_w = as_int(warm, "ALLOC_BYTES")
        if alloc_c is None or alloc_w is None:
            proposals["alloc_bytes"] = None
            formulas.append(
                "alloc_bytes    = SKIPPED: ALLOC_BYTES UNKNOWN (the logs do not"
                " print a byte counter; existing pin left unchanged)"
            )
        else:
            m = max(alloc_c, alloc_w)
            proposals["alloc_bytes"] = ceil15(m)
            formulas.append(
                f"alloc_bytes    = ceil(max({alloc_c}, {alloc_w}) * 1.15)"
                f" = ceil({m * 1.15:.1f}) = {proposals['alloc_bytes']}"
            )

    # ── RSS: aggregate peaks across VM A/VM B; variance = spread ─────
    vm_rss = (
        collect_ints(metrics, ("VM_A_PEAK_RSS_MIB", "VM_B_PEAK_RSS_MIB"))
        if kind == "aggregate"
        else []
    )
    if vm_rss:
        peak = max(vm_rss)
        variance = peak - min(vm_rss)
        margin = max(1024, ceil10pct(peak))
        proposals["rss_mib"] = peak + variance + margin
        formulas.append(
            "rss_mib        = max(VM_A/VM_B peak RSS over cold+warm)"
            f" ({peak}) + spread ({variance}) + max(1024, ceil(10% * {peak})) ({margin})"
            f" = {proposals['rss_mib']}"
        )
    else:
        if kind == "aggregate":
            notes.append(
                "aggregate per-VM RSS peaks absent; falling back to the"
                " standalone PEAK_RSS_MIB fields"
            )
        rss_c = as_int(cold, "PEAK_RSS_MIB")
        rss_w = as_int(warm, "PEAK_RSS_MIB")
        if rss_c is None or rss_w is None:
            proposals["rss_mib"] = None
            formulas.append("rss_mib        = SKIPPED: PEAK_RSS_MIB UNKNOWN")
        else:
            peak = max(rss_c, rss_w)
            variance = abs(rss_c - rss_w)
            margin = max(1024, ceil10pct(peak))
            proposals["rss_mib"] = peak + variance + margin
            formulas.append(
                f"rss_mib        = max({rss_c}, {rss_w}) + |{rss_c} - {rss_w}|"
                f" + max(1024, ceil(10% * {peak}))"
            )
            formulas.append(
                f"               = {peak} + {variance} + {margin}"
                f" = {proposals['rss_mib']}"
            )

    # ── wall timeout: aggregate AGGREGATE_WALL_S, else phase sum ─────
    agg_walls = (
        collect_floats(metrics, ("AGGREGATE_WALL_S",))
        if kind == "aggregate"
        else []
    )
    wall_c = as_float(cold, "WALL_PHASE_SUM_S")
    wall_w = as_float(warm, "WALL_PHASE_SUM_S")
    if kind == "aggregate" and len(agg_walls) == 2:
        m = max(agg_walls)
        proposals["wall_timeout_s"] = int(math.ceil(m * 1.5 / 60.0) * 60)
        formulas.append(
            f"GATE_TIMEOUT_S = ceil(max(AGGREGATE_WALL_S {agg_walls[0]:g},"
            f" {agg_walls[1]:g}) * 1.5 / 60) * 60"
            f" = ceil({m * 1.5 / 60.0:.2f}) * 60 = {proposals['wall_timeout_s']}"
        )
        notes.append(
            "GATE_TIMEOUT_S is derived from the whole-gate wall clock"
            " (AGGREGATE_WALL_S), not from summed per-phase strings"
        )
    elif wall_c is not None and wall_w is not None:
        if kind == "aggregate":
            notes.append(
                "AGGREGATE_WALL_S missing in one/both blocks; falling back to"
                " WALL_PHASE_SUM_S for the wall timeout"
            )
        m = max(wall_c, wall_w)
        proposals["wall_timeout_s"] = int(math.ceil(m * 1.5 / 60.0) * 60)
        formulas.append(
            f"wall_timeout_s = ceil(max({wall_c:g}, {wall_w:g}) * 1.5 / 60) * 60"
            f" = ceil({m * 1.5 / 60.0:.2f}) * 60 = {proposals['wall_timeout_s']}"
        )
    else:
        proposals["wall_timeout_s"] = None
        missing = [
            name
            for name, val in (("cold", wall_c), ("warm", wall_w))
            if val is None
        ]
        formulas.append(
            "wall_timeout_s = SKIPPED: WALL_PHASE_SUM_S missing in "
            + ", ".join(missing)
            + " (existing outer timeout left unchanged)"
        )
    return {"values": proposals, "formulas": formulas, "notes": notes}


def read_current(path: Path, pins: dict[str, str]) -> dict[str, int]:
    text = path.read_text(encoding="utf-8")
    current: dict[str, int] = {}
    for key, pattern in pins.items():
        m = re.search(pattern, text, re.MULTILINE)
        if m:
            current[key] = int(m.group(2).replace("_", ""))
    return current


def apply_pins(
    path: Path,
    pins: dict[str, str],
    proposals: dict[str, int | None],
    underscore_numbers: bool = False,
) -> tuple[str, list[tuple[str, int, int]]]:
    """Rewrites the pinned constants in `text`. Returns (new_text, changes)."""
    text = path.read_text(encoding="utf-8")
    new_text = text
    changes: list[tuple[str, int, int]] = []
    for key, pattern in pins.items():
        want = proposals.get(key)
        if want is None:
            continue
        rx = re.compile(pattern, re.MULTILINE)
        matches = list(rx.finditer(new_text))
        if len(matches) != 1:
            print(
                f"repin_bootstrap_limits: ERROR: {path}: expected exactly one"
                f" pinned constant for {key}, found {len(matches)}",
                file=sys.stderr,
            )
            sys.exit(3)
        m = matches[0]
        old = int(m.group(2).replace("_", ""))
        if old == want:
            continue
        suffix = m.group(3) if m.re.groups >= 3 else ""
        rendered = f"{want:_}" if underscore_numbers else str(want)
        replacement = m.group(1) + rendered + suffix
        new_text = new_text[: m.start()] + replacement + new_text[m.end() :]
        changes.append((key, old, want))
    return new_text, changes


def unified_diff(old_text: str, new_text: str, path: Path) -> str:
    label = str(path)
    diff = difflib.unified_diff(
        old_text.splitlines(keepends=True),
        new_text.splitlines(keepends=True),
        fromfile=label + " (current)",
        tofile=label + " (proposed)",
        n=2,
    )
    return "".join(diff)


def main(argv: list[str]) -> int:
    opts = parse_args(argv)
    cold = read_metrics(opts["cold"])
    warm = read_metrics(opts["warm"])
    warnings = validate(cold, warm, opts)
    plan = build_proposals(cold, warm)
    proposals = plan["values"]

    print("REPIN PROPOSAL -- bootstrap limits (measurement-only, no authorization)")
    for name, m in (("cold", cold), ("warm", warm)):
        print(
            f"  {name}: label={m.get('RUN_LABEL', '?')} kind={m.get('LOG_KIND', '?')}"
            f" status={m.get('STATUS', '?')} outcome={m.get('RUN_OUTCOME', '?')}"
            f" steps={m.get('FINAL_STEPS', '?')} host_calls={m.get('HOST_CALLS', '?')}"
            f" peak_rss_mib={m.get('PEAK_RSS_MIB', '?')}"
            f" alloc_bytes={m.get('ALLOC_BYTES', '?')}"
            f" sha={m.get('RUN_SHA', '?')} target={m.get('RUN_TARGET', '?')}"
        )
        if m.get("LOG_KIND") == "aggregate":
            print(
                f"    {name} VM_A: steps={m.get('VM_A_FINAL_STEPS', '?')}"
                f" host_calls={m.get('VM_A_HOST_CALLS', '?')}"
                f" alloc_bytes={m.get('VM_A_ALLOC_BYTES', '?')}"
                f" peak_rss_mib={m.get('VM_A_PEAK_RSS_MIB', '?')}"
                f" wall_s={m.get('VM_A_WALL_S', '?')}"
            )
            print(
                f"    {name} VM_B: steps={m.get('VM_B_FINAL_STEPS', '?')}"
                f" host_calls={m.get('VM_B_HOST_CALLS', '?')}"
                f" alloc_bytes={m.get('VM_B_ALLOC_BYTES', '?')}"
                f" peak_rss_mib={m.get('VM_B_PEAK_RSS_MIB', '?')}"
                f" wall_s={m.get('VM_B_WALL_S', '?')}"
                f" preflight_wall_s={m.get('VM_B_PREFLIGHT_WALL_S', '?')}"
            )
            print(f"    {name} AGGREGATE_WALL_S={m.get('AGGREGATE_WALL_S', '?')}")
    for w in warnings:
        print(f"  WARN: {w}")
    for n in plan.get("notes", []):
        print(f"  NOTE: {n}")
    print("")
    print("formulas (implemented):")
    for f in plan["formulas"]:
        print(f"  {f}")
    print("")

    gate_path = Path(opts["gate_script"])
    if not gate_path.is_file():
        print(f"repin_bootstrap_limits: no gate script: {gate_path}", file=sys.stderr)
        return 2
    current = read_current(gate_path, GATE_PINS)
    print("proposed pins (current values read from the gate script):")
    print(f"  {'CONSTANT':14s} {'CURRENT':>16s} {'PROPOSED':>16s}")
    for key in ("steps", "host_calls", "alloc_bytes", "rss_mib", "wall_timeout_s"):
        want = proposals[key]
        shown = "UNCHANGED" if want is None else str(want)
        cur = str(current.get(key, "?"))
        print(f"  {key:14s} {cur:>16s} {shown:>16s}")

    print("")
    print("machine-readable:")
    print(f"PROPOSED_STEPS_LIMIT={proposals['steps'] if proposals['steps'] is not None else 'UNCHANGED'}")
    print(f"PROPOSED_HOST_CALLS_LIMIT={proposals['host_calls'] if proposals['host_calls'] is not None else 'UNCHANGED'}")
    print(f"PROPOSED_ALLOC_BYTES_LIMIT={proposals['alloc_bytes'] if proposals['alloc_bytes'] is not None else 'UNCHANGED'}")
    print(f"PROPOSED_RSS_MIB={proposals['rss_mib'] if proposals['rss_mib'] is not None else 'UNCHANGED'}")
    print(f"PROPOSED_WALL_TIMEOUT_S={proposals['wall_timeout_s'] if proposals['wall_timeout_s'] is not None else 'UNCHANGED'}")
    print("")

    old_gate = gate_path.read_text(encoding="utf-8")
    new_gate, gate_changes = apply_pins(gate_path, GATE_PINS, proposals)
    diff = unified_diff(old_gate, new_gate, gate_path)
    if diff:
        print(f"gate diff ({'apply' if opts['apply'] else 'dry-run'}):")
        print(diff, end="" if diff.endswith("\n") else "\n")
    else:
        print("gate diff: (no changes)")

    driver_diff = ""
    driver_changes: list[tuple[str, int, int]] = []
    new_driver = ""
    driver_path = Path(opts["driver_path"])
    if opts["driver_defaults"]:
        if not driver_path.is_file():
            print(f"repin_bootstrap_limits: no driver: {driver_path}", file=sys.stderr)
            return 2
        old_driver = driver_path.read_text(encoding="utf-8")
        new_driver, driver_changes = apply_pins(
            driver_path, DRIVER_PINS, proposals, underscore_numbers=True
        )
        driver_diff = unified_diff(old_driver, new_driver, driver_path)
        if driver_diff:
            print(f"driver-defaults diff ({'apply' if opts['apply'] else 'dry-run'}):")
            print(driver_diff, end="" if driver_diff.endswith("\n") else "\n")
        else:
            print("driver-defaults diff: (no changes)")

    if not opts["apply"]:
        print("DRY RUN: no files written. Re-run with --apply to rewrite the pins.")
        return 0

    if gate_changes:
        mode = stat.S_IMODE(gate_path.stat().st_mode)
        tmp = gate_path.with_name(gate_path.name + ".repin.tmp")
        tmp.write_text(new_gate, encoding="utf-8")
        os.chmod(tmp, mode)
        os.replace(tmp, gate_path)
        print(f"applied {len(gate_changes)} gate pin(s) to {gate_path}")
    else:
        print(f"gate {gate_path}: already at proposed values")

    if opts["driver_defaults"]:
        if driver_changes:
            mode = stat.S_IMODE(driver_path.stat().st_mode)
            tmp = driver_path.with_name(driver_path.name + ".repin.tmp")
            tmp.write_text(new_driver, encoding="utf-8")
            os.chmod(tmp, mode)
            os.replace(tmp, driver_path)
            print(f"applied {len(driver_changes)} driver default(s) to {driver_path}")
        else:
            print(f"driver {driver_path}: already at proposed values")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
