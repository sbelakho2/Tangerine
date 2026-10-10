"""Symmetric ingest side of the neutral System Intelligence Protocol.

Any verifier, runtime collector, CI system or human tool can return evidence
to Tangerine without Tangerine knowing which product generated it: the
document is validated against the neutral protocol vocabulary, and its
evidence / support / unresolved claims / counterexamples / requirements are
persisted into the target (mutable) snapshot.

Ingest never fabricates local structural truth: it stores what the producer
observed, attributed to the producer, and keeps the subject references the
producer supplied. An unknown record kind is counted and skipped — never an
error, never a crash.
"""

from __future__ import annotations

from system_intel.graph import SnapshotError

SUPPORTED_RECORD_KINDS = {
    "Requirement",
    "Fact",
    "Claim",
    "Invariant",
    "Contract",
    "Risk",
    "Change",
    "Evidence",
    "Counterexample",
    "UnresolvedClaim",
    "Relationship",
    "Provider",
}


def _ref_list(value) -> list:
    if not value:
        return []
    if isinstance(value, list):
        return value
    return [value]


def _ref_id(ref) -> str:
    if isinstance(ref, dict):
        return str(ref.get("id") or ref.get("ref") or "")
    return str(ref or "")


def ingest_protocol(graph, doc, *, snapshot_id, provider_id, provider_version="") -> dict:
    """Validate a protocol v2 document and persist its evidence into a snapshot.

    The target snapshot must be mutable (a draft): finalized snapshots are
    immutable truth and raise SnapshotError.
    """
    if not isinstance(doc, dict):
        raise ValueError("ingest_protocol: the document must be a mapping")
    version = doc.get("protocol_version")
    if version != 2:
        raise ValueError(f"ingest_protocol: unsupported protocol_version {version!r} (expected 2)")

    snap_row = graph._snapshot_row(snapshot_id) if hasattr(graph, "_snapshot_row") else None
    if snap_row is None:
        raise SnapshotError(f"ingest_protocol: snapshot {snapshot_id} not found")
    if str(snap_row.get("state")) == "finalized":
        raise SnapshotError(
            "ingest_protocol: the target snapshot is finalized and immutable; "
            "ingest into a draft (finalized snapshots are frozen truth)"
        )

    records = doc.get("records") or {}
    report = {
        "protocol_version": 2,
        "snapshot_id": int(snapshot_id),
        "provider": provider_id,
        "provider_version": provider_version,
        "accepted_records": 0,
        "skipped_records": 0,
        "evidence_ids": [],
        "support_ids": [],
        "unresolved_ids": [],
        "counterexample_ids": [],
        "requirement_fact_ids": [],
        "errors": [],
    }

    # 0. Unknown record kinds are counted and skipped (forward compatibility),
    # in every bucket — a future protocol minor version must not crash ingest.
    for bucket_records in records.values():
        if not isinstance(bucket_records, list):
            continue
        for rec in bucket_records:
            if not isinstance(rec, dict):
                continue
            if rec.get("record") and rec.get("record") not in SUPPORTED_RECORD_KINDS:
                report["skipped_records"] += 1

    # 1. Evidence first: every other record references it by protocol id.
    evidence_map: dict[str, int] = {}
    for rec in records.get("evidence", []) or []:
        rec_kind = rec.get("record", "Evidence")
        if rec_kind != "Evidence":
            continue
        try:
            ev_id = graph.add_evidence(
                snapshot_id,
                str(rec.get("kind") or "external"),
                str(rec.get("ref") or rec.get("id") or ""),
                digest=rec.get("digest"),
                summary=str(rec.get("summary") or ""),
                provider=provider_id,
            )
        except Exception as exc:  # noqa: BLE001 - ingest reports, never crashes
            report["errors"].append(f"evidence {rec.get('id')}: {exc}")
            continue
        evidence_map[str(rec.get("id") or ev_id)] = ev_id
        report["evidence_ids"].append(ev_id)
        report["accepted_records"] += 1

    def map_evidence(refs) -> list[str]:
        out = []
        for ref in _ref_list(refs):
            rid = _ref_id(ref)
            mapped = evidence_map.get(rid)
            if mapped is not None:
                out.append(str(mapped))
        return out

    # 2. Unresolved claims: first-class unknown edges.
    for rec in records.get("unresolved", []) or []:
        if rec.get("record") != "UnresolvedClaim":
            report["skipped_records"] += 1
            continue
        try:
            un_id = graph.add_unresolved_edge(
                snapshot_id,
                str(rec.get("src_key") or ""),
                str(rec.get("raw_target") or ""),
                str(rec.get("kind") or ""),
                provider=str(rec.get("provenance", {}).get("provider") or provider_id)
                if isinstance(rec.get("provenance"), dict)
                else provider_id,
                provider_revision=str(rec.get("provenance", {}).get("provider_version") or provider_version)
                if isinstance(rec.get("provenance"), dict)
                else provider_version,
                candidates=list(rec.get("candidates") or []),
                confidence=float(rec.get("confidence", {}).get("value", 0.3))
                if isinstance(rec.get("confidence"), dict)
                else float(rec.get("confidence") or 0.3),
                completeness=str(rec.get("completeness") or "unknown"),
                evidence=map_evidence(rec.get("evidence")),
            )
        except Exception as exc:  # noqa: BLE001
            report["errors"].append(f"unresolved {rec.get('id')}: {exc}")
            continue
        report["unresolved_ids"].append(un_id)
        report["accepted_records"] += 1

    # 3. Counterexamples: refuting evidence linked to the claim it refutes.
    for rec in records.get("counterexamples", []) or []:
        if rec.get("record") != "Counterexample":
            report["skipped_records"] += 1
            continue
        try:
            ev_id = graph.add_evidence(
                snapshot_id,
                "counterexample",
                str(rec.get("claim_id") or ""),
                summary=str(rec.get("description") or ""),
                payload={"claim_id": rec.get("claim_id"), "ingested": True},
                provider=provider_id,
            )
        except Exception as exc:  # noqa: BLE001
            report["errors"].append(f"counterexample {rec.get('id')}: {exc}")
            continue
        report["counterexample_ids"].append(ev_id)
        report["accepted_records"] += 1

    # 4. Requirements: preserved as declared facts with supporting evidence.
    for rec in records.get("requirements", []) or []:
        if rec.get("record") != "Requirement":
            report["skipped_records"] += 1
            continue
        rid = str(rec.get("id") or "")
        statement = str(rec.get("statement") or "")
        try:
            ev_id = graph.add_evidence(
                snapshot_id,
                "requirement",
                rid or statement,
                summary=statement,
                provider=provider_id,
            )
            fact_id = graph.upsert_fact(
                f"requirement:{rid or statement}",
                "requires",
                statement,
                snapshot_id=snapshot_id,
                provenance="declared",
                confidence=1.0,
                provider=provider_id,
                provider_revision=provider_version,
                stable_subject=f"requirement:{rid or statement}",
            )
            graph.accumulate_support(
                snapshot_id,
                "fact",
                fact_id,
                provider=provider_id,
                provider_revision=provider_version,
                confidence=1.0,
                evidence_id=ev_id,
                detail=f"requirement status={rec.get('status') or 'unknown'}",
            )
        except Exception as exc:  # noqa: BLE001
            report["errors"].append(f"requirement {rec.get('id')}: {exc}")
            continue
        report["requirement_fact_ids"].append(fact_id)
        report["evidence_ids"].append(ev_id)
        report["accepted_records"] += 1

    # 5. Evidence-bearing claims: support is accumulated against a LOCAL
    # subject when one resolves; otherwise the evidence stands attributed to
    # the producer without fabricating a local subject.
    for bucket, table in (
        ("facts", "fact"),
        ("invariants", "invariant"),
        ("contracts", "contract"),
        ("relationships", "relation"),
        ("risks", "fact"),
    ):
        for rec in records.get(bucket, []) or []:
            kind = rec.get("record")
            if kind not in SUPPORTED_RECORD_KINDS:
                report["skipped_records"] += 1
                continue
            ev_ids = map_evidence(rec.get("evidence"))
            if not ev_ids:
                report["accepted_records"] += 1
                continue
            stable = rec.get("stable_id") or rec.get("id") or ""
            subject_id = None
            if table == "relation" and rec.get("src_key"):
                subject_id = _resolve_relation_id(graph, snapshot_id, rec)
            elif table == "fact":
                subject_id = _resolve_fact_id(
                    graph, snapshot_id, rec.get("subject"), rec.get("predicate"), rec.get("object")
                )
            if subject_id is None:
                # No local subject: keep the evidence, count the record.
                report["accepted_records"] += 1
                continue
            try:
                sup_id = graph.accumulate_support(
                    snapshot_id,
                    table,
                    subject_id,
                    provider=provider_id,
                    provider_revision=provider_version,
                    confidence=float(rec.get("confidence", {}).get("value", 1.0))
                    if isinstance(rec.get("confidence"), dict)
                    else float(rec.get("confidence") or 1.0),
                    evidence_id=int(ev_ids[0]),
                    detail=f"protocol:{stable}",
                )
            except Exception as exc:  # noqa: BLE001
                report["errors"].append(f"support {stable}: {exc}")
                continue
            report["support_ids"].append(sup_id)
            report["accepted_records"] += 1

    return report


def _resolve_relation_id(graph, snapshot_id, rec):
    conn = graph._require_conn()
    row = conn.execute(
        "SELECT id FROM relation WHERE snapshot_id=? AND src_key=? AND kind=? AND (dst_key=? OR dst_key='')",
        (
            int(snapshot_id),
            str(rec.get("src_key") or ""),
            str(rec.get("kind") or ""),
            str(rec.get("dst_key") or ""),
        ),
    ).fetchone()
    return int(row["id"]) if row is not None else None


def _resolve_fact_id(graph, snapshot_id, subject, predicate, object_):
    if subject is None or predicate is None or object_ is None:
        return None
    conn = graph._require_conn()
    row = conn.execute(
        "SELECT id FROM fact WHERE snapshot_id=? AND subject=? AND predicate=? AND object=?",
        (int(snapshot_id), str(subject), str(predicate), str(object_)),
    ).fetchone()
    return int(row["id"]) if row is not None else None
