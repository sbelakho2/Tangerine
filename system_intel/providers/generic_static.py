"""generic-static provider: the zero-install fallback over ``extract_core``.

This wraps :func:`system_intel.extract_core.extract` (Tier 0/1 filesystem +
lexical extraction) into the §5 SPI.  It is deliberately NOT authoritative:

* entities    complete (analysis_depth <= 1)
* relations   partial (containment complete; imports resolved only when the
              target is derivable from the scanned file set)
* facts       partial (manifest/SQL/config facts; no data-flow)
* tests       partial (test paths / ``@test`` declarations)
* calls       unavailable (no call resolution in the static scanner)
* contracts / ownership / invariants / runtime / history
              unavailable / unknown (never claimed)

Unresolved import targets are NOT dropped: every relation whose target does
not resolve to a known entity stable id is emitted as a first-class
:class:`ProviderUnresolved` entry carrying the typed raw target and the
resolvable candidate stable ids (when computable from the scanned file set).
"""

from __future__ import annotations

from pathlib import Path

from system_intel import extract_core
from system_intel.providers.base import (
    ProviderCapability,
    ProviderEntity,
    ProviderEvidence,
    ProviderFact,
    ProviderRelation,
    ProviderSnapshot,
    ProviderUnresolved,
    normalize_verdict,
)

PROVIDER_ID = "generic-static"
PROVIDER_VERSION = "2.0"

DEFAULT_CAPABILITIES: tuple[ProviderCapability, ...] = (
    ProviderCapability(
        "entities", "complete",
        "Tier 0/1 filesystem + lexical extraction (analysis_depth <= 1)",
    ),
    ProviderCapability(
        "relations", "partial",
        "containment complete; imports resolved only when derivable",
    ),
    ProviderCapability("facts", "partial", "manifest/SQL/config facts; no data-flow"),
    ProviderCapability("tests", "partial", "test paths / @test declarations only"),
    ProviderCapability("calls", "unavailable", "no call resolution in the static scanner"),
    ProviderCapability("contracts", "unavailable", "no contract extraction"),
    ProviderCapability("ownership", "unavailable", "no ownership analysis"),
    ProviderCapability("invariants", "unknown", "not extracted"),
    ProviderCapability("runtime", "unknown", "no runtime data"),
    ProviderCapability("history", "unknown", "no history source"),
)

_MAX_CANDIDATES = 8

_IMPORT_CANDIDATE_SUFFIXES = (
    "",
    ".py",
    "/__init__.py",
    ".js",
    "/index.js",
    ".ts",
    "/index.ts",
    ".rs",
    "/mod.rs",
    ".tg",
)


def _stable_id(record) -> str:
    stable = getattr(record, "stable_id", "") or ""
    if stable:
        return str(stable)
    kind = str(getattr(record, "kind", "") or "")
    qn = str(getattr(record, "qualified_name", "") or "")
    return f"{kind.lower()}:{qn}"


def _candidate_ids(relation, known: set[str]) -> tuple[str, ...]:
    """Resolvable candidate stable ids for an unresolved import target.

    Candidates are exact stable ids present in the scanned entity set (the
    resolver's own evidence); an external dependency with no in-corpus hit
    yields no candidates rather than a guess.
    """
    if str(getattr(relation, "kind", "")) != "imports":
        return ()
    raw = str(
        (getattr(relation, "attrs", None) or {}).get("raw")
        or getattr(relation, "dst_key", "")
        or ""
    ).strip()
    if not raw:
        return ()
    src_key = str(getattr(relation, "src_key", "") or "")
    base_dir = ""
    if src_key.startswith("file:"):
        base_dir = Path(src_key[len("file:"):]).parent.as_posix()
        if base_dir == ".":
            base_dir = ""
    spellings: list[str] = []
    if raw.startswith("."):
        joined = (Path(base_dir) / raw).as_posix() if base_dir else raw
        spellings.append(joined)
    else:
        norm = raw.replace("::", ".").strip(".")
        if norm:
            spellings.append(norm.replace(".", "/"))
            spellings.append(norm)
    out: list[str] = []
    for spelling in spellings:
        for suffix in _IMPORT_CANDIDATE_SUFFIXES:
            candidate = f"file:{spelling}{suffix}"
            if candidate in known and candidate not in out:
                out.append(candidate)
        for module_spelling in (spelling.replace("/", "."), spelling):
            candidate = f"module:{module_spelling}"
            if candidate in known and candidate not in out:
                out.append(candidate)
    return tuple(sorted(out)[:_MAX_CANDIDATES])


