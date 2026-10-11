"""Scan orchestration for system_intel: identity -> providers -> snapshot.

v3 semantics (INTERFACES.md §1/§3, audit P0 federation items):

* Three identity levels are materialized: the level-1 ``source_revision``
  (repository identity + source tree + target/semantic configuration), one
  immutable level-2 ``provider_observation`` per invoked provider, and the
  level-3 federated snapshot = the immutable set of observation ids.
* A normal ``scan`` (``provider=None``) selects providers through the
  registry automatically (native first when applicable, generic-static as
  the zero-install fallback) and federates their snapshots claim-scoped:
  every provider contributes its UNIQUE knowledge (authority is per claim,
  not per provider), while the same typed assertion keeps the
  higher-authority canonical row and accumulates one ``support`` observation
  per provider -- with disagreements preserved, never overwritten.
* Providers run BEFORE final snapshot identity: the primary snapshot's
  semantic configuration (target/features/options) and its content digest
  participate in the revision identity, so recompiling the same source under
  a different target, or collecting a new runtime/verification observation,
  produces a NEW federated revision instead of a silent reuse.
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
import os
import stat
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
    observation_set_digest,
)
from system_intel.providers.generic_static import GenericStaticProvider

GENERIC_CAPABILITIES = {
    "entities": "complete",
    "relations": "partial",
    "calls": "unavailable",
    "runtime": "unknown",
    "tests": "partial",
}

FALLBACK_PROVIDER = (EXTRACTOR_PROVIDER_ID, EXTRACTOR_PROVIDER_VERSION)

# Files/directories that are OUTPUTS of a scan and must never participate in
# the repository tree digest (the DB can live inside the scanned root).
_DIGEST_DEFAULT_EXCLUDES = ("build/tg_semantic.jsonl",)


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


def _tree_digest(root: Path, exclude=()) -> str:
    """sha256 over the canonical (relpath,size,mode,content-digest) manifest.

    Symlinks are recorded by their TARGET STRING (never followed): a link
    can never pull content from outside the root into the digest.  Output
    paths (the active DB and its journal files) are excluded so a scan can
    never contaminate its own repository identity.
    """
    excluded = {str(Path(p).expanduser().resolve()) for p in exclude if p}
    entries = []
    for path in iter_files(root):
        try:
            rel = path.relative_to(root).as_posix()
        except ValueError:
            continue
        try:
            if str(path.resolve()) in excluded:
                continue
        except OSError:
            pass
        try:
            st = path.lstat()
            mode = int(st.st_mode) & 0o777
            if stat.S_ISLNK(st.st_mode):
                try:
                    target = os.readlink(path)
                except OSError:
                    target = "?"
                entries.append((rel, len(target), mode, "#symlink:" + target))
                continue
            data = path.read_bytes()
            content = hashlib.sha256(data).hexdigest()
            entries.append((rel, int(st.st_size), mode, content))
        except OSError:
            entries.append((rel, -1, -1, "#unreadable"))
    digest = hashlib.sha256()
    for rel, size, mode, content in sorted(entries):
        digest.update(f"{rel}\x00{size}\x00{mode}\x00{content}\n".encode("utf-8"))
    return digest.hexdigest()


def _provider_pairs(providers) -> list[tuple[str, str]]:
    pairs = []
    for provider in providers:
        if isinstance(provider, (tuple, list)):
            pairs.append((str(provider[0]), str(provider[1])))
        else:
            pairs.append((
                str(getattr(provider, "provider_id", "") or ""),
                str(getattr(provider, "provider_version", "") or ""),
            ))
    return pairs


def _provider_set_digest(providers) -> str:
    pairs = sorted(_provider_pairs(providers))
    return hashlib.sha256(_canonical(pairs).encode("utf-8")).hexdigest()


def _identity(root, *, commit_sha=None, strict_clean=False, providers=(),
               semantic_configuration=None, repo_root=None,
               observation_digest="", target="", source_revision_id=None,
               exclude_paths=()) -> dict:
    """Compute the §1/v3 revision identity for a scan root.

    ``providers`` is a sequence of provider instances or
    ``(provider_id, provider_version)`` pairs.  ``semantic_configuration``
    may be a dict (canonicalized) or a string.  ``observation_digest`` is
    the content-derived federated observation-set digest (level 3).
    """
    root_path = Path(root).expanduser().resolve()
    exclude = []
    for hint in tuple(exclude_paths):
        if not hint:
            continue
        exclude.append(hint)
        text = str(hint)
        if text.endswith((".db", ".sqlite", ".sqlite3")):
            exclude.append(text + "-wal")
            exclude.append(text + "-shm")
            exclude.append(text + "-journal")
    tree = _tree_digest(root_path, exclude=exclude)
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
        semantic = semantic_configuration or "{}"
    else:
        semantic = _canonical(semantic_configuration)

    identity = {
        "repo_root": str(Path(repo_root).resolve()) if repo_root else str(root_path),
        "repo_identity": repo_identity,
        "source_revision": revision,
        "tree_digest": tree,
        "semantic_configuration": semantic,
        "provider_set_digest": _provider_set_digest(providers),
        "observation_set_digest": str(observation_digest or ""),
        "target": str(target or ""),
    }
    if source_revision_id is not None:
        identity["source_revision_id"] = int(source_revision_id)
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
    return _provider_pairs([provider])


# ── provider federation ──────────────────────────────────────────────────


def _select_providers(root_path: Path, provider) -> list:
    """Explicit provider wins; otherwise registry selection (native first)."""
    if provider is not None:
        return [provider]
    from system_intel.providers.registry import select_for

    selected = list(select_for(root_path))
    if not selected:
        selected = [GenericStaticProvider()]
    return selected


def _invoke_provider(provider, root_path: Path, commit_sha):
    """Run one provider.

    An expected-unavailable state is a DEGRADED snapshot (the SPI's
    contract); an exception or a missing snapshot is a provider FAULT and
    propagates, so a broken provider can never be silently replaced by a
    lower-authority fallback.
    """
    snap = provider.snapshot(root_path, commit_sha=commit_sha)
    if snap is None:
        raise SnapshotError(
            f"provider {getattr(provider, 'provider_id', '?')} returned no snapshot"
        )
    return snap, ""


def _snapshot_usable(snap) -> bool:
    if snap is None:
        return False
    if isinstance(snap, dict):
        return any(key in snap for key in ("entities", "relations", "facts", "unresolved"))
    entities = list(getattr(snap, "entities", ()) or ())
    if entities:
        return True
    caps = list(getattr(snap, "capabilities", ()) or ())
    if caps:
        for cap in caps:
            if getattr(cap, "family", "") == "entities":
                return str(getattr(cap, "verdict", "unknown")) in ("complete", "partial")
        return False
    # Legacy extraction objects carry entities/relations with no capability list.
    return hasattr(snap, "entities") and hasattr(snap, "relations")


def _snapshot_capabilities(snap) -> dict:
    """Capability dict from a ProviderSnapshot, a dict snapshot, or legacy."""
    if isinstance(snap, dict):
        caps = _capabilities_dict(_field(snap, "capabilities", None))
        if caps:
            return caps
        for desc in _as_list(_field(snap, "providers", [])):
            merged = _capabilities_dict(_field(desc, "capabilities", None))
            for key, value in merged.items():
                caps.setdefault(key, value)
        return caps
    capability_record = getattr(snap, "capability_record", None)
    if callable(capability_record):
        try:
            return dict(capability_record())
        except Exception:  # noqa: BLE001 - duck-typed snapshot
            pass
    return _capabilities_dict(getattr(snap, "capabilities", None))


# Keys that are transport/transient plumbing inside a provider snapshot and
# must not participate in the observation digest (cache paths, log paths).
_TRANSIENT_OBSERVATION_KEYS = frozenset({
    "cache", "cache_path", "log_path", "tmp_path", "artifact_path",
    "server_log", "compile_log", "stderr", "stdout",
})


def _canonical_observation(value):
    """Canonical, order-independent view of EVERY observation field.

    The whole ProviderSnapshot is hashed — confidence, completeness,
    attributes, evidence payload/summary, derived_from, uncertainty,
    capabilities and semantic configuration included.  Only explicitly
    transient plumbing keys are excluded; there is no hand-picked subset.
    """
    if hasattr(value, "__dataclass_fields__") and not isinstance(value, type):
        return {
            name: _canonical_observation(getattr(value, name))
            for name in value.__dataclass_fields__
        }
    if isinstance(value, dict):
        return {
            str(key): _canonical_observation(item)
            for key, item in sorted(value.items(), key=lambda kv: str(kv[0]))
            if str(key) not in _TRANSIENT_OBSERVATION_KEYS
        }
    if isinstance(value, (list, tuple, set, frozenset)):
        items = [_canonical_observation(item) for item in value]
        return sorted(items, key=lambda item: _canonical(item))
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


def _snapshot_observation_payload(pid: str, version: str, snap) -> dict:
    """The complete canonical snapshot body plus provider identity."""
    if hasattr(snap, "__dataclass_fields__") and not isinstance(snap, type):
        body = _canonical_observation(snap)
    elif isinstance(snap, dict):
        body = _canonical_observation(snap)
    else:
        attrs = {}
        for name in dir(snap):
            if name.startswith("_"):
                continue
            try:
                value = getattr(snap, name)
            except Exception:  # noqa: BLE001 - duck-typed legacy object
                continue
            if callable(value):
                continue
            attrs[name] = value
        body = _canonical_observation(attrs)
    if isinstance(body, dict):
        body["provider_id"] = str(pid)
        body["provider_version"] = str(version)
    return body


def _snapshot_digest(pid: str, version: str, snap) -> str:
    """Content-derived observation digest (never a DB row id).

    Hashes the canonical COMPLETE ProviderSnapshot, so a provider cannot
    change confidence, completeness, attributes, evidence payload/summary
    or any other meaningful metadata without changing the digest.
    """
    payload = _snapshot_observation_payload(pid, version, snap)
    return hashlib.sha256(_canonical(payload).encode("utf-8")).hexdigest()


def _observation_kind_for(provider) -> str:
    kind = str(getattr(provider, "observation_kind", "") or "")
    return kind if kind in ("static", "runtime", "verification", "history") else "static"


def _authority_for(provider) -> str:
    try:
        authority = int(getattr(provider, "authority", 100))
    except (TypeError, ValueError):
        authority = 100
    if authority <= 0:
        return "native"
    if authority < 100:
        return "compiler"
    return "fallback"


# ── projection ───────────────────────────────────────────────────────────


def _project_snapshot(graph: Graph, snapshot_id: int, snap, pid: str, ver: str,
                      *, canonical: bool) -> dict:
    """Project one provider snapshot into the draft (claim-scoped authority).

    Federation is claim/family-scoped, not winner-takes-all: providers are
    projected in authority order (the primary first) and EVERY provider
    contributes its unique knowledge.  On the same typed assertion:

    * identical claim   -> the canonical row stays + one support observation
    * conflicting claim -> the higher-authority (earlier) row stays canonical
      and the disagreement is preserved in the support detail
    * unique claim      -> included with its own provider authority and
      completeness

    ``canonical`` marks the primary provider (first in authority order); it
    only affects execution order, never whether a unique claim is written.
    """
    evidence_records: list = []
    if _field(snap, "entities", None) is None:
        result = snap  # legacy extraction result (facts/relations/entities lists)
        entities_in = list(_field(result, "entities", []))
        relations_in = list(_field(result, "relations", []))
        facts_in = list(_field(result, "facts", []))
    else:
        entities_in = _as_list(_field(snap, "entities", []))
        relations_in = _as_list(_field(snap, "relations", []))
        facts_in = _as_list(_field(snap, "facts", []))
        evidence_records = _as_list(_field(snap, "evidence", []))
        # Typed-but-unresolved claims are first-class relations too (P0-5).
        relations_in = relations_in + _as_list(_field(snap, "unresolved", []))

    entities = _dedupe_entities(entities_in)

    ids_by_stable: dict[str, int] = {}
    ids_by_typed: dict[tuple[str, str], int] = {}
    stable_by_qn: dict[str, str] = {}
    counts_by_kind: dict[str, int] = {}
    support_rows = 0
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
        ent_provider = str(_field(ent, "provider", pid) or pid)
        ent_revision = str(_field(ent, "provider_revision", ver) or ver)
        existing = ids_by_typed.get((kind, stable))
        existing_row = None
        if existing is None and graph is not None:
            existing_row = graph._require_conn().execute(
                "SELECT * FROM entity WHERE snapshot_id=? AND kind=? AND stable_id=?",
                (int(snapshot_id), kind, stable),
            ).fetchone()
            existing = int(existing_row["id"]) if existing_row is not None else None
        if existing is not None:
            entity_id = existing
        else:
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
            counts_by_kind[kind] = counts_by_kind.get(kind, 0) + 1
        ids_by_stable.setdefault(stable, entity_id)
        ids_by_typed.setdefault((kind, stable), entity_id)
        stable_by_qn.setdefault(qn, stable)
        stable_by_qn.setdefault(stable, stable)
        if graph is not None:
            detail = str(_field(ent, "completeness", "") or "support")
            if existing_row is not None:
                # A second provider asserts the same typed entity: keep the
                # canonical row and PRESERVE any disagreement.
                incoming = {
                    "name": name,
                    "qualified_name": qn,
                    "file": _field(ent, "file", None),
                    "line": _field(ent, "line", None),
                    "provenance": str(_field(ent, "provenance", "observed") or "observed"),
                    "confidence": float(_field(ent, "confidence", 1.0) or 1.0),
                    "completeness": str(_field(ent, "completeness", "partial") or "partial"),
                    "attrs": _field(ent, "attrs", None) or {},
                }
                stored = {
                    "name": existing_row["name"],
                    "qualified_name": existing_row["qualified_name"],
                    "file": existing_row["file"],
                    "line": existing_row["line"],
                    "provenance": existing_row["provenance"],
                    "confidence": existing_row["confidence"],
                    "completeness": existing_row["completeness"],
                    "attrs": json.loads(existing_row["attrs"] or "{}"),
                }
                mismatch = {
                    key: {"canonical": stored[key], "other": value}
                    for key, value in incoming.items()
                    if key in stored and stored[key] != value
                }
                detail = ("conflict:" + _canonical(mismatch)) if mismatch else "support"
            graph.accumulate_support(
                snapshot_id, "entity", entity_id,
                provider=ent_provider, provider_revision=ent_revision,
                confidence=_field(ent, "confidence", 1.0) or 1.0,
                detail=detail,
            )
            support_rows += 1

    def _resolve(key, kind):
        """Resolve a typed endpoint key, including entities an EARLIER
        provider projected into the same draft (claim-scoped federation)."""
        if key in (None, ""):
            return None
        key = str(key)
        conn = graph._require_conn() if graph is not None else None
        if kind:
            typed = (str(kind), key)
            hit = ids_by_typed.get(typed)
            if hit is not None:
                return hit
            if conn is not None:
                row = conn.execute(
                    "SELECT id FROM entity WHERE snapshot_id=? AND kind=? AND stable_id=?",
                    (int(snapshot_id), str(kind), key),
                ).fetchone()
                if row is not None:
                    entity_id = int(row["id"])
                    ids_by_typed[typed] = entity_id
                    ids_by_stable.setdefault(key, entity_id)
                    return entity_id
            return None
        hit = ids_by_stable.get(key)
        if hit is not None:
            return hit
        if conn is not None:
            row = conn.execute(
                "SELECT id FROM entity WHERE snapshot_id=? AND stable_id=? LIMIT 1",
                (int(snapshot_id), key),
            ).fetchone()
            if row is not None:
                entity_id = int(row["id"])
                ids_by_stable[key] = entity_id
                return entity_id
        return None

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
        rel_provider = str(_field(rel, "provider", pid) or pid)
        rel_revision = str(_field(rel, "provider_revision", ver) or ver)
        rel_attrs = _field(rel, "attrs", None) or {}
        site_completeness = None
        target_completeness = None
        if isinstance(rel_attrs, dict):
            site_completeness = rel_attrs.get("site_completeness")
            target_completeness = rel_attrs.get("target_resolution_completeness")

        if src_id is None:
            # Source itself is unknown: preserve as an unresolved edge only
            # (a relation row needs a real src_id).
            relations_unresolved += 1
            if graph is not None:
                graph.add_unresolved_edge(
                    snapshot_id, src_key or "", str(dst_key or ""), rkind,
                    provider=rel_provider, provider_revision=rel_revision,
                    candidates=candidates or [],
                    confidence=_field(rel, "confidence", 0.3) or 0.3,
                    completeness=str(_field(rel, "completeness", "unknown") or "unknown"),
                )
            unresolved_edges += 1
            continue

        # Claim-scoped federation: an edge already asserted by a
        # higher-authority provider keeps its canonical row (disagreement is
        # preserved in the support detail); a UNIQUE edge is written with
        # this provider's own authority and completeness.
        if dst_id is not None:
            stored_edge = graph._require_conn().execute(
                "SELECT * FROM relation WHERE snapshot_id=? AND src_id=? AND dst_id=? AND kind=?",
                (int(snapshot_id), int(src_id), int(dst_id), rkind),
            ).fetchone()
        else:
            stored_edge = graph._require_conn().execute(
                "SELECT * FROM relation WHERE snapshot_id=? AND src_id=? AND dst_id IS NULL "
                "AND dst_key=? AND kind=?",
                (int(snapshot_id), int(src_id), str(dst_key or ""), rkind),
            ).fetchone()
        if stored_edge is not None:
            mismatch = {}
            incoming_completeness = str(_field(rel, "completeness", "partial") or "partial")
            if str(stored_edge["completeness"]) != incoming_completeness:
                mismatch["completeness"] = {
                    "canonical": str(stored_edge["completeness"]),
                    "other": incoming_completeness,
                }
            incoming_confidence = float(_field(rel, "confidence", 1.0) or 1.0)
            if float(stored_edge["confidence"]) != incoming_confidence:
                mismatch["confidence"] = {
                    "canonical": float(stored_edge["confidence"]),
                    "other": incoming_confidence,
                }
            if dst_id is None:
                graph.add_unresolved_edge(
                    snapshot_id, str(src_key or ""), str(dst_key or ""), rkind,
                    provider=rel_provider, provider_revision=rel_revision,
                    candidates=candidates or [],
                    confidence=_field(rel, "confidence", 0.3) or 0.3,
                    completeness=str(_field(rel, "completeness", "unknown") or "unknown"),
                )
                unresolved_edges += 1
                relations_unresolved += 1
            graph.accumulate_support(
                snapshot_id, "relation", int(stored_edge["id"]),
                provider=rel_provider, provider_revision=rel_revision,
                confidence=incoming_confidence,
                detail=("conflict:" + _canonical(mismatch)) if mismatch else "support",
            )
            support_rows += 1
            continue

        common = dict(
            snapshot_id=snapshot_id,
            tier=_field(rel, "tier", 1) or 0,
            provenance=_field(rel, "provenance", "inferred") or "inferred",
            confidence=_field(rel, "confidence", 1.0),
            derived_from=_as_list(_field(rel, "derived_from", ())),
            attrs=rel_attrs,
            src_key=str(src_key or ""),
            epistemic_state=_field(rel, "epistemic_state", None),
            analysis_depth=_field(rel, "analysis_depth", None),
            completeness=_field(rel, "completeness", None),
            site_completeness=site_completeness,
            target_resolution_completeness=target_completeness,
            provider=rel_provider,
            provider_revision=rel_revision,
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
            rel_id = graph.upsert_relation(
                src_id, None, rkind, dst_key=str(dst_key or ""), resolved=0, **common
            )
        else:
            rel_id = graph.upsert_relation(src_id, dst_id, rkind, **common)
            relations_upserted += 1
        graph.accumulate_support(
            snapshot_id, "relation", rel_id,
            provider=rel_provider, provider_revision=rel_revision,
            confidence=_field(rel, "confidence", 1.0) or 1.0,
            detail=str(_field(rel, "completeness", "") or ""),
        )
        support_rows += 1

    facts_upserted = 0
    for fact in facts_in:
        subject = str(_field(fact, "subject", "") or "")
        stable_subject = _field(fact, "stable_subject", None)
        if not stable_subject:
            stable_subject = stable_by_qn.get(subject, subject)
        fact_provider = str(_field(fact, "provider", pid) or pid)
        fact_revision = str(_field(fact, "provider_revision", ver) or ver)
        existing = graph._require_conn().execute(
            "SELECT * FROM fact WHERE snapshot_id=? AND subject=? AND predicate=? AND object=?",
            (int(snapshot_id), subject, str(_field(fact, "predicate", "") or ""),
             str(_field(fact, "object", "") or "")),
        ).fetchone()
        if existing is not None:
            # Same assertion from another provider: support the canonical
            # row and preserve any disagreement; a unique fact is written
            # below with its own provider/authority.
            mismatch = {}
            incoming_completeness = str(_field(fact, "completeness", "partial") or "partial")
            if str(existing["completeness"]) != incoming_completeness:
                mismatch["completeness"] = {
                    "canonical": str(existing["completeness"]),
                    "other": incoming_completeness,
                }
            incoming_confidence = float(_field(fact, "confidence", 1.0) or 1.0)
            if float(existing["confidence"]) != incoming_confidence:
                mismatch["confidence"] = {
                    "canonical": float(existing["confidence"]),
                    "other": incoming_confidence,
                }
            graph.accumulate_support(
                snapshot_id, "fact", int(existing["id"]),
                provider=fact_provider, provider_revision=fact_revision,
                confidence=incoming_confidence,
                detail=("conflict:" + _canonical(mismatch)) if mismatch else "support",
            )
            support_rows += 1
            continue
        fact_id = graph.upsert_fact(
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
            provider=fact_provider,
            provider_revision=fact_revision,
            stable_subject=str(stable_subject or ""),
        )
        facts_upserted += 1
        graph.accumulate_support(
            snapshot_id, "fact", fact_id,
            provider=fact_provider, provider_revision=fact_revision,
            confidence=_field(fact, "confidence", 1.0) or 1.0,
            detail=str(_field(fact, "completeness", "") or ""),
        )
        support_rows += 1

    for ev in evidence_records:
        graph.add_evidence(
            snapshot_id,
            str(_field(ev, "kind", "unknown") or "unknown"),
            str(_field(ev, "ref", "") or ""),
            digest=_field(ev, "digest", None),
            summary=str(_field(ev, "summary", "") or ""),
            payload=_field(ev, "payload", None),
            provider=str(_field(ev, "provider", pid) or pid),
        )

    return {
        "entities": len(entities) if canonical else 0,
        "relations": relations_upserted,
        "relations_unresolved": relations_unresolved,
        "facts": facts_upserted,
        "unresolved_edges": unresolved_edges,
        "evidence": len(evidence_records),
        "support": support_rows,
        "counts_by_kind": counts_by_kind,
    }


def _project(graph: Graph, snapshot_id: int, root_path: Path, provider,
             commit_sha) -> dict:
    """Legacy single-provider projection (kept for embedding callers)."""
    if provider is None:
        provider = GenericStaticProvider()
        pid, ver = EXTRACTOR_PROVIDER_ID, EXTRACTOR_PROVIDER_VERSION
    else:
        pid = str(_field(provider, "provider_id", "") or "unknown-provider")
        ver = str(_field(provider, "provider_version", "") or "")
    snap, _note = _invoke_provider(provider, root_path, commit_sha)
    if snap is None:
        raise SnapshotError(f"provider {pid!r} returned no snapshot for {root_path}")
    return _project_snapshot(graph, snapshot_id, snap, pid, ver, canonical=True)


# ── scan ─────────────────────────────────────────────────────────────────


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
            "observation_set_digest": identity.get("observation_set_digest", ""),
            "revision_digest": identity["revision_digest"],
        },
        "source_revision_id": snapshot_row.get("source_revision_id"),
        "revision_digest": identity["revision_digest"],
        "observations": [
            {
                "provider": obs["provider"],
                "provider_version": obs["provider_version"],
                "observation_kind": obs["observation_kind"],
                "observation_digest": obs["observation_digest"],
                "authority": obs["authority"],
                "enumeration_completeness": obs["enumeration_completeness"],
                "resolution_completeness": obs["resolution_completeness"],
            }
            for obs in graph.observations(int(snapshot_row["id"]))
        ],
        "stale_entities": 0,
        "stale_relations": 0,
        "completeness": graph.completeness(int(snapshot_row["id"])),
        "duration_ms": int((time.monotonic() - started) * 1000),
        "db_path": str(db_path),
    }


def scan(root, db_path, *, commit_sha=None, repo_root=None, strict_clean=False,
         provider=None, semantic_configuration=None, observation_kind=None):
    """Federate providers over `root` into the graph at `db_path`.

    Idempotent per federated revision tuple: re-scanning an unchanged tree
    with the same provider set AND the same provider observations returns the
    existing finalized snapshot with ``reused=True`` and performs no snapshot
    writes.  A NEW observation (runtime/verification/history) changes the
    observation-set digest and therefore produces a fresh federated revision.
    """
    started = time.monotonic()
    root_path = Path(root).expanduser().resolve()
    if not root_path.is_dir():
        raise NotADirectoryError(str(root_path))

    selected = _select_providers(root_path, provider)
    # The graph opens FIRST: a provider fault must leave an (empty) database
    # behind, never a partially written snapshot (P0-4).
    graph = Graph.open(db_path)
    try:
        provider_pairs = _provider_pairs(selected)

        invoked: list[tuple] = []  # (provider, snapshot|None, note)
        for candidate in selected:
            snap, note = _invoke_provider(candidate, root_path, commit_sha)
            invoked.append((candidate, snap, note))

        usable = [(p, s) for (p, s, _note) in invoked if _snapshot_usable(s)]
        if not usable:
            fallback = GenericStaticProvider()
            snap, note = _invoke_provider(fallback, root_path, commit_sha)
            if snap is None or not _snapshot_usable(snap):
                raise SnapshotError(
                    f"no provider produced a usable snapshot for {root_path}: {note}"
                )
            usable = [(fallback, snap)]
            if not any(str(getattr(p, "provider_id", "")) == fallback.provider_id
                       for p in selected):
                selected = selected + [fallback]

        primary_provider, primary_snap = usable[0]

        # Semantic configuration and observation digests participate in the
        # snapshot identity (providers ran BEFORE identity selection).
        if semantic_configuration is None:
            config = _field(primary_snap, "semantic_configuration", None) or {}
            semantic_text = (
                _canonical(config) if isinstance(config, dict) and config else "{}"
            )
        elif isinstance(semantic_configuration, str):
            semantic_text = semantic_configuration or "{}"
        else:
            semantic_text = _canonical(semantic_configuration)
        target = ""
        try:
            parsed = json.loads(semantic_text)
            if isinstance(parsed, dict):
                target = str(parsed.get("target", "") or "")
        except (TypeError, ValueError):
            target = ""

        obs_entries = []
        for prov, snap in usable:
            pid = str(getattr(prov, "provider_id", "") or "unknown-provider")
            ver = str(getattr(prov, "provider_version", "") or "")
            obs_entries.append({
                "provider": prov,
                "snapshot": snap,
                "provider_id": pid,
                "provider_version": ver,
                "observation_kind": observation_kind or _observation_kind_for(prov),
                "observation_digest": _snapshot_digest(pid, ver, snap),
                "authority": _authority_for(prov),
                "enumeration_completeness": str(_field(snap, "completeness_entities", None)
                                                or _snap_family_verdict(snap, "entities")),
                "resolution_completeness": str(_field(snap, "completeness_relations", None)
                                               or _snap_family_verdict(snap, "relations")),
                "scope": {"provider": pid},
            })
        obs_digest = observation_set_digest([e["observation_digest"] for e in obs_entries])

        pinned_root = str(Path(repo_root).resolve()) if repo_root else str(root_path)
        db_hint = str(Path(db_path).expanduser().resolve()) if db_path != ":memory:" else None
        identity = _identity(
            root_path,
            commit_sha=commit_sha,
            strict_clean=strict_clean,
            providers=provider_pairs,
            semantic_configuration=semantic_text,
            repo_root=pinned_root,
            observation_digest=obs_digest,
            target=target,
            exclude_paths=(db_hint,) if db_hint else (),
        )

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
                "support": stats["support"],
                "providers": stats["providers"],
                "counts_by_kind": dict(stats["entities_by_kind"]),
            })
            return report

        source_revision_id = graph.upsert_source_revision(identity)
        observation_ids = []
        for entry in obs_entries:
            observation_ids.append(graph.add_provider_observation(
                source_revision_id,
                entry["provider_id"],
                provider_version=entry["provider_version"],
                observation_kind=entry["observation_kind"],
                observation_digest=entry["observation_digest"],
                scope=entry["scope"],
                semantic_configuration=semantic_text,
                authority=entry["authority"],
                enumeration_completeness=entry["enumeration_completeness"],
                resolution_completeness=entry["resolution_completeness"],
            ))
        identity["source_revision_id"] = source_revision_id
        identity["observation_ids"] = observation_ids

        counts = None
        snapshot_id = None
        with graph.batch():
            if existing is not None:
                graph.abort_draft(int(existing["id"]))
            snapshot_id = graph.begin_draft({**identity, "repo_root": pinned_root})
            # Canonical rows from the primary provider, support from all.
            counts = _project_snapshot(
                graph, snapshot_id, primary_snap,
                str(getattr(primary_provider, "provider_id", "") or ""),
                str(getattr(primary_provider, "provider_version", "") or ""),
                canonical=True,
            )
            for entry in obs_entries:
                if entry["provider"] is primary_provider:
                    continue
                _project_snapshot(
                    graph, snapshot_id, entry["snapshot"],
                    entry["provider_id"], entry["provider_version"],
                    canonical=False,
                )
            # provider_record for EVERY selected provider (invoked flag
            # distinguishes a degraded/unavailable provider honestly).
            invoked_ids = {}
            for (prov, snap, note) in invoked:
                pid = str(getattr(prov, "provider_id", "") or "unknown-provider")
                invoked_ids[pid] = (snap, note)
            for entry in obs_entries:
                pid = entry["provider_id"]
                invoked_ids.pop(pid, None)
                graph.record_provider(
                    snapshot_id, pid, entry["provider_version"],
                    _snapshot_capabilities(entry["snapshot"]),
                    invoked=True,
                    scope=entry["scope"],
                    authority=entry["authority"],
                )
            for pid, (snap, note) in invoked_ids.items():
                prov = next((p for p in selected
                             if str(getattr(p, "provider_id", "")) == pid), None)
                caps = {}
                if snap is not None:
                    caps = _snapshot_capabilities(snap)
                elif prov is not None:
                    caps = _capabilities_dict(_field(prov, "capabilities", None))
                graph.record_provider(
                    snapshot_id, pid,
                    str(getattr(prov, "provider_version", "") or ""),
                    caps, invoked=True, scope={"provider": pid},
                    authority=_authority_for(prov) if prov is not None else "fallback",
                )
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
            "support": stats["support"],
            "providers": sorted({str(getattr(p, "provider_id", "") or "")
                                 for p in selected}),
            "counts_by_kind": dict(sorted(stats["entities_by_kind"].items())),
        })
        return report
    finally:
        graph.close()


def _snap_family_verdict(snap, family: str) -> str:
    caps = _snapshot_capabilities(snap)
    if family in caps:
        return str(caps[family])
    try:
        return str(snap.completeness(family))
    except Exception:  # noqa: BLE001 - duck-typed legacy snapshots
        return "unknown"


def report_to_json(report) -> str:
    return json.dumps(report, indent=2, sort_keys=True)
