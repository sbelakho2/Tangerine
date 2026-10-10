"""Tests for the neutral exchange protocol projection (system_intel.protocol)."""

import json
import unittest

from system_intel.graph import Graph
from system_intel.protocol import (
    PROTOCOL_VERSION,
    Requirement,
    export_protocol,
    protocol_json,
)


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.g = Graph.open(":memory:")
        self.snap = self.g.ensure_snapshot("/repo", "deadbeef")
        a = self.g.upsert_entity(
            "Service", "orders", "shop::orders", file="src/orders.py", tier=1
        )
        b = self.g.upsert_entity(
            "Symbol", "capture", "shop::orders::capture", tier=2
        )
        self.g.upsert_relation(
            b, a, "depends_on", tier=2, provenance="inferred", confidence=0.8
        )
        self.g.upsert_fact(
            "orders", "publishes", "OrderCreated", tier=1, provenance="observed"
        )
        # a low-confidence / uncertain fact must surface as a Risk
        self.g.upsert_fact(
            "checkout",
            "appears_idempotent",
            "true",
            tier=3,
            provenance="inferred",
            confidence=0.55,
            derived_from=["runtime traces"],
            uncertainty="one external payment path not observed",
        )
        self.g.add_invariant(
            "payment capture must be idempotent",
            component_qn="shop::orders",
            provenance="declared",
        )
        self.g.add_contract(
            "event", "OrderCreated", component_qn="shop::orders", format="json"
        )
        self.g.add_incident(
            "capture double-charged on retry", component_qn="shop::orders"
        )
        self.g.add_change(
            "abc123", "harden capture retry", files=["src/orders.py"], outcome="merged"
        )

    def tearDown(self):
        self.g.close()

    def test_protocol_version_and_sections(self):
        doc = export_protocol(self.g, self.snap)
        self.assertEqual(doc["protocol_version"], PROTOCOL_VERSION)
        self.assertEqual(doc["snapshot"]["commit_sha"], "deadbeef")
        recs = doc["records"]
        for key in (
            "requirements",
            "facts",
            "claims",
            "invariants",
            "contracts",
            "risks",
            "changes",
            "evidence",
            "counterexamples",
            "relations",
        ):
            self.assertIn(key, recs)
        self.assertEqual(len(recs["facts"]), 2)
        self.assertEqual(len(recs["invariants"]), 1)
        self.assertEqual(len(recs["contracts"]), 1)
        self.assertEqual(len(recs["changes"]), 1)

    def test_relations_carry_qualified_names(self):
        doc = export_protocol(self.g, self.snap)
        rels = doc["records"]["relations"]
        self.assertEqual(len(rels), 1)
        self.assertEqual(rels[0]["src"], "shop::orders::capture")
        self.assertEqual(rels[0]["dst"], "shop::orders")
        self.assertEqual(rels[0]["kind"], "depends_on")

    def test_incident_becomes_risk_with_evidence(self):
        doc = export_protocol(self.g, self.snap)
        recs = doc["records"]
        incidents = [
            c for c in recs["claims"] if "capture double-charged" in c["text"]
        ]
        self.assertEqual(incidents, [])  # incidents are evidence, not claims
        self.assertEqual(len(recs["evidence"]), 1)
        risk = next(r for r in recs["risks"] if "double-charged" in r["description"])
        self.assertEqual(risk["evidence"], [recs["evidence"][0]["id"]])
        self.assertEqual(risk["state"], "historically_supported")

    def test_uncertain_fact_becomes_risk(self):
        doc = export_protocol(self.g, self.snap)
        risks = doc["records"]["risks"]
        uncertain = [
            r for r in risks if r["description"] == "one external payment path not observed"
        ]
        self.assertEqual(len(uncertain), 1)
        self.assertEqual(uncertain[0]["state"], "uncertain")
        self.assertAlmostEqual(uncertain[0]["confidence"]["value"], 0.55, places=6)

    def test_stale_entity_state_maps_to_stale(self):
        seen = {"Service": {"shop::orders"}, "Symbol": set()}
        self.g.stale_sweep(self.snap, seen)
        self.g.upsert_fact(
            "stale-svc", "reads", "x", tier=1, provenance="observed"
        )
        # mark that fact stale directly through the row
        conn = self.g._require_conn()
        fact_id = conn.execute(
            "SELECT id FROM fact WHERE subject = 'stale-svc'"
        ).fetchone()["id"]
        conn.execute("UPDATE fact SET stale = 1 WHERE id = ?", (fact_id,))
        conn.commit()
        doc = export_protocol(self.g, self.snap)
        stale = [f for f in doc["records"]["facts"] if f["subject"] == "stale-svc"]
        self.assertEqual(stale[0]["state"], "stale")

    def test_requirements_are_caller_supplied(self):
        req = Requirement(
            id="req:1", statement="no double charge", status="met", refs=["req-doc"]
        )
        doc = export_protocol(self.g, self.snap, requirements=[req])
        self.assertEqual(
            doc["records"]["requirements"][0]["statement"], "no double charge"
        )
        self.assertEqual(doc["records"]["requirements"][0]["record"], "Requirement")

    def test_protocol_json_round_trips(self):
        text = protocol_json(self.g, self.snap)
        doc = json.loads(text)
        self.assertEqual(doc["protocol_version"], PROTOCOL_VERSION)

    def test_empty_database_raises(self):
        empty = Graph.open(":memory:")
        with self.assertRaises(ValueError):
            export_protocol(empty)
        empty.close()


if __name__ == "__main__":
    unittest.main()
