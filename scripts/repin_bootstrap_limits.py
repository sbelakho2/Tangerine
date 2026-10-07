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
    """Returns warnings; exits 2 on a hard validation failure."""
    errors: list[str] = []
    warnings: list[str] = []
    for name, m in (("cold", cold), ("warm", warm)):
        status = m.get("STATUS", "UNKNOWN")
        if status != "COMPLETED":
            errors.append(f"{name} block STATUS={status}, want COMPLETED")
        if m.get("RUN_OUTCOME", "UNKNOWN") == "FAIL":
            warnings.append(
                f"{name} block reports RUN_OUTCOME=FAIL (the VM summary exists but"
                " the log's selfcheck did not pass); budget numbers are still"
                " VM-completion measurements"
            )

    shas = {}
    for name, m in (("cold", cold), ("warm", warm)):
        sha = m.get("RUN_SHA", "UNKNOWN")
        if sha not in ("", "UNKNOWN"):
            shas[name] = sha
    if opts["sha"]:
        shas["cli"] = opts["sha"]
    if len(set(shas.values())) > 1:
        errors.append(f"RUN_SHA mismatch: {shas}")
    elif not shas:
        warnings.append(
            "RUN_SHA absent from both blocks (and no --sha given): same-tree"
            " identity is NOT verified beyond this warning"
        )

    targets = {}
    for name, m in (("cold", cold), ("warm", warm)):
        tgt = m.get("RUN_TARGET", "UNKNOWN")
        if tgt not in ("", "UNKNOWN"):
            targets[name] = tgt
    if opts["target"]:
        targets["cli"] = opts["target"]
    if len(set(targets.values())) > 1:
        errors.append(f"RUN_TARGET mismatch: {targets}")
    elif not targets:
        warnings.append(
            "RUN_TARGET absent from both blocks (and no --target given): the"
            " same target triple is NOT verified beyond this warning"
        )

    fps = {
        name: m.get("CLOSURE_FINGERPRINT", "UNKNOWN")
        for name, m in (("cold", cold), ("warm", warm))
        if m.get("CLOSURE_FINGERPRINT", "UNKNOWN") not in ("", "UNKNOWN")
    }
    if len(fps) == 2 and len(set(fps.values())) > 1:
        errors.append(
            "CLOSURE_FINGERPRINT mismatch (the two logs are not the same"
            f" closure): {fps}"
        )
    elif len(fps) == 1:
        warnings.append(
            "CLOSURE_FINGERPRINT present in only one block; same-closure"
            " identity is not cross-checked"
        )

    if errors:
        for e in errors:
            print(f"repin_bootstrap_limits: VALIDATION FAIL: {e}", file=sys.stderr)
        sys.exit(2)
    return warnings


def build_proposals(cold: dict[str, str], warm: dict[str, str]) -> dict:
    proposals: dict[str, int | None] = {}
    formulas: list[str] = []

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

    wall_c = as_float(cold, "WALL_PHASE_SUM_S")
    wall_w = as_float(warm, "WALL_PHASE_SUM_S")
    if wall_c is None or wall_w is None:
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
    else:
        m = max(wall_c, wall_w)
        proposals["wall_timeout_s"] = int(math.ceil(m * 1.5 / 60.0) * 60)
        formulas.append(
            f"wall_timeout_s = ceil(max({wall_c:g}, {wall_w:g}) * 1.5 / 60) * 60"
            f" = ceil({m * 1.5 / 60.0:.2f}) * 60 = {proposals['wall_timeout_s']}"
        )
    return {"values": proposals, "formulas": formulas}


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
            f"  {name}: label={m.get('RUN_LABEL', '?')} status={m.get('STATUS', '?')}"
            f" steps={m.get('FINAL_STEPS', '?')} host_calls={m.get('HOST_CALLS', '?')}"
            f" peak_rss_mib={m.get('PEAK_RSS_MIB', '?')}"
            f" alloc_bytes={m.get('ALLOC_BYTES', '?')}"
            f" sha={m.get('RUN_SHA', '?')} target={m.get('RUN_TARGET', '?')}"
        )
    for w in warnings:
        print(f"  WARN: {w}")
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
