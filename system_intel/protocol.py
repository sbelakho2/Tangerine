"""Neutral System Intelligence Protocol v2 (export side).

This module is documented independently of Tangerine internals: a consumer
needs only `PROTOCOL.md`, never the SQLite schema or this package's code.

v2 changes over v1 (stop-ship review):
- stable record IDs (`<Kind>:<stable_id>`), never SQLite row integers;
- the envelope binds ONE deterministic finalized snapshot (identity tuple +
  revision digest), a provider set with per-family capabilities, and
  explicit completeness verdicts — never records from multiple revisions;
- every record carries epistemic_state / analysis_depth / completeness /
  confidence{value,basis} / provenance / provider identity;
- relations carry TYPED endpoint keys and a resolved flag; unresolved edges
  export as first-class `UnresolvedClaim` records (raw target, candidates,
  evidence) instead of silently vanishing;
- evidence is referenced, not synthesized; counterexamples link claims to
  evidence; runtime provenance maps to observed/depth-4, never inferred.

`system_intel.ingest` is the symmetric ingest side.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone

PROTOCOL_VERSION = 2

# The knowledge states every record may carry (shared vocabulary).
STATES = (
    "observed",
    "declared",
    "inferred",
    "historically_supported",
    "uncertain",
    "contradicted",
)

COMPLETENESS = ("complete", "partial", "unavailable", "unknown")


@dataclass
class Confidence:
    value: float = 1.0
    basis: list[str] = field(default_factory=list)


@dataclass
class Provenance:
    kind: str = "source_scan"
    provider: str = ""
    provider_version: str = ""
    derived_from: list[str] = field(default_factory=list)
    last_verified: str | None = None
    uncertainty: str | None = None


@dataclass
class EvidenceRef:
    id: str
    digest: str | None = None
    ref: str | None = None


@dataclass
class Epistemics:
    epistemic_state: str = "observed"
    analysis_depth: int = 0
    completeness: str = "partial"


@dataclass
class Requirement:
    id: str
    statement: str
    status: str = "unknown"  # open | met | unknown
    refs: list[str] = field(default_factory=list)


@dataclass
class Fact:
    id: str
    stable_id: str
    subject: str
    predicate: str
    object: str
    epistemics: Epistemics = field(default_factory=Epistemics)
    confidence: Confidence = field(default_factory=Confidence)
    provenance: Provenance = field(default_factory=Provenance)
    evidence: list[EvidenceRef] = field(default_factory=list)


@dataclass
class Claim:
    id: str
    stable_id: str
    text: str
    epistemics: Epistemics = field(default_factory=Epistemics)
    confidence: Confidence = field(default_factory=Confidence)
    provenance: Provenance = field(default_factory=Provenance)
    evidence: list[EvidenceRef] = field(default_factory=list)


@dataclass
class Invariant:
    id: str
    stable_id: str
    statement: str
    component: str | None = None
    epistemics: Epistemics = field(default_factory=Epistemics)
    confidence: Confidence = field(default_factory=Confidence)
    provenance: Provenance = field(default_factory=Provenance)


@dataclass
class Contract:
    id: str
    stable_id: str
    kind: str = ""
    name: str = ""
    component: str | None = None
    format: str | None = None
    epistemics: Epistemics = field(default_factory=Epistemics)
    confidence: Confidence = field(default_factory=Confidence)
    provenance: Provenance = field(default_factory=Provenance)


@dataclass
class Risk:
    id: str
    stable_id: str
    description: str
    component: str | None = None
    epistemics: Epistemics = field(default_factory=Epistemics)
    evidence: list[EvidenceRef] = field(default_factory=list)
    confidence: Confidence = field(default_factory=Confidence)
    provenance: Provenance = field(default_factory=Provenance)


@dataclass
class Change:
    id: str
    stable_id: str
    commit_sha: str | None
    summary: str
    files: list[str] = field(default_factory=list)
    outcome: str | None = None
    epistemics: Epistemics = field(default_factory=Epistemics)
    confidence: Confidence = field(default_factory=Confidence)
    provenance: Provenance = field(default_factory=Provenance)


@dataclass
class Evidence:
    id: str
    kind: str
    ref: str
    digest: str | None = None
    summary: str = ""
    provider: str = ""
    epistemics: Epistemics = field(default_factory=Epistemics)


@dataclass
class Counterexample:
    id: str
    claim_id: str
    description: str
    evidence: list[EvidenceRef] = field(default_factory=list)
    epistemics: Epistemics = field(
        default_factory=lambda: Epistemics("contradicted", 0, "complete")
    )


@dataclass
class UnresolvedClaim:
    """An observed edge whose target could not be resolved.

    First-class by design: "we do not know" is knowledge, and must never be
    indistinguishable from "nothing depends on this".
    """

    id: str
    stable_id: str
    src_key: str
    raw_target: str
    kind: str
    candidates: list[str] = field(default_factory=list)
    completeness: str = "unknown"
    confidence: Confidence = field(default_factory=lambda: Confidence(0.3, []))
    provenance: Provenance = field(default_factory=Provenance)
    evidence: list[EvidenceRef] = field(default_factory=list)


@dataclass
class Relationship:
    id: str
    stable_id: str
    src_key: str
    dst_key: str
    kind: str
    resolved: bool = True
    epistemics: Epistemics = field(default_factory=Epistemics)
    confidence: Confidence = field(default_factory=Confidence)
    provenance: Provenance = field(default_factory=Provenance)


@dataclass
class ProviderRecord:
    id: str
    provider: str
    version: str
    capabilities: dict = field(default_factory=dict)
    invoked: bool = True


def _derived_list(value) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError:
            return [value]
        return list(parsed) if isinstance(parsed, list) else [str(parsed)]
    return list(value)


def _confidence(row: dict) -> Confidence:
    try:
        value = float(row.get("confidence", 1.0))
    except (TypeError, ValueError):
        value = 1.0
    return Confidence(value=max(0.0, min(1.0, value)), basis=_derived_list(row.get("derived_from")))


def _provenance(row: dict, provider: str = "", version: str = "") -> Provenance:
    kind = row.get("provenance") or "source_scan"
    if kind in ("runtime", "runtime_trace"):
        kind = "runtime_trace"
    return Provenance(
        kind=kind,
        provider=provider or row.get("provider") or "",
        provider_version=version or row.get("provider_revision") or "",
        derived_from=_derived_list(row.get("derived_from")),
        last_verified=row.get("last_verified"),
        uncertainty=row.get("uncertainty"),
    )


def _epistemics(row: dict) -> Epistemics:
    state = row.get("epistemic_state") or "observed"
    depth = row.get("analysis_depth")
    try:
        depth = int(depth) if depth is not None else 0
    except (TypeError, ValueError):
        depth = 0
    provenance = (row.get("provenance") or "").lower()
    # Runtime evidence is OBSERVED at depth 4 — never reported as inferred.
    if provenance in ("runtime", "runtime_trace"):
        state, depth = "observed", max(depth, 4)
    if state not in STATES:
        state = "inferred"
    completeness = row.get("completeness") or "partial"
    if completeness not in COMPLETENESS:
        completeness = "partial"
    return Epistemics(state, depth, completeness)


def _provider_of(row: dict) -> tuple[str, str]:
    return (
        str(row.get("provider") or ""),
        str(row.get("provider_revision") or ""),
    )


def _stable(row: dict, fallback: str) -> str:
    return str(row.get("stable_id") or row.get("stable_subject") or fallback)


def _record(kind: str, obj) -> dict:
    data = asdict(obj) if hasattr(obj, "__dataclass_fields__") else dict(obj)
    data["record"] = kind
    return data


def export_protocol(
    graph,
    snapshot_id: int | None = None,
    *,
    requirements: list[Requirement] | None = None,
) -> dict:
    """Project ONE deterministic finalized snapshot into protocol v2.

    `snapshot_id=None` resolves the latest FINALIZED snapshot; there is no
    union-across-snapshots mode. Raises `SnapshotError` when none exists.
    """
    data = graph.export_json(snapshot_id)
    snap = data["snapshot"]
    snap_id = int(snap["id"])

    semantic_config = snap.get("semantic_configuration") or "{}"
    if isinstance(semantic_config, str):
        try:
            semantic_config = json.loads(semantic_config)
        except json.JSONDecodeError:
            semantic_config = {"raw": semantic_config}

    support_index: dict[tuple[str, int], list[dict]] = {}
    for s in data.get("support", []):
        support_index.setdefault((str(s.get("subject_table")), int(s.get("subject_id") or 0)), []).append(s)

    evidence_rows = data.get("evidence", [])
    evidence_ids = {int(e["id"]): f"Evidence:{e['id']}" for e in evidence_rows}

    def evidence_refs_for(subject_table: str, subject_id: int) -> list[EvidenceRef]:
        out = []
        for s in support_index.get((subject_table, int(subject_id)), []):
            ev = s.get("evidence_id")
            if ev is None:
                continue
            ref = EvidenceRef(id=evidence_ids.get(int(ev), f"Evidence:{ev}"))
            for e in evidence_rows:
                if int(e["id"]) == int(ev):
                    ref.digest = e.get("digest")
                    ref.ref = e.get("ref")
                    break
            if ref not in out:
                out.append(ref)
        return out

    providers = [
        _record(
            "Provider",
            ProviderRecord(
                id=f"Provider:{p['provider']}",
                provider=p["provider"],
                version=p.get("provider_version", ""),
                capabilities=p.get("capabilities") or {},
                invoked=bool(p.get("invoked", True)),
            ),
        )
        for p in data.get("provider_records", [])
    ]
    provider_versions = {
        p["provider"]: p.get("provider_version", "") for p in data.get("provider_records", [])
    }

    facts = []
    claims = []
    for r in data.get("facts", []):
        provider, version = _provider_of(r)
        stable = _stable(r, f"fact:{r['subject']}:{r['predicate']}:{r['object']}")
        facts.append(
            _record(
                "Fact",
                Fact(
                    id=f"Fact:{stable}",
                    stable_id=stable,
                    subject=r["subject"],
                    predicate=r["predicate"],
                    object=r["object"],
                    epistemics=_epistemics(r),
                    confidence=_confidence(r),
                    provenance=_provenance(r, provider, version),
                    evidence=evidence_refs_for("fact", int(r["id"])),
                ),
            )
        )
        claims.append(
            _record(
                "Claim",
                Claim(
                    id=f"Claim:fact:{stable}",
                    stable_id=f"fact:{stable}",
                    text=f"{r['subject']} {r['predicate']} {r['object']}",
                    epistemics=_epistemics(r),
                    confidence=_confidence(r),
                    provenance=_provenance(r, provider, version),
                    evidence=evidence_refs_for("fact", int(r["id"])),
                ),
            )
        )

    invariants = []
    for r in data.get("invariants", []):
        provider, version = _provider_of(r)
        stable = _stable(r, f"invariant:{r['id']}")
        invariants.append(
            _record(
                "Invariant",
                Invariant(
                    id=f"Invariant:{stable}",
                    stable_id=stable,
                    statement=r["statement"],
                    component=r.get("component_qn"),
                    epistemics=_epistemics(r),
                    confidence=_confidence(r),
                    provenance=_provenance(r, provider, version),
                ),
            )
        )
        claims.append(
            _record(
                "Claim",
                Claim(
                    id=f"Claim:invariant:{stable}",
                    stable_id=f"invariant:{stable}",
                    text=r["statement"],
                    epistemics=_epistemics(r),
                    confidence=_confidence(r),
                    provenance=_provenance(r, provider, version),
                ),
            )
        )

    contracts = []
    for r in data.get("contracts", []):
        provider, version = _provider_of(r)
        stable = _stable(r, f"contract:{r['id']}")
        contracts.append(
            _record(
                "Contract",
                Contract(
                    id=f"Contract:{stable}",
                    stable_id=stable,
                    kind=r.get("kind", ""),
                    name=r.get("name", ""),
                    component=r.get("component_qn"),
                    format=r.get("format"),
                    epistemics=_epistemics(r),
                    confidence=_confidence(r),
                    provenance=_provenance(r, provider, version),
                ),
            )
        )

    risks = []
    for r in data.get("incidents", []):
        provider, version = _provider_of(r)
        stable = _stable(r, f"incident:{r['id']}")
        risks.append(
            _record(
                "Risk",
                Risk(
                    id=f"Risk:{stable}",
                    stable_id=stable,
                    description=r["summary"],
                    component=r.get("component_qn"),
                    epistemics=_epistemics({**r, "epistemic_state": r.get("epistemic_state") or "historically_supported"}),
                    confidence=_confidence(r),
                    provenance=_provenance(r, provider, version),
                ),
            )
        )
    for r in data.get("facts", []):
        try:
            conf = float(r.get("confidence", 1.0))
        except (TypeError, ValueError):
            conf = 1.0
        if r.get("uncertainty") or conf < 1.0:
            provider, version = _provider_of(r)
            stable = _stable(r, f"fact:{r['id']}")
            risks.append(
                _record(
                    "Risk",
                    Risk(
                        id=f"Risk:uncertain:{stable}",
                        stable_id=f"uncertain:{stable}",
                        description=r.get("uncertainty")
                        or f"low-confidence fact: {r['subject']} {r['predicate']} {r['object']}",
                        component=r["subject"],
                        epistemics=Epistemics("uncertain", _epistemics(r).analysis_depth, "partial"),
                        evidence=[EvidenceRef(id=f"Fact:{stable}")],
                        confidence=_confidence(r),
                        provenance=_provenance(r, provider, version),
                    ),
                )
            )

    changes = []
    for r in data.get("changes", []):
        provider, version = _provider_of(r)
        stable = _stable(r, f"change:{r['id']}")
        changes.append(
            _record(
                "Change",
                Change(
                    id=f"Change:{stable}",
                    stable_id=stable,
                    commit_sha=r.get("commit_sha"),
                    summary=r["summary"],
                    files=_derived_list(r.get("files")),
                    outcome=r.get("outcome"),
                    epistemics=_epistemics({**r, "epistemic_state": r.get("epistemic_state") or "historically_supported"}),
                    confidence=_confidence(r),
                    provenance=_provenance(r, provider, version),
                ),
            )
        )

    evidence = [
        _record(
            "Evidence",
            Evidence(
                id=evidence_ids[int(r["id"])],
                kind=r.get("kind", ""),
                ref=r.get("ref", ""),
                digest=r.get("digest"),
                summary=r.get("summary") or "",
                provider=r.get("provider") or "",
                epistemics=Epistemics("observed", 0, "complete"),
            ),
        )
        for r in evidence_rows
    ]

    counterexamples = []
    for r in evidence_rows:
        if r.get("kind") != "counterexample":
            continue
        payload = r.get("payload")
        if isinstance(payload, str):
            try:
                payload = json.loads(payload)
            except json.JSONDecodeError:
                payload = {}
        payload = payload if isinstance(payload, dict) else {}
        claim_id = payload.get("claim_id") or r.get("ref") or ""
        counterexamples.append(
            _record(
                "Counterexample",
                Counterexample(
                    id=f"Counterexample:{r['id']}",
                    claim_id=str(claim_id),
                    description=r.get("summary") or "refuting evidence",
                    evidence=[EvidenceRef(id=evidence_ids[int(r["id"])], digest=r.get("digest"), ref=r.get("ref"))],
                ),
            )
        )

    unresolved = []
    for r in data.get("unresolved_edges", []):
        provider = str(r.get("provider") or "")
        stable = f"unresolved:{r.get('src_key','')}:{r.get('kind','')}:{r.get('dst_raw','')}"
        unresolved.append(
            _record(
                "UnresolvedClaim",
                UnresolvedClaim(
                    id=f"UnresolvedClaim:{stable}",
                    stable_id=stable,
                    src_key=str(r.get("src_key") or ""),
                    raw_target=str(r.get("dst_raw") or ""),
                    kind=str(r.get("kind") or ""),
                    candidates=list(r.get("candidates") or []),
                    completeness=str(r.get("completeness") or "unknown"),
                    confidence=Confidence(_safe_float(r.get("confidence"), 0.3), []),
                    provenance=Provenance(
                        kind="source_scan",
                        provider=provider,
                        provider_version=str(r.get("provider_revision") or provider_versions.get(provider, "")),
                    ),
                    evidence=[EvidenceRef(id=e) for e in _derived_list(r.get("evidence"))],
                ),
            )
        )

    relationships = []
    for r in data.get("relations", []):
        provider, version = _provider_of(r)
        resolved = r.get("dst_id") is not None
        stable = f"rel:{r.get('src_key','')}:{r.get('kind','')}:{r.get('dst_key','') or r.get('src_id')}"
        relationships.append(
            _record(
                "Relationship",
                Relationship(
                    id=f"Relationship:{stable}",
                    stable_id=stable,
                    src_key=str(r.get("src_key") or ""),
                    dst_key=str(r.get("dst_key") or ""),
                    kind=str(r.get("kind") or ""),
                    resolved=bool(resolved),
                    epistemics=_epistemics(r),
                    confidence=_confidence(r),
                    provenance=_provenance(r, provider, version),
                ),
            )
        )

    completeness = graph.completeness(snap_id)
    return {
        "protocol_version": PROTOCOL_VERSION,
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "snapshot": {
            "id": snap_id,
            "revision_digest": snap.get("revision_digest"),
            "repo_identity": snap.get("repo_identity"),
            "source_revision": snap.get("source_revision"),
            "tree_digest": snap.get("tree_digest"),
            "semantic_configuration": semantic_config,
            "provider_set_digest": snap.get("provider_set_digest"),
            "state": snap.get("state"),
            "repo_root": snap.get("repo_root"),
            "created_utc": snap.get("created_utc"),
            "finalized_utc": snap.get("finalized_utc"),
        },
        "provider_set": [
            {"provider": p["provider"], "version": p.get("provider_version", ""), "capabilities": p.get("capabilities") or {}}
            for p in data.get("provider_records", [])
        ],
        "completeness": completeness.get("families", {}),
        "records": {
            "requirements": [_record("Requirement", r) for r in (requirements or [])],
            "facts": facts,
            "claims": claims,
            "invariants": invariants,
            "contracts": contracts,
            "risks": risks,
            "changes": changes,
            "evidence": evidence,
            "counterexamples": counterexamples,
            "unresolved": unresolved,
            "relationships": relationships,
            "providers": providers,
        },
    }


def _safe_float(value, default: float) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def protocol_json(graph, snapshot_id: int | None = None, **kwargs) -> str:
    """`export_protocol` rendered as indented JSON."""
    return json.dumps(
        export_protocol(graph, snapshot_id, **kwargs), indent=2, sort_keys=False
    )
