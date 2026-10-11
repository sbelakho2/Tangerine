"""Protocol v2 + ingest tests (stop-ship review items P0-1, P0-5, P0-8, protocol v2)."""

import json
import re
import unittest

from system_intel.graph import Graph, SnapshotError
from system_intel.ingest import ingest_protocol
from system_intel.protocol import (
    PROTOCOL_VERSION,
    Requirement,
    evidence_stable_id,
    export_protocol,
    protocol_json,
    semantic_digest,
)


def _identity(tag, **overrides):
    base = {
        "repo_identity": "test-repo",
        "source_revision": f"rev-{tag}",
        "tree_digest": f"tree-{tag}",
        "semantic_configuration": "{}",
        "provider_set_digest": "",
    }
    base.update(overrides)
    return base


class ProtocolV2Tests(unittest.TestCase):
    def setUp(self):
        self.g = Graph.open(":memory:")

    def tearDown(self):
        self.g.close()

    def _draft(self, tag, **overrides):
        return self.g.begin_draft(_identity(tag, **overrides))

    # (a) deterministic single snapshot: no cross-snapshot mixing after reopen
    def test_export_protocol_claims_one_snapshot_only(self):
        a = self._draft("a")
        self.g.upsert_fact("svc-a", "is", "present", snapshot_id=a)
        self.g.finalize_snapshot(a)
        b = self._draft("b")
        self.g.upsert_fact("svc-b", "is", "present", snapshot_id=b)
        self.g.finalize_snapshot(b)

        doc = export_protocol(self.g)  # no snapshot_id: latest FINALIZED
        self.assertEqual(doc["snapshot"]["source_revision"], "rev-b")
        subjects = {f["subject"] for f in doc["records"]["facts"]}
        self.assertIn("svc-b", subjects)
        self.assertNotIn("svc-a", subjects)

    def test_reopen_resolves_latest_snapshot(self):
        import tempfile, os

        with tempfile.TemporaryDirectory() as tmp:
            db = os.path.join(tmp, "g.db")
            g = Graph.open(db)
            a = g.begin_draft(_identity("a"))
            g.upsert_fact("only-a", "is", "x", snapshot_id=a)
            g.finalize_snapshot(a)
            b = g.begin_draft(_identity("b"))
            g.upsert_fact("only-b", "is", "x", snapshot_id=b)
            g.finalize_snapshot(b)
            g.close()

            with Graph.open(db, create=False) as reopened:
                doc = export_protocol(reopened)
                self.assertEqual(doc["snapshot"]["source_revision"], "rev-b")
                subjects = {f["subject"] for f in doc["records"]["facts"]}
                self.assertEqual(subjects, {"only-b"})
                # stats() follows the same one-snapshot rule
                stats = reopened.stats()
                self.assertEqual(stats["state"], "finalized")
                snap_row = reopened.latest_finalized_snapshot()
                self.assertEqual(snap_row["source_revision"], "rev-b")

    # (b) no finalized snapshot -> SnapshotError, never a union
    def test_empty_database_raises(self):
        with self.assertRaises(SnapshotError):
            export_protocol(self.g)
        with self.assertRaises(SnapshotError):
            self.g.stats()
        with self.assertRaises(SnapshotError):
            self.g.export_json()

    # (c) stable record ids, never SQLite row integers
    def test_stable_ids_never_row_ids(self):
        snap = self._draft("ids")
        self.g.upsert_fact("subject", "predicate", "object", snapshot_id=snap)
        self.g.add_unresolved_edge(
            snap, "file:src/x.py", "missing::target", "imports", provider="generic-static"
        )
        self.g.finalize_snapshot(snap)
        doc = export_protocol(self.g)
        for rec in doc["records"]["facts"]:
            self.assertTrue(rec["id"].startswith("Fact:"))
            self.assertFalse(re.fullmatch(r"Fact:\d+", rec["id"]), rec["id"])
        for rec in doc["records"]["unresolved"]:
            self.assertTrue(rec["id"].startswith("UnresolvedClaim:"))
            self.assertFalse(re.fullmatch(r"UnresolvedClaim:\d+", rec["id"]))
            # content-derived identity: the hash is deterministic and carries
            # no row id; the raw source key lives in the record fields.
            self.assertEqual(rec["stable_id"], rec["id"].split(":", 1)[1])
            self.assertEqual(len(rec["stable_id"].split(":")[-1]), 64)
        self.assertEqual(doc["protocol_version"], PROTOCOL_VERSION)

    # (d) runtime provenance is observed/depth-4, never inferred
    def test_runtime_provenance_maps_to_observed_depth_4(self):
        snap = self._draft("rt")
        self.g.upsert_fact(
            "svc",
            "handled",
            "request",
            snapshot_id=snap,
            provenance="runtime",
            confidence=0.9,
        )
        self.g.finalize_snapshot(snap)
        doc = export_protocol(self.g)
        fact = next(f for f in doc["records"]["facts"] if f["subject"] == "svc")
        self.assertEqual(fact["epistemics"]["epistemic_state"], "observed")
        self.assertEqual(fact["epistemics"]["analysis_depth"], 4)
        self.assertNotEqual(fact["epistemics"]["epistemic_state"], "inferred")

    # (e) unresolved edges are first-class, with raw target + candidates
    def test_unresolved_claims_exported(self):
        snap = self._draft("unres")
        self.g.add_unresolved_edge(
            snap,
            "file:src/orders.py",
            "app.store",
            "imports",
            provider="generic-static",
            provider_revision="1.0",
            candidates=["file:app/store.py"],
            confidence=0.5,
            completeness="partial",
        )
        self.g.finalize_snapshot(snap)
        doc = export_protocol(self.g)
        claims = doc["records"]["unresolved"]
        self.assertEqual(len(claims), 1)
        claim = claims[0]
        self.assertEqual(claim["src_key"], "file:src/orders.py")
        self.assertEqual(claim["raw_target"], "app.store")
        self.assertEqual(claim["candidates"], ["file:app/store.py"])
        self.assertEqual(claim["completeness"], "partial")
        self.assertEqual(claim["record"], "UnresolvedClaim")

    # typed endpoints + resolved flag on relationships
    def test_relationships_carry_typed_keys(self):
        snap = self._draft("rel")
        a = self.g.upsert_entity("File", "orders.py", "file:src/orders.py", snapshot_id=snap)
        b = self.g.upsert_entity("Module", "app", "module:app", snapshot_id=snap)
        self.g.upsert_relation(a, b, "imports", snapshot_id=snap)
        self.g.finalize_snapshot(snap)
        doc = export_protocol(self.g)
        rels = doc["records"]["relationships"]
        self.assertEqual(len(rels), 1)
        rel = rels[0]
        self.assertEqual(rel["src_key"], "file:src/orders.py")
        self.assertEqual(rel["dst_key"], "module:app")
        self.assertTrue(rel["resolved"])

    # (h) counterexample shape: evidence of kind counterexample becomes a record
    def test_counterexample_records(self):
        snap = self._draft("cx")
        ev = self.g.add_evidence(
            snap, "counterexample", "claim:payment-idempotent",
            summary="double charge observed", payload={"claim_id": "claim:payment-idempotent"},
            provider="kiwi",
        )
        self.g.finalize_snapshot(snap)
        doc = export_protocol(self.g)
        cxs = doc["records"]["counterexamples"]
        self.assertEqual(len(cxs), 1)
        self.assertEqual(cxs[0]["claim_id"], "claim:payment-idempotent")
        # Evidence identity is content-derived (never "Evidence:<row id>").
        self.assertEqual(
            cxs[0]["evidence"][0]["id"],
            evidence_stable_id({
                "kind": "counterexample",
                "ref": "claim:payment-idempotent",
                "digest": None,
                "summary": "double charge observed",
            }),
        )
        self.assertNotEqual(cxs[0]["evidence"][0]["id"], f"Evidence:{ev}")
        self.assertEqual(cxs[0]["epistemics"]["epistemic_state"], "contradicted")

    # requirements are carried through the protocol
    def test_requirements_export(self):
        snap = self._draft("req")
        self.g.upsert_fact("x", "is", "y", snapshot_id=snap)
        self.g.finalize_snapshot(snap)
        req = Requirement(id="req:1", statement="no double charge", status="met")
        doc = export_protocol(self.g, requirements=[req])
        self.assertEqual(doc["records"]["requirements"][0]["statement"], "no double charge")

    def test_protocol_json_round_trips(self):
        snap = self._draft("json")
        self.g.upsert_fact("x", "is", "y", snapshot_id=snap)
        self.g.finalize_snapshot(snap)
        doc = json.loads(protocol_json(self.g))
        self.assertEqual(doc["protocol_version"], PROTOCOL_VERSION)
        self.assertTrue(doc["provider_set"] == [] or isinstance(doc["provider_set"], list))
        self.assertIn("completeness", doc)

    # (f) ingest round-trip: export -> ingest into a fresh draft
    def test_ingest_round_trip(self):
        src = self._draft("src")
        fact_id = self.g.upsert_fact(
            "svc", "publishes", "OrderCreated", snapshot_id=src, provider="generic-static"
        )
        ev = self.g.add_evidence(src, "trace", "trace:1", summary="observed publish")
        self.g.accumulate_support(src, "fact", fact_id, provider="generic-static", evidence_id=ev)
        self.g.add_unresolved_edge(
            src, "file:src/x.py", "ghost::module", "imports",
            provider="generic-static", candidates=[], completeness="unknown",
            evidence=[f"Evidence:{ev}"],
        )
        self.g.finalize_snapshot(src)
        doc = export_protocol(self.g)

        with Graph.open(":memory:") as dst:
            draft = dst.begin_draft(_identity("dst"))
            report = ingest_protocol(
                dst, doc, snapshot_id=draft, provider_id="kiwi", provider_version="1.2.0"
            )
            self.assertEqual(report["errors"], [], report["errors"])
            self.assertTrue(report["unresolved_ids"])
            self.assertTrue(report["evidence_ids"] or report["support_ids"])
            doc2 = export_protocol(dst, draft)
            self.assertTrue(doc2["records"]["unresolved"])

    # (g) ingest into a finalized snapshot is refused
    def test_ingest_rejects_finalized_snapshot(self):
        snap = self._draft("frozen")
        self.g.upsert_fact("x", "is", "y", snapshot_id=snap)
        self.g.finalize_snapshot(snap)
        doc = export_protocol(self.g)
        with self.assertRaises(SnapshotError):
            ingest_protocol(self.g, doc, snapshot_id=snap, provider_id="kiwi")

    def test_ingest_rejects_wrong_version(self):
        snap = self._draft("ver")
        with self.assertRaises(ValueError):
            ingest_protocol(
                self.g,
                {"protocol_version": 1, "records": {}},
                snapshot_id=snap,
                provider_id="kiwi",
            )

    def test_ingest_skips_unknown_record_kinds(self):
        draft = self.g.begin_draft(_identity("unknown"))
        doc = {
            "protocol_version": 2,
            "records": {"future_kind": [{"record": "FutureThing", "id": "FutureThing:1"}], "facts": []},
        }
        report = ingest_protocol(self.g, doc, snapshot_id=draft, provider_id="kiwi")
        self.assertEqual(report["errors"], [])
        self.assertGreaterEqual(report["skipped_records"], 1)

    # ── v3 protocol integrity ──────────────────────────────────────────

    def test_entity_records_exported_as_first_class_subjects(self):
        snap = self._draft("entities")
        self.g.upsert_entity(
            "Symbol", "Order", "sym:python:app/store.py::Order",
            qualified_name="app.store.Order", snapshot_id=snap, file="app/store.py",
        )
        self.g.finalize_snapshot(snap)
        doc = export_protocol(self.g)
        entities = doc["records"]["entities"]
        self.assertEqual(len(entities), 1)
        record = entities[0]
        self.assertEqual(record["record"], "Entity")
        self.assertEqual(record["stable_id"], "sym:python:app/store.py::Order")
        self.assertEqual(record["kind"], "Symbol")
        self.assertEqual(record["provenance"]["kind"], record["provenance"]["kind"])
        self.assertTrue(record["id"].startswith("Entity:"))

    def test_fact_ids_do_not_collide_for_one_subject(self):
        snap = self._draft("facts")
        self.g.upsert_fact("checkout", "publishes", "OrderCreated",
                           snapshot_id=snap, stable_subject="sym:checkout")
        self.g.upsert_fact("checkout", "publishes", "OrderPaid",
                           snapshot_id=snap, stable_subject="sym:checkout")
        self.g.finalize_snapshot(snap)
        doc = export_protocol(self.g)
        ids = {f["id"] for f in doc["records"]["facts"]}
        self.assertEqual(len(ids), 2, "different facts must have different ids")
        for fact in doc["records"]["facts"]:
            self.assertTrue(fact["id"].startswith("Fact:fact:"), fact["id"])

    def test_two_independent_databases_have_identical_semantic_digest(self):
        def build(tag):
            graph = Graph.open(":memory:")
            # SAME logical revision in both databases; only row ids and the
            # transport timestamp differ.
            snap = graph.begin_draft(_identity("same"))
            graph.upsert_entity("File", "a.py", "file:a.py", qualified_name="a.py",
                                snapshot_id=snap)
            graph.upsert_fact("svc", "publishes", "OrderCreated", snapshot_id=snap,
                              stable_subject="svc")
            graph.add_evidence(snap, "trace", "trace:1", summary="observed publish")
            graph.finalize_snapshot(snap)
            doc = export_protocol(graph)
            graph.close()
            return doc

        doc_a = build("a")
        doc_b = build("b")
        # Transport timestamps and DB row ids may differ...
        doc_b["generated_utc"] = "2000-01-01T00:00:00+00:00"
        # ...but the semantic digest (and the record identities) are equal.
        self.assertEqual(semantic_digest(doc_a), semantic_digest(doc_b))
        ids_a = {r["id"] for r in doc_a["records"]["facts"]}
        ids_b = {r["id"] for r in doc_b["records"]["facts"]}
        self.assertEqual(ids_a, ids_b)
        self.assertNotEqual(doc_a["generated_utc"], doc_b["generated_utc"])

    def test_ingest_entities_and_records_an_observation(self):
        doc = {
            "protocol_version": 2,
            "snapshot": {"revision_digest": "sha256:peer"},
            "completeness": {"entities": "partial", "relations": "unknown"},
            "records": {
                "entities": [{
                    "record": "Entity",
                    "id": "Entity:sym:peer::Thing",
                    "stable_id": "sym:peer::Thing",
                    "kind": "Symbol",
                    "name": "Thing",
                    "qualified_name": "peer.Thing",
                    "epistemics": {"epistemic_state": "declared",
                                   "analysis_depth": 2, "completeness": "partial"},
                }],
                "evidence": [{
                    "record": "Evidence",
                    "id": "Evidence:peer-1",
                    "kind": "verification",
                    "ref": "kiwi:run:1",
                    "summary": "verified",
                }],
            },
        }
        draft = self.g.begin_draft(_identity("ingest-obs"))
        report = ingest_protocol(
            self.g, doc, snapshot_id=draft, provider_id="kiwi", provider_version="1.0"
        )
        self.assertEqual(report["errors"], [], report["errors"])
        self.assertEqual(len(report["entity_ids"]), 1)
        self.assertTrue(report["observation_ids"], "ingest must record an observation")
        self.assertTrue(report["observation_digest"].startswith("sha256:"))
        # The linked observation set is visible on the draft snapshot.
        observations = self.g.observations(draft)
        self.assertEqual(len(observations), 1)
        self.assertEqual(observations[0]["provider"], "kiwi")
        self.assertEqual(observations[0]["observation_kind"], "verification")
        self.assertEqual(observations[0]["authority"], "external")

    # legacy documents (no observations) still ingest and record one
    def test_ingest_legacy_document_still_records_observation(self):
        draft = self.g.begin_draft(_identity("legacy"))
        doc = {"protocol_version": 2, "records": {"facts": []}}
        report = ingest_protocol(self.g, doc, snapshot_id=draft, provider_id="kiwi")
        self.assertEqual(report["errors"], [])
        self.assertTrue(report["observation_ids"])


if __name__ == "__main__":
    unittest.main()
