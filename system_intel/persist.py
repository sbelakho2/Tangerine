"""Scan orchestration for system_intel: identity -> provider -> snapshot.

v2 semantics (INTERFACES.md §1/§3):

* A scan computes the revision identity (repo identity, source revision,
  tree digest, semantic configuration, provider set digest) and either
  REUSES the finalized snapshot for that exact tuple (idempotent, no
  writes) or writes a new draft and finalizes it inside ONE transaction.
* A dirty git worktree is never recorded as the clean HEAD sha; its
  revision is ``worktree:<base-sha>:<tree-digest>`` (or a hard failure in
  ``strict_clean`` mode).  Non-git trees get ``content:<tree-digest>``.
* Relation endpoints resolve by typed ``(kind, stable_id)`` exact match.
  Unresolved targets become first-class ``unresolved_edge`` rows AND a
  relation row with ``resolved=0`` -- never a guess and never a mutation of
  an older snapshot.
* On any exception the transaction is rolled back and NO snapshot rows
  remain (P0-4).
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import time
from pathlib import Path

from system_intel.extract_core import (
    EXTRACTOR_PROVIDER_ID,
    EXTRACTOR_PROVIDER_VERSION,
    extract,
    iter_files,
)
from system_intel.graph import (
    Graph,
    SnapshotError,
    derive_stable_id,
    identity_revision_digest,
)

GENERIC_CAPABILITIES = {
    "entities": "complete",
    "relations": "partial",
    "calls": "unavailable",
    "runtime": "unknown",
    "tests": "partial",
}

FALLBACK_PROVIDER = (EXTRACTOR_PROVIDER_ID, EXTRACTOR_PROVIDER_VERSION)


def _sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _canonical(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), default=str)


def _git(root: Path, *args: str) -> str | None:
    try:
        out = subprocess.run(
            ["git", "-C", str(root), *args],
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip()


def _tree_digest(root: Path) -> str:
    """sha256 over the canonical (relpath,size,mode,content-digest) manifest."""
    entries = []
    for path in iter_files(root):
        try:
            rel = path.relative_to(root).as_posix()
        except ValueError:
            continue
        try:
            st = path.stat()
            data = path.read_bytes()
            content = hashlib.sha256(data).hexdigest()
            entries.append((rel, int(st.st_size), int(st.st_mode) & 0o777, content))
        except OSError:
            entries.append((rel, -1, -1, "#unreadable"))
    digest = hashlib.sha256()
    for rel, size, mode, content in sorted(entries):
        digest.update(f"{rel}\x00{size}\x00{mode}\x00{content}\n".encode("utf-8"))
    return digest.hexdigest()


def _provider_set_digest(providers) -> str:
    pairs = sorted((str(a), str(b)) for a, b in providers)
    return hashlib.sha256(_canonical(pairs).encode("utf-8")).hexdigest()


def _identity(root, *, commit_sha=None, strict_clean=False, providers=(),
              semantic_configuration=None, repo_root=None) -> dict:
    """Compute the §1 revision identity for a scan root.

    ``providers`` is a sequence of ``(provider_id, provider_version)`` pairs.
    ``semantic_configuration`` may be a dict (canonicalized) or a string.
    ``repo_root`` is accepted for provenance symmetry and ignored here.
    """
    root_path = Path(root).expanduser().resolve()
    tree = _tree_digest(root_path)
    head = _git(root_path, "rev-parse", "HEAD")
    if head:
        status = _git(root_path, "status", "--porcelain")
        dirty = status is None or bool(status.strip())
        base = str(commit_sha) if commit_sha else head
        if dirty:
            if strict_clean:
                raise SnapshotError(
                    f"worktree at {root_path} is dirty; strict_clean requires a true revision"
                )
            revision = f"worktree:{base}:{tree}"
        else:
            revision = base
    else:
        if strict_clean:
            raise SnapshotError(
                f"{root_path} is not a git repository; strict_clean cannot produce a true revision"
            )
        revision = f"content:{tree}"

    remote = _git(root_path, "config", "--get", "remote.origin.url")
    if remote:
        repo_identity = _sha256_text("remote:" + remote)
    else:
        repo_identity = _sha256_text("root:" + str(root_path))

    if semantic_configuration is None:
        semantic = "{}"
    elif isinstance(semantic_configuration, str):
        semantic = semantic_configuration
    else:
        semantic = _canonical(semantic_configuration)

    identity = {
        "repo_root": str(Path(repo_root).resolve()) if repo_root else str(root_path),
        "repo_identity": repo_identity,
        "source_revision": revision,
        "tree_digest": tree,
        "semantic_configuration": semantic,
        "provider_set_digest": _provider_set_digest(providers),
    }
    identity["revision_digest"] = identity_revision_digest(identity)
    return identity


# Public alias for tests / embedding callers.
compute_identity = _identity


def _field(obj, name, default=None):
    """Duck-typed field access for provider records (objects or dicts)."""
    if isinstance(obj, dict):
        return obj.get(name, default)
    if hasattr(obj, name):
        return getattr(obj, name)
    return default


def _as_list(value):
    if value is None:
        return []
    if isinstance(value, (list, tuple, set)):
        return list(value)
    return [value]


def _dedupe_entities(records):
    """First occurrence wins, keyed by typed (kind, stable_id)."""
    seen: set[tuple[str, str]] = set()
    ordered = []
    for record in records:
        kind = str(_field(record, "kind", "") or "")
        stable = _field(record, "stable_id", None)
        if not stable:
            stable = derive_stable_id(kind, _field(record, "qualified_name", None))
        key = (kind, str(stable))
        if key in seen:
            continue
        seen.add(key)
        ordered.append(record)
    return ordered


def _capabilities_dict(caps) -> dict:
    if caps is None:
        return {}
    if isinstance(caps, dict):
        return {str(k): str(v) for k, v in caps.items()}
    out: dict[str, str] = {}
    for cap in caps:
        family = str(_field(cap, "family", "") or "")
        verdict = str(_field(cap, "verdict", "unknown") or "unknown")
        if family and family not in out:
            out[family] = verdict
    return out


def _provider_descriptors(provider):
    """Normalize a provider argument into (id, version) pairs for identity."""
    if provider is None:
        return [FALLBACK_PROVIDER]
    pid = str(_field(provider, "provider_id", "") or "unknown-provider")
    ver = str(_field(provider, "provider_version", "") or "")
    return [(pid, ver)]


def _project(graph: Graph, snapshot_id: int, root_path: Path, provider,
             commit_sha) -> dict:
    """Project a provider snapshot (or the built-in extractor) into the draft."""
    default_pid, default_ver = _provider_descriptors(provider)[0]
    evidence_records: list = []

    if provider is None:
        result = extract(root_path, commit_sha=commit_sha)
        entities_in = list(result.entities)
        relations_in = list(result.relations)
        facts_in = list(result.facts)
        providers_in = [{
            "provider_id": EXTRACTOR_PROVIDER_ID,
            "provider_version": EXTRACTOR_PROVIDER_VERSION,
            "capabilities": dict(GENERIC_CAPABILITIES),
            "invoked": True,
        }]
    else:
        snap = provider.snapshot(root_path, commit_sha=commit_sha)
        if snap is None:
            raise SnapshotError(
                f"provider {default_pid!r} returned no snapshot for {root_path}"
            )
        entities_in = _as_list(_field(snap, "entities", []))
        relations_in = _as_list(_field(snap, "relations", []))
        facts_in = _as_list(_field(snap, "facts", []))
        evidence_records = _as_list(_field(snap, "evidence", []))
        providers_in = _as_list(_field(snap, "providers", []))
        if not providers_in:
            providers_in = [{
                "provider_id": default_pid,
                "provider_version": default_ver,
                "capabilities": _capabilities_dict(_field(provider, "capabilities", None)),
                "invoked": True,
            }]
        unresolved_in = _as_list(_field(snap, "unresolved", []))
        relations_in = relations_in + unresolved_in

    entities = _dedupe_entities(entities_in)

    ids_by_stable: dict[str, int] = {}
    ids_by_typed: dict[tuple[str, str], int] = {}
    stable_by_qn: dict[str, str] = {}
    counts_by_kind: dict[str, int] = {}
    for ent in entities:
        kind = str(_field(ent, "kind", "") or "")
        name = str(_field(ent, "name", "") or "")
        qn = _field(ent, "qualified_name", None)
        stable = _field(ent, "stable_id", None)
        if not stable:
            stable = derive_stable_id(kind, qn or name)
        stable = str(stable)
        if qn is None:
            qn = stable
        qn = str(qn)
        ent_provider = str(_field(ent, "provider", default_pid) or default_pid)
        ent_revision = str(_field(ent, "provider_revision", default_ver) or default_ver)
        entity_id = graph.upsert_entity(
            kind,
            name,
            stable,
            qualified_name=qn,
            snapshot_id=snapshot_id,
            file=_field(ent, "file", None),
            line=_field(ent, "line", None),
            tier=_field(ent, "tier", 0) or 0,
            provenance=_field(ent, "provenance", "observed") or "observed",
            confidence=_field(ent, "confidence", 1.0),
            derived_from=_as_list(_field(ent, "derived_from", ())),
            uncertainty=_field(ent, "uncertainty", None),
            attrs=_field(ent, "attrs", None) or {},
            epistemic_state=_field(ent, "epistemic_state", None),
            analysis_depth=_field(ent, "analysis_depth", None),
            completeness=_field(ent, "completeness", None),
            provider=ent_provider,
            provider_revision=ent_revision,
        )
        ids_by_stable.setdefault(stable, entity_id)
        ids_by_typed.setdefault((kind, stable), entity_id)
        stable_by_qn.setdefault(qn, stable)
        stable_by_qn.setdefault(stable, stable)
        counts_by_kind[kind] = counts_by_kind.get(kind, 0) + 1

    def _resolve(key, kind):
        if key in (None, ""):
            return None
        key = str(key)
        if kind:
            hit = ids_by_typed.get((str(kind), key))
            if hit is not None:
                return hit
            return None
        return ids_by_stable.get(key)

    relations_upserted = 0
    relations_unresolved = 0
    unresolved_edges = 0
    for rel in relations_in:
        rkind = str(_field(rel, "kind", "") or "")
        src_key = _field(rel, "src_key", None)
        dst_key = _field(rel, "dst_key", None)
        if src_key is None:
            src_key = _field(rel, "src_qn", "")
        if dst_key is None:
            dst_key = _field(rel, "dst_qn", None)
        if dst_key is None:
            dst_key = _field(rel, "dst_raw", "")
        src_kind = _field(rel, "src_kind", None)
        dst_kind = _field(rel, "dst_kind", None)
        src_id = _resolve(src_key, src_kind) if src_kind else _resolve(src_key, None)
        dst_id = _resolve(dst_key, dst_kind) if dst_kind else _resolve(dst_key, None)
        candidates = _field(rel, "candidates", None)
        if not candidates:
            attrs = _field(rel, "attrs", None) or {}
            if isinstance(attrs, dict):
                candidates = attrs.get("candidates")
        rel_provider = str(_field(rel, "provider", default_pid) or default_pid)
        rel_revision = str(_field(rel, "provider_revision", default_ver) or default_ver)

        if src_id is None:
            # Source itself is unknown: preserve as an unresolved edge only
            # (a relation row needs a real src_id).
            relations_unresolved += 1
            graph.add_unresolved_edge(
                snapshot_id, src_key or "", str(dst_key or ""), rkind,
                provider=rel_provider, provider_revision=rel_revision,
                candidates=candidates or [],
                confidence=_field(rel, "confidence", 0.3) or 0.3,
                completeness=str(_field(rel, "completeness", "unknown") or "unknown"),
            )
            unresolved_edges += 1
            continue

        common = dict(
            snapshot_id=snapshot_id,
            tier=_field(rel, "tier", 1) or 0,
            provenance=_field(rel, "provenance", "inferred") or "inferred",
            confidence=_field(rel, "confidence", 1.0),
            derived_from=_as_list(_field(rel, "derived_from", ())),
            attrs=_field(rel, "attrs", None) or {},
            src_key=str(src_key or ""),
            epistemic_state=_field(rel, "epistemic_state", None),
            analysis_depth=_field(rel, "analysis_depth", None),
            completeness=_field(rel, "completeness", None),
            provider=rel_provider,
        )
        if dst_id is None:
            relations_unresolved += 1
            graph.add_unresolved_edge(
                snapshot_id, str(src_key or ""), str(dst_key or ""), rkind,
                provider=rel_provider, provider_revision=rel_revision,
                candidates=candidates or [],
                confidence=_field(rel, "confidence", 0.3) or 0.3,
                completeness=str(_field(rel, "completeness", "unknown") or "unknown"),
            )
            unresolved_edges += 1
            graph.upsert_relation(
                src_id, None, rkind, dst_key=str(dst_key or ""), resolved=0, **common
            )
        else:
            graph.upsert_relation(src_id, dst_id, rkind, **common)
            relations_upserted += 1

    facts_upserted = 0
    for fact in facts_in:
        subject = str(_field(fact, "subject", "") or "")
        stable_subject = _field(fact, "stable_subject", None)
        if not stable_subject:
            stable_subject = stable_by_qn.get(subject, subject)
        graph.upsert_fact(
            subject,
            _field(fact, "predicate", "") or "",
            _field(fact, "object", "") or "",
            snapshot_id=snapshot_id,
            tier=_field(fact, "tier", 0) or 0,
            provenance=_field(fact, "provenance", "observed") or "observed",
            confidence=_field(fact, "confidence", 1.0),
            derived_from=_as_list(_field(fact, "derived_from", ())),
            uncertainty=_field(fact, "uncertainty", None),
            epistemic_state=_field(fact, "epistemic_state", None),
            analysis_depth=_field(fact, "analysis_depth", None),
            completeness=_field(fact, "completeness", None),
            provider=str(_field(fact, "provider", default_pid) or default_pid),
            provider_revision=str(_field(fact, "provider_revision", default_ver) or default_ver),
            stable_subject=str(stable_subject or ""),
        )
        facts_upserted += 1

    for ev in evidence_records:
        graph.add_evidence(
            snapshot_id,
            str(_field(ev, "kind", "unknown") or "unknown"),
            str(_field(ev, "ref", "") or ""),
            digest=_field(ev, "digest", None),
            summary=str(_field(ev, "summary", "") or ""),
            payload=_field(ev, "payload", None),
            provider=str(_field(ev, "provider", default_pid) or default_pid),
        )

    recorded_providers = []
    for desc in providers_in:
        pid = str(_field(desc, "provider_id", None) or _field(desc, "provider", "") or default_pid)
        ver = str(_field(desc, "provider_version", None) or _field(desc, "version", "") or default_ver)
        caps = _capabilities_dict(_field(desc, "capabilities", None))
        graph.record_provider(snapshot_id, pid, ver, caps,
                              invoked=bool(_field(desc, "invoked", True)))
        recorded_providers.append(pid)

    return {
        "entities": len(entities),
        "relations": relations_upserted,
        "relations_unresolved": relations_unresolved,
        "facts": facts_upserted,
        "unresolved_edges": unresolved_edges,
        "evidence": len(evidence_records),
        "providers": recorded_providers,
        "counts_by_kind": counts_by_kind,
    }


def _base_report(graph, snapshot_row, identity, db_path, started):
    stats = graph.stats(int(snapshot_row["id"]))
    return {
        "snapshot_id": int(snapshot_row["id"]),
        "state": snapshot_row["state"],
        "repo_root": snapshot_row.get("repo_root"),
        "commit_sha": snapshot_row["source_revision"],
        "schema_version": stats["schema_version"],
        "identity": {
            "repo_identity": identity["repo_identity"],
            "source_revision": identity["source_revision"],
            "tree_digest": identity["tree_digest"],
            "semantic_configuration": identity["semantic_configuration"],
            "provider_set_digest": identity["provider_set_digest"],
            "revision_digest": identity["revision_digest"],
        },
        "revision_digest": identity["revision_digest"],
        "stale_entities": 0,
        "stale_relations": 0,
        "completeness": graph.completeness(int(snapshot_row["id"])),
        "duration_ms": int((time.monotonic() - started) * 1000),
        "db_path": str(db_path),
    }


def scan(root, db_path, *, commit_sha=None, repo_root=None, strict_clean=False,
         provider=None, semantic_configuration=None):
    """Extract `root` into the graph at `db_path`; return the report dict.

    Idempotent per revision tuple: re-scanning an unchanged tree returns the
    existing finalized snapshot with ``reused=True`` and performs no writes.
    """
    started = time.monotonic()
    root_path = Path(root).expanduser().resolve()
    if not root_path.is_dir():
        raise NotADirectoryError(str(root_path))

    providers = _provider_descriptors(provider)
    identity = _identity(
        root_path,
        commit_sha=commit_sha,
        strict_clean=strict_clean,
        providers=providers,
        semantic_configuration=semantic_configuration,
        repo_root=repo_root,
    )
    pinned_root = str(Path(repo_root).resolve()) if repo_root else str(root_path)

    graph = Graph.open(db_path)
    try:
        existing = graph.snapshot_for(identity)
        if existing is not None and existing["state"] == "finalized":
            report = _base_report(graph, existing, identity, db_path, started)
            stats = graph.stats(int(existing["id"]))
            report.update({
                "reused": True,
                "stale": False,
                "entities_upserted": sum(stats["entities_by_kind"].values()),
                "relations_upserted": stats["relations_resolved"],
                "relations_unresolved": stats["relations_unresolved"],
                "facts_upserted": stats["facts"],
                "unresolved_edges": stats["unresolved_edges"],
                "evidence": stats["evidence"],
                "providers": stats["providers"],
                "counts_by_kind": dict(stats["entities_by_kind"]),
            })
            return report

        counts = None
        snapshot_id = None
        with graph.batch():
            if existing is not None:
                # A crashed scan left a draft for the same revision: drop it.
                graph.abort_draft(int(existing["id"]))
            snapshot_id = graph.begin_draft({**identity, "repo_root": pinned_root})
            counts = _project(graph, snapshot_id, root_path, provider, commit_sha)
            graph.integrity_report(snapshot_id)
            graph.finalize_snapshot(snapshot_id)

        snapshot_row = graph._snapshot_row(snapshot_id)
        report = _base_report(graph, snapshot_row, identity, db_path, started)
        stats = graph.stats(snapshot_id)
        report.update({
            "reused": False,
            "stale": False,
            "entities_upserted": sum(stats["entities_by_kind"].values()),
            "relations_upserted": stats["relations_resolved"],
            "relations_unresolved": stats["relations_unresolved"],
            "facts_upserted": stats["facts"],
            "unresolved_edges": stats["unresolved_edges"],
            "evidence": stats["evidence"],
            "providers": counts["providers"],
            "counts_by_kind": dict(sorted(stats["entities_by_kind"].items())),
        })
        return report
    finally:
        graph.close()


def report_to_json(report) -> str:
    return json.dumps(report, indent=2, sort_keys=True)
