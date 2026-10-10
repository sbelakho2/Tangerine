"""Scan orchestration for system_intel: extract -> graph snapshot.

`scan` pins a snapshot to ``(repo_root, commit_sha)``, upserts everything
idempotently, marks entities of fully-enumerated kinds stale when they
disappear, and returns a machine-readable report.  Re-running on an
unchanged tree changes nothing.
"""

from __future__ import annotations

import json
import subprocess
import time
from pathlib import Path

from system_intel.extract_core import Extraction, extract
from system_intel.graph import Graph

# Kinds the default extractor enumerates COMPLETELY in one pass.  Only
# these may be swept: a kind the extractor did not fully enumerate would
# otherwise be marked stale wholesale.  (Contract/Invariant/Owner/Event/
# Queue/Incident/Change/API/RuntimePath/DataFlow are populated by other
# layers and are never swept here.)
ENUMERATED_KINDS = (
    "Repository",
    "Project",
    "Package",
    "Module",
    "File",
    "Symbol",
    "Schema",
    "Configuration",
    "Test",
    "Service",
    "Resource",
    "Deployment",
    "API",
)


def _git_sha(root: Path) -> str:
    try:
        out = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if out.returncode == 0:
            sha = out.stdout.strip()
            if sha:
                return sha
    except (OSError, subprocess.SubprocessError):
        pass
    return "WORKTREE"


def _dedupe_entities(result: Extraction):
    """First occurrence wins (registry order is most-specific first)."""
    seen: dict[tuple[str, str], object] = {}
    ordered = []
    for ent in result.entities:
        key = (ent.kind, ent.qualified_name)
        if key in seen:
            continue
        seen[key] = ent
        ordered.append(ent)
    return ordered


def scan(root, db_path, commit_sha=None, repo_root=None):
    """Extract `root` into the graph at `db_path`; return the report dict."""
    started = time.monotonic()
    root_path = Path(root).expanduser().resolve()
    if not root_path.is_dir():
        raise NotADirectoryError(str(root_path))
    pinned_root = str(Path(repo_root).resolve()) if repo_root else str(root_path)
    commit = commit_sha or _git_sha(root_path)

    graph = Graph.open(db_path)
    try:
        snapshot_id = graph.ensure_snapshot(pinned_root, commit)
        result = extract(root_path, commit_sha=commit)
        entities = _dedupe_entities(result)

        ids: dict[tuple[str, str], int] = {}
        seen_by_kind: dict[str, set[str]] = {}
        # Resolve relation endpoints against THIS extraction in memory
        # (exact qualified name first, then the unique suffix at '::'
        # boundaries) — no per-relation SQL scan.
        exact_by_qn: dict[str, int] = {}
        tail_index: dict[str, list[str]] = {}

        def _index(ent) -> None:
            qn = ent.qualified_name
            exact_by_qn.setdefault(qn, ids[(ent.kind, qn)])
            segments = qn.split("::")
            for i in range(len(segments)):
                tail_index.setdefault("::".join(segments[i:]), []).append(qn)

        def resolve(target: str):
            if target in exact_by_qn:
                return exact_by_qn[target]
            candidates = tail_index.get(target)
            if candidates and len(set(candidates)) == 1:
                return exact_by_qn[candidates[0]]
            # Qualified module-path fallback (Tangerine-style `a::b`):
            # try the file/module spellings the target names.
            if "::" in target:
                base = target.replace("::", "/")
                for cand in (base + ".tg", base + "/mod.tg", base + ".rs"):
                    if cand in exact_by_qn:
                        return exact_by_qn[cand]
            return None

        relations_upserted = 0
        relations_unresolved = 0
        facts_upserted = 0

        with graph.batch():
            for ent in entities:
                entity_id = graph.upsert_entity(
                    ent.kind,
                    ent.name,
                    ent.qualified_name,
                    snapshot_id=snapshot_id,
                    file=ent.file,
                    line=ent.line,
                    tier=ent.tier,
                    provenance=ent.provenance,
                    confidence=ent.confidence,
                    derived_from=list(ent.derived_from),
                    attrs=ent.attrs,
                )
                ids[(ent.kind, ent.qualified_name)] = entity_id
                if ent.kind in ENUMERATED_KINDS:
                    seen_by_kind.setdefault(ent.kind, set()).add(ent.qualified_name)
                _index(ent)

            for rel in result.relations:
                src_id = resolve(rel.src_qn)
                dst_id = resolve(rel.dst_qn)
                if src_id is None or dst_id is None:
                    relations_unresolved += 1
                    continue
                graph.upsert_relation(
                    src_id,
                    dst_id,
                    rel.kind,
                    snapshot_id=snapshot_id,
                    tier=rel.tier,
                    provenance=rel.provenance,
                    confidence=rel.confidence,
                    derived_from=list(rel.derived_from),
                    attrs=rel.attrs,
                )
                relations_upserted += 1

            for fact in result.facts:
                graph.upsert_fact(
                    fact.subject,
                    fact.predicate,
                    fact.object,
                    snapshot_id=snapshot_id,
                    tier=fact.tier,
                    provenance=fact.provenance,
                    confidence=fact.confidence,
                    derived_from=list(fact.derived_from),
                    uncertainty=fact.uncertainty,
                )
                facts_upserted += 1

        stale_entities = graph.stale_sweep(snapshot_id, seen_by_kind)

        counts_by_kind: dict[str, int] = {}
        for ent in entities:
            counts_by_kind[ent.kind] = counts_by_kind.get(ent.kind, 0) + 1

        stats = graph.stats(snapshot_id)
        report = {
            "snapshot_id": snapshot_id,
            "repo_root": pinned_root,
            "commit_sha": commit,
            "schema_version": stats.get("schema_version", 1),
            "entities_upserted": len(entities),
            "relations_upserted": relations_upserted,
            "relations_unresolved": relations_unresolved,
            "facts_upserted": facts_upserted,
            "stale_entities": stale_entities,
            "stale_relations": stats.get("stale_relations", 0),
            "counts_by_kind": dict(sorted(counts_by_kind.items())),
            "duration_ms": int((time.monotonic() - started) * 1000),
            "db_path": str(db_path),
        }
        return report
    finally:
        graph.close()


def report_to_json(report) -> str:
    return json.dumps(report, indent=2, sort_keys=True)