class GenericStaticProvider:
    """§5 provider over the stdlib-only static scanner."""

    provider_id = PROVIDER_ID
    provider_version = PROVIDER_VERSION
    authority = 10  # higher number = lower authority (native wins, §5)

    def __init__(self) -> None:
        self._completeness = {
            cap.family: cap.verdict for cap in DEFAULT_CAPABILITIES
        }
        self._last_snapshot: ProviderSnapshot | None = None

    def applies_to(self, root) -> bool:
        return Path(root).is_dir()

    # ------------------------------------------------------------------ SPI

    def identity(self, root) -> dict:
        return {
            "repo_root": str(Path(root).expanduser()),
            "source_revision": "",
            "tree_digest": "",
            "semantic_configuration": "{}",
            "provider": self.provider_id,
            "provider_version": self.provider_version,
        }

    def capabilities(self) -> list[ProviderCapability]:
        return [
            ProviderCapability(cap.family, cap.verdict, cap.note)
            for cap in DEFAULT_CAPABILITIES
        ]

    def snapshot(self, root, *, commit_sha: str | None = None) -> ProviderSnapshot:
        root_path = Path(root).expanduser()
        try:
            extraction = extract_core.extract(root_path, commit_sha=commit_sha)
        except Exception as exc:  # noqa: BLE001 - fallback never crashes a scan
            snap = ProviderSnapshot(
                providers=[{
                    "provider_id": self.provider_id,
                    "provider_version": self.provider_version,
                    "capabilities": {
                        cap.family: "unavailable" for cap in DEFAULT_CAPABILITIES
                    },
                    "invoked": True,
                }],
                provider_id=self.provider_id,
                provider_version=self.provider_version,
                capabilities=[
                    ProviderCapability(cap.family, "unavailable",
                                       f"extraction failed: {exc.__class__.__name__}")
                    for cap in DEFAULT_CAPABILITIES
                ],
                evidence=[ProviderEvidence(
                    kind="provider_error",
                    ref=str(root_path),
                    summary=f"generic-static extraction failed: {exc.__class__.__name__}",
                    payload={"error": str(exc)},
                    provider=self.provider_id,
                )],
            )
            self._completeness = {cap.family: "unavailable" for cap in DEFAULT_CAPABILITIES}
            self._last_snapshot = snap
            return snap

        known: set[str] = set()
        entities: list[ProviderEntity] = []
        for record in extraction.entities:
            stable = _stable_id(record)
            known.add(stable)
            entities.append(ProviderEntity(
                kind=str(record.kind),
                name=str(record.name),
                qualified_name=str(record.qualified_name),
                stable_id=stable,
                file=record.file,
                line=record.line,
                tier=int(record.tier),
                provenance=str(record.provenance),
                confidence=float(record.confidence),
                derived_from=tuple(record.derived_from or ()),
                attrs=dict(record.attrs or {}),
                epistemic_state=str(record.epistemic_state),
                analysis_depth=int(record.analysis_depth),
                completeness=str(record.completeness),
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))

        relations: list[ProviderRelation] = []
        unresolved: list[ProviderUnresolved] = []
        for record in extraction.relations:
            src_key = str(record.src_key or "")
            dst_key = str(record.dst_key or "")
            resolved = bool(
                src_key and src_key in known
                and dst_key and dst_key in known
            )
            if resolved:
                relations.append(ProviderRelation(
                    src_key=src_key,
                    dst_key=dst_key,
                    kind=str(record.kind),
                    src_kind=record.src_kind,
                    dst_kind=record.dst_kind,
                    tier=int(record.tier),
                    provenance=str(record.provenance),
                    confidence=float(record.confidence),
                    derived_from=tuple(record.derived_from or ()),
                    attrs=dict(record.attrs or {}),
                    epistemic_state=str(record.epistemic_state),
                    analysis_depth=int(record.analysis_depth),
                    completeness=str(record.completeness),
                    provider=self.provider_id,
                    provider_revision=self.provider_version,
                ))
            else:
                candidates = _candidate_ids(record, known)
                raw = str((record.attrs or {}).get("raw") or dst_key)
                unresolved.append(ProviderUnresolved(
                    src_key=src_key,
                    dst_raw=raw,
                    kind=str(record.kind),
                    candidates=candidates,
                    confidence=float(record.confidence),
                    completeness=str(record.completeness),
                    attrs={
                        "dst_key": dst_key,
                        "dst_kind": record.dst_kind,
                        "src_kind": record.src_kind,
                        "derived_from": list(record.derived_from or ()),
                    },
                    provider=self.provider_id,
                    provider_revision=self.provider_version,
                ))

        facts: list[ProviderFact] = []
        for record in extraction.facts:
            facts.append(ProviderFact(
                subject=str(record.subject),
                predicate=str(record.predicate),
                object=str(record.object),
                stable_subject=str(record.stable_subject or ""),
                tier=int(record.tier),
                provenance=str(record.provenance),
                confidence=float(record.confidence),
                derived_from=tuple(record.derived_from or ()),
                uncertainty=record.uncertainty,
                epistemic_state=str(record.epistemic_state),
                analysis_depth=int(record.analysis_depth),
                completeness=str(record.completeness),
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))

        capabilities = [
            ProviderCapability(cap.family, cap.verdict, cap.note)
            for cap in DEFAULT_CAPABILITIES
        ]
        snap = ProviderSnapshot(
            entities=entities,
            relations=relations,
            facts=facts,
            unresolved=unresolved,
            evidence=[ProviderEvidence(
                kind="source_scan",
                ref=str(root_path),
                summary=(
                    f"generic-static Tier 0/1 extraction: {len(entities)} "
                    f"entities, {len(relations)} resolved relations, "
                    f"{len(unresolved)} unresolved claims"
                ),
                payload={"commit_sha": commit_sha},
                provider=self.provider_id,
            )],
            providers=[{
                "provider_id": self.provider_id,
                "provider_version": self.provider_version,
                "capabilities": {cap.family: cap.verdict for cap in capabilities},
                "invoked": True,
            }],
            semantic_configuration={},
            provider_id=self.provider_id,
            provider_version=self.provider_version,
            capabilities=capabilities,
        )
        self._completeness = {cap.family: cap.verdict for cap in capabilities}
        self._last_snapshot = snap
        return snap

    def query(self, snapshot: ProviderSnapshot, operation: str, **kwargs) -> dict:
        op = str(operation)
        if op in ("entity", "entity.get", "symbol.get"):
            key = kwargs.get("stable_id") or kwargs.get("key") or kwargs.get("qualified_name")
            records = [
                ent for ent in snapshot.entities
                if key and (
                    ent.stable_id == key
                    or ent.qualified_name == key
                    or ent.name == key
                )
            ]
            return {
                "kind": "entity.get",
                "records": records,
                "completeness": snapshot.completeness("entities"),
            }
        if op == "entities":
            kind = kwargs.get("kind")
            records = [
                ent for ent in snapshot.entities
                if kind is None or ent.kind == kind
            ]
            return {
                "kind": "entities",
                "records": records,
                "completeness": snapshot.completeness("entities"),
            }
        if op in ("search", "symbol_search"):
            needle = str(kwargs.get("query") or kwargs.get("needle") or "")
            records = [
                ent for ent in snapshot.entities
                if not needle or needle in ent.name or needle in ent.qualified_name
            ]
            return {
                "kind": "search",
                "records": records,
                "completeness": snapshot.completeness("entities"),
            }
        if op in ("relations", "edges"):
            kind = kwargs.get("kind")
            records = [
                rel for rel in snapshot.relations
                if kind is None or rel.kind == kind
            ]
            return {
                "kind": "relations",
                "records": records,
                "completeness": snapshot.completeness("relations"),
            }
        if op == "unresolved":
            kind = kwargs.get("kind")
            records = [
                edge for edge in snapshot.unresolved
                if kind is None or edge.kind == kind
            ]
            return {
                "kind": "unresolved",
                "records": records,
                "completeness": snapshot.completeness("relations"),
            }
        return {
            "kind": f"{op}_unavailable",
            "records": [],
            "note": f"generic-static does not answer {op!r}",
            "completeness": "unavailable",
        }

    def delta(self, old_snapshot: ProviderSnapshot,
              new_snapshot: ProviderSnapshot) -> dict:
        return _snapshot_delta(old_snapshot, new_snapshot)

    def completeness(self, family: str) -> str:
        return normalize_verdict(self._completeness.get(str(family), "unknown"))


