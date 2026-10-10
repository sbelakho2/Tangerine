"""Neutral exchange protocol for Tangerine System Intelligence.

This module is intentionally documented independently of Tangerine
internals: a consumer only needs this vocabulary (defined here and in
README.md) to understand an exchange, never the SQLite schema.

Protocol records are plain dataclasses serialized to JSON.  The record
kinds mirror the shared interoperability schema:

    Requirement, Fact, Claim, Invariant, Contract, Risk, Change,
    Evidence, Counterexample

each carrying Confidence and Provenance where meaningful.

`export_protocol(graph)` projects a graph snapshot into that vocabulary
using only the public Graph API.  Nothing here is consumer-specific: no
Faktor/Kiwi identifiers, no task formats, no orchestration semantics.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone

PROTOCOL_VERSION = 1

# The knowledge states every record may carry (shared vocabulary).
STATES = (
    "observed",
    "declared",
    "inferred",
    "historically_supported",
    "uncertain",
    "contradicted",
    "stale",
)


@dataclass
class Confidence:
    value: float = 1.0
    basis: list[str] = field(default_factory=list)


@dataclass
class Provenance:
    source: str = "tangerine"
    derived_from: list[str] = field(default_factory=list)
    last_verified: str | None = None
    uncertainty: str | None = None


@dataclass
class Requirement:
    id: str
    statement: str
    status: str = "unknown"  # open | met | unknown
    refs: list[str] = field(default_factory=list)


@dataclass
class Fact:
    id: str
    subject: str
    predicate: str
    object: str
    state: str = "observed"
    tier: int = 0
    confidence: Confidence = field(default_factory=Confidence)
    provenance: Provenance = field(default_factory=Provenance)


@dataclass
class Claim:
    id: str
    text: str
    state: str = "inferred"
    confidence: Confidence = field(default_factory=Confidence)
    provenance: Provenance = field(default_factory=Provenance)


@dataclass
class Invariant:
    id: str
    statement: str
    component: str | None = None
    state: str = "declared"
    confidence: Confidence = field(default_factory=Confidence)
    provenance: Provenance = field(default_factory=Provenance)


@dataclass
class Contract:
    id: str
    kind: str
    name: str
    component: str | None = None
    format: str | None = None
    state: str = "declared"
    confidence: Confidence = field(default_factory=Confidence)
    provenance: Provenance = field(default_factory=Provenance)


@dataclass
class Risk:
    id: str
    description: str
    component: str | None = None
    state: str = "inferred"
    evidence: list[str] = field(default_factory=list)
    confidence: Confidence = field(default_factory=Confidence)
    provenance: Provenance = field(default_factory=Provenance)


@dataclass
class Change:
    id: str
    commit_sha: str | None
    summary: str
    files: list[str] = field(default_factory=list)
    outcome: str | None = None
    state: str = "historically_supported"
    confidence: Confidence = field(default_factory=Confidence)
    provenance: Provenance = field(default_factory=Provenance)


@dataclass
class Evidence:
    id: str
    kind: str
    ref: str
    summary: str = ""
    state: str = "observed"


@dataclass
class Counterexample:
    id: str
    claim_id: str
    description: str
    evidence: list[str] = field(default_factory=list)


def _confidence(row: dict) -> Confidence:
    value = row.get("confidence")
    try:
        value = float(value)
    except (TypeError, ValueError):
        value = 1.0
    return Confidence(value=max(0.0, min(1.0, value)))


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


def _provenance(row: dict) -> Provenance:
    return Provenance(
        source="tangerine",
        derived_from=_derived_list(row.get("derived_from")),
        last_verified=row.get("last_verified"),
        uncertainty=row.get("uncertainty"),
    )


def _state(row: dict) -> str:
    if row.get("stale"):
        return "stale"
    state = row.get("provenance") or "observed"
    return state if state in STATES else "inferred"


def _record(kind: str, row) -> dict:
    data = asdict(row) if hasattr(row, "__dataclass_fields__") else dict(row)
    data["record"] = kind
    return data


def export_protocol(
    graph,
    snapshot_id: int | None = None,
    *,
    requirements: list[Requirement] | None = None,
) -> dict:
    """Project one graph snapshot into the neutral exchange vocabulary.

    The returned dict is JSON-serializable with the shape::

        {"protocol_version": 1, "generated_utc": ..., "snapshot": {...},
         "records": {"requirements": [...], "facts": [...], "claims": [...],
                     "invariants": [...], "contracts": [...], "risks": [...],
                     "changes": [...], "evidence": [...],
                     "counterexamples": [...], "relations": [...]}}

    Only public Graph API is used (`export_json`); the projection can be
    re-implemented by any consumer without Tangerine internals.
    """
    data = graph.export_json(snapshot_id)
    snaps = data.get("snapshots") or []
    if snapshot_id is None:
        if not snaps:
            raise ValueError("no snapshot in this database; run scan first")
        snapshot_meta = {
            "id": snaps[-1]["id"],
            "repo_root": snaps[-1].get("repo_root"),
            "commit_sha": snaps[-1].get("commit_sha"),
            "created_utc": snaps[-1].get("created_utc"),
        }
    else:
        chosen = next((s for s in snaps if s.get("id") == snapshot_id), None)
        if chosen is None:
            raise ValueError(f"snapshot {snapshot_id} not found")
        snapshot_meta = {
            "id": chosen["id"],
            "repo_root": chosen.get("repo_root"),
            "commit_sha": chosen.get("commit_sha"),
            "created_utc": chosen.get("created_utc"),
        }

    entities_by_id = {e.get("id"): e for e in data.get("entities", [])}

    facts = []
    claims = []
    for r in data.get("facts", []):
        facts.append(
            _record(
                "Fact",
                Fact(
                    id=f"fact:{r['id']}",
                    subject=r["subject"],
                    predicate=r["predicate"],
                    object=r["object"],
                    state=_state(r),
                    tier=r.get("tier", 0),
                    confidence=_confidence(r),
                    provenance=_provenance(r),
                ),
            )
        )
        claims.append(
            _record(
                "Claim",
                Claim(
                    id=f"claim:fact:{r['id']}",
                    text=f"{r['subject']} {r['predicate']} {r['object']}",
                    state=_state(r),
                    confidence=_confidence(r),
                    provenance=_provenance(r),
                ),
            )
        )

    invariants = []
    for r in data.get("invariants", []):
        invariants.append(
            _record(
                "Invariant",
                Invariant(
                    id=f"invariant:{r['id']}",
                    statement=r["statement"],
                    component=r.get("component_qn"),
                    state=_state(r),
                    confidence=_confidence(r),
                    provenance=_provenance(r),
                ),
            )
        )
        claims.append(
            _record(
                "Claim",
                Claim(
                    id=f"claim:invariant:{r['id']}",
                    text=r["statement"],
                    state=_state(r),
                    confidence=_confidence(r),
                    provenance=_provenance(r),
                ),
            )
        )

    contracts = []
    for r in data.get("contracts", []):
        contracts.append(
            _record(
                "Contract",
                Contract(
                    id=f"contract:{r['id']}",
                    kind=r["kind"],
                    name=r["name"],
                    component=r.get("component_qn"),
                    format=r.get("format"),
                    state=_state(r),
                    confidence=_confidence(r),
                    provenance=_provenance(r),
                ),
            )
        )

    risks = []
    evidence = []
    for r in data.get("incidents", []):
        ev_id = f"evidence:incident:{r['id']}"
        evidence.append(
            _record(
                "Evidence",
                Evidence(
                    id=ev_id,
                    kind="incident",
                    ref=r.get("occurred_utc") or "unknown-time",
                    summary=r["summary"],
                    state="historically_supported",
                ),
            )
        )
        risks.append(
            _record(
                "Risk",
                Risk(
                    id=f"risk:incident:{r['id']}",
                    description=r["summary"],
                    component=r.get("component_qn"),
                    state="historically_supported",
                    evidence=[ev_id],
                    confidence=_confidence(r),
                    provenance=_provenance(r),
                ),
            )
        )
    for r in data.get("facts", []):
        try:
            conf = float(r.get("confidence", 1.0))
        except (TypeError, ValueError):
            conf = 1.0
        if r.get("uncertainty") or conf < 1.0:
            risks.append(
                _record(
                    "Risk",
                    Risk(
                        id=f"risk:uncertain-fact:{r['id']}",
                        description=r.get("uncertainty")
                        or f"low-confidence fact: {r['subject']} {r['predicate']} {r['object']}",
                        component=r["subject"],
                        state="uncertain",
                        evidence=[f"fact:{r['id']}"],
                        confidence=_confidence(r),
                        provenance=_provenance(r),
                    ),
                )
            )

    changes = []
    for r in data.get("changes", []):
        changes.append(
            _record(
                "Change",
                Change(
                    id=f"change:{r['id']}",
                    commit_sha=r.get("commit_sha"),
                    summary=r["summary"],
                    files=_derived_list(r.get("files")),
                    outcome=r.get("outcome"),
                    state=_state(r),
                    confidence=_confidence(r),
                    provenance=_provenance(r),
                ),
            )
        )

    relations = []
    for r in data.get("relations", []):
        src = entities_by_id.get(r.get("src_id"), {})
        dst = entities_by_id.get(r.get("dst_id"), {})
        relations.append(
            {
                "record": "Relationship",
                "id": f"relation:{r['id']}",
                "src": src.get("qualified_name"),
                "dst": dst.get("qualified_name"),
                "kind": r["kind"],
                "tier": r.get("tier", 0),
                "state": _state(r),
                "confidence": _confidence(r).value,
                "provenance": asdict(_provenance(r)),
            }
        )

    return {
        "protocol_version": PROTOCOL_VERSION,
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "snapshot": snapshot_meta,
        "records": {
            "requirements": [_record("Requirement", r) for r in (requirements or [])],
            "facts": facts,
            "claims": claims,
            "invariants": invariants,
            "contracts": contracts,
            "risks": risks,
            "changes": changes,
            "evidence": evidence,
            "counterexamples": [],
            "relations": relations,
        },
    }


def protocol_json(graph, snapshot_id: int | None = None, **kwargs) -> str:
    """`export_protocol` rendered as indented JSON."""
    return json.dumps(
        export_protocol(graph, snapshot_id, **kwargs), indent=2, sort_keys=False
    )
