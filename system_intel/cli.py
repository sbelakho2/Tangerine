"""Command-line interface for the Tangerine System Intelligence graph.

Usage: ``python3 -m system_intel.cli <command> [options]`` or via
``tools/system_intel.sh``.  Every read command accepts ``--json`` for
machine-readable output.  ``scan`` lazily imports ``system_intel.persist``
so the rest of the CLI (including ``--help``) works standalone.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from system_intel.graph import Graph

DEFAULT_DB_PATH = "./.tangerine-intel.db"


def _default_db(explicit):
    return explicit or os.environ.get("TANGERINE_INTEL_DB") or DEFAULT_DB_PATH


def _dump(obj, as_json):
    if as_json:
        print(json.dumps(obj, indent=2, sort_keys=True, default=str))
        return
    _print_human(obj)


def _entity_line(ent):
    stale = " stale" if ent.get("stale") else ""
    return (f"{ent['kind']} {ent['qualified_name']} "
            f"(id={ent['id']} tier={ent['tier']} {ent['provenance']} "
            f"conf={ent['confidence']:.2f}{stale})")


def _print_human(obj):
    if isinstance(obj, list):
        for item in obj:
            if isinstance(item, dict) and "qualified_name" in item:
                print(_entity_line(item))
            else:
                print(item)
        return
    print(json.dumps(obj, indent=2, sort_keys=True, default=str))


def _load_entity(graph, kind, qualified_name):
    ent = graph.find_entity(kind, qualified_name, include_stale=True)
    if ent is None:
        print(f"error: no entity kind={kind!r} qualified_name={qualified_name!r}",
              file=sys.stderr)
    return ent


def _apply_scan(scan_func, path, db_path, commit):
    """Call persist.scan tolerating small signature differences."""
    attempts = []
    if commit is not None:
        attempts.append(lambda: scan_func(path, db_path=db_path, commit=commit))
        attempts.append(lambda: scan_func(path, db_path=db_path, commit_sha=commit))
    attempts.append(lambda: scan_func(path, db_path=db_path))
    attempts.append(lambda: scan_func(path, db_path))
    last_error = None
    for attempt in attempts:
        try:
            return attempt()
        except TypeError as exc:
            last_error = exc
    raise last_error


def cmd_scan(args):
    db_path = _default_db(args.db)
    Path(db_path).expanduser().parent.mkdir(parents=True, exist_ok=True)
    try:
        from system_intel.persist import scan as persist_scan
    except ImportError as exc:
        print(f"error: system_intel.persist unavailable ({exc})", file=sys.stderr)
        return 1
    result = _apply_scan(persist_scan, args.path, db_path, args.commit)
    if result is not None:
        print(json.dumps(result, indent=2, sort_keys=True, default=str))
    return 0


def cmd_stats(args):
    with Graph.open(args.db, create=False) as graph:
        _dump(graph.stats(), args.json)
    return 0


def cmd_export(args):
    with Graph.open(args.db, create=False) as graph:
        print(json.dumps(graph.export_json(), indent=2, sort_keys=True, default=str))
    return 0


def cmd_entities(args):
    with Graph.open(args.db, create=False) as graph:
        rows = graph.entities_by_kind(args.kind, include_stale=args.include_stale)
        _dump(rows, args.json)
    return 0


def cmd_neighbors(args):
    with Graph.open(args.db, create=False) as graph:
        ent = _load_entity(graph, args.kind, args.qualified_name)
        if ent is None:
            return 1
        rows = graph.neighbors(ent["id"], kind=args.edge_kind,
                               direction=args.direction,
                               include_stale=args.include_stale)
        if args.json:
            print(json.dumps(rows, indent=2, sort_keys=True, default=str))
        else:
            for rel in rows:
                arrow = "->" if rel["direction"] == "out" else "<-"
                print(f"{arrow} {rel['kind']} ({rel['id']}) {_entity_line(rel['entity'])}")
    return 0


def _closure_cmd(args, method):
    with Graph.open(args.db, create=False) as graph:
        ent = _load_entity(graph, args.kind, args.qualified_name)
        if ent is None:
            return 1
        result = getattr(graph, method)(ent["id"], max_depth=args.max_depth)
        if args.json:
            print(json.dumps(result, indent=2, sort_keys=True, default=str))
        else:
            for level in result["levels"]:
                names = ", ".join(e["qualified_name"] for e in level["entities"])
                print(f"depth {level['depth']}: {names}")
            print(f"contracts: {len(result['contracts'])}  "
                  f"invariants: {len(result['invariants'])}  "
                  f"tests: {len(result['tests'])}  "
                  f"incidents: {len(result['incidents'])}")
    return 0


def cmd_dependencies(args):
    return _closure_cmd(args, "dependencies")


def cmd_impact(args):
    return _closure_cmd(args, "impact")


def cmd_explain(args):
    with Graph.open(args.db, create=False) as graph:
        ent = _load_entity(graph, args.kind, args.qualified_name)
        if ent is None:
            return 1
        edges = graph.neighbors(ent["id"], direction="both", include_stale=True)
        contracts = graph.contracts(component_qn=ent["qualified_name"])
        invariants = graph.invariants(component_qn=ent["qualified_name"])
        payload = {"entity": ent, "edges": edges,
                   "contracts": contracts, "invariants": invariants}
        if args.json:
            print(json.dumps(payload, indent=2, sort_keys=True, default=str))
            return 0
        print(_entity_line(ent))
        if ent.get("file"):
            print(f"  file: {ent['file']}" + (f":{ent['line']}" if ent.get("line") else ""))
        if ent.get("attrs"):
            print(f"  attrs: {json.dumps(ent['attrs'], sort_keys=True)}")
        print(f"edges ({len(edges)}):")
        for rel in edges:
            arrow = "->" if rel["direction"] == "out" else "<-"
            print(f"  {arrow} {rel['kind']} {_entity_line(rel['entity'])}")
        print(f"contracts ({len(contracts)}):")
        for con in contracts:
            print(f"  [{con['kind']}] {con['name']}")
        print(f"invariants ({len(invariants)}):")
        for inv in invariants:
            print(f"  {inv['statement']}")
    return 0


def cmd_invariant_list(args):
    with Graph.open(args.db, create=False) as graph:
        rows = graph.invariants(component_qn=args.component)
        if args.json:
            print(json.dumps(rows, indent=2, sort_keys=True, default=str))
        else:
            for inv in rows:
                comp = f" [{inv['component_qn']}]" if inv.get("component_qn") else ""
                print(f"{inv['id']}: {inv['statement']}{comp}")
    return 0


def _looks_like_path(value):
    if "/" in value or "\\" in value:
        return True
    return Path(value).exists()


def cmd_blast_radius(args):
    with Graph.open(args.db, create=False) as graph:
        report = {}
        for target in args.changed:
            if _looks_like_path(target):
                file_entities = graph.entities_by_file(target, include_stale=True)
                qns = [e["qualified_name"] for e in file_entities]
                if qns:
                    surface = graph.change_surface(qns, max_depth=args.max_depth)
                    surface["file_matched_entities"] = file_entities
                else:
                    surface = {"matched": {}, "unmatched": [target], "impacted": [],
                               "contracts": [], "invariants": [], "tests": [],
                               "incidents": [], "likely_regression_surfaces": []}
            else:
                surface = graph.change_surface([target], max_depth=args.max_depth)
            report[target] = surface

        if args.json:
            print(json.dumps(report, indent=2, sort_keys=True, default=str))
            return 0

        for target, surface in report.items():
            print(f"== {target}")
            print(f"  matched entities: {sum(len(v) for v in surface['matched'].values())}"
                  f"  impacted: {len(surface['impacted'])}")
            if surface["unmatched"]:
                print(f"  unmatched: {', '.join(surface['unmatched'])}")
            contracts = surface["contracts"]
            print(f"  contracts at risk: {len(contracts)}"
                  + (" (" + ", ".join(c["name"] for c in contracts) + ")" if contracts else ""))
            for inv in surface["invariants"]:
                print(f"  invariant: {inv['statement']}")
            for test in surface["tests"]:
                print(f"  test: {test['qualified_name']}")
            for inc in surface["incidents"]:
                when = f" @ {inc['occurred_utc']}" if inc.get("occurred_utc") else ""
                print(f"  historical incident: {inc['summary']}{when}")
            for qn in surface["likely_regression_surfaces"]:
                print(f"  likely regression surface: {qn}")
    return 0


def cmd_protocol(args):
    """Emit the neutral exchange protocol (independent of internals)."""
    from system_intel.protocol import protocol_json

    with Graph.open(args.db, create=False) as g:
        try:
            print(protocol_json(g, args.snapshot))
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
    return 0


def build_parser():
    parser = argparse.ArgumentParser(
        prog="system_intel",
        description="Tangerine System Intelligence: query what is true about a system, "
                    "what depends on what, and what can break.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("scan", help="extract a repository into the graph database")
    p.add_argument("path", help="repository root to scan")
    p.add_argument("--db", help="SQLite database path (default: env TANGERINE_INTEL_DB or ./.tangerine-intel.db)")
    p.add_argument("--commit", default=None, help="commit SHA to pin the snapshot to")
    p.set_defaults(func=cmd_scan)

    p = sub.add_parser("stats", help="graph counts and schema version")
    p.add_argument("db")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_stats)

    p = sub.add_parser("export", help="export the snapshot as JSON")
    p.add_argument("db")
    p.add_argument("--json", action="store_true", help="accepted; output is JSON")
    p.set_defaults(func=cmd_export)

    p = sub.add_parser("entities", help="list entities of a kind")
    p.add_argument("db")
    p.add_argument("--kind", required=True)
    p.add_argument("--json", action="store_true")
    p.add_argument("--include-stale", action="store_true")
    p.set_defaults(func=cmd_entities)

    p = sub.add_parser("neighbors", help="show edges around an entity")
    p.add_argument("db")
    p.add_argument("--kind", required=True)
    p.add_argument("--qualified-name", required=True)
    p.add_argument("--edge-kind", default=None)
    p.add_argument("--direction", choices=("both", "in", "out"), default="both")
    p.add_argument("--json", action="store_true")
    p.add_argument("--include-stale", action="store_true")
    p.set_defaults(func=cmd_neighbors)

    for name, help_text, func in (
        ("dependencies", "forward closure: what this entity depends on", cmd_dependencies),
        ("impact", "reverse closure: what depends on this entity", cmd_impact),
    ):
        p = sub.add_parser(name, help=help_text)
        p.add_argument("db")
        p.add_argument("--kind", required=True)
        p.add_argument("--qualified-name", required=True)
        p.add_argument("--max-depth", type=int, default=6)
        p.add_argument("--json", action="store_true")
        p.set_defaults(func=func)

    p = sub.add_parser("explain", help="entity plus all edges, contracts and invariants")
    p.add_argument("db")
    p.add_argument("--kind", required=True)
    p.add_argument("--qualified-name", required=True)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_explain)

    p = sub.add_parser("invariant-list", help="list invariants, optionally for a component")
    p.add_argument("db")
    p.add_argument("--component", default=None)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_invariant_list)

    p = sub.add_parser("blast-radius", help="impact analysis for changed files or symbols")
    p.add_argument("db")
    p.add_argument("changed", nargs="+", help="changed file paths or qualified names")
    p.add_argument("--max-depth", type=int, default=6)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_blast_radius)

    p = sub.add_parser(
        "protocol",
        help="emit the neutral exchange protocol (facts/claims/invariants/contracts/risks)",
    )
    p.add_argument("db")
    p.add_argument("--snapshot", type=int, default=None)
    p.set_defaults(func=cmd_protocol)

    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except FileNotFoundError as exc:
        print(f"error: database not found: {exc}", file=sys.stderr)
        return 1
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