def _entity_render(entity: ProviderEntity) -> str:
    return "\x1f".join((
        entity.kind, entity.qualified_name, str(entity.provenance),
        str(entity.confidence), str(entity.analysis_depth),
        str(entity.completeness),
    ))


def _unresolved_render(edge: ProviderUnresolved) -> str:
    return "\x1f".join((edge.src_key, edge.kind, edge.dst_raw,
                        ",".join(edge.candidates), str(edge.completeness)))


def _snapshot_delta(old_snapshot: ProviderSnapshot,
                    new_snapshot: ProviderSnapshot) -> dict:
    old_entities = {ent.stable_id: _entity_render(ent) for ent in old_snapshot.entities}
    new_entities = {ent.stable_id: _entity_render(ent) for ent in new_snapshot.entities}
    old_unresolved = {
        (edge.src_key, edge.kind, edge.dst_raw): _unresolved_render(edge)
        for edge in old_snapshot.unresolved
    }
    new_unresolved = {
        (edge.src_key, edge.kind, edge.dst_raw): _unresolved_render(edge)
        for edge in new_snapshot.unresolved
    }
    return {
        "added": sorted(set(new_entities) - set(old_entities)),
        "removed": sorted(set(old_entities) - set(new_entities)),
        "changed": sorted(
            key for key in set(old_entities) & set(new_entities)
            if old_entities[key] != new_entities[key]
        ),
        "unresolved_added": sorted(
            f"{src}\x1f{kind}\x1f{dst}" for (src, kind, dst) in
            set(new_unresolved) - set(old_unresolved)
        ),
    }
