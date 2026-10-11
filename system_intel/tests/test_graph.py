"""Unit tests for the core System Intelligence graph v2 (stdlib only)."""

import os
import sqlite3
import tempfile
import unittest

from system_intel.graph import (
    Graph,
    SnapshotError,
    identity_revision_digest,
)


def _identity(revision="sha-1", tree="tree-1"):
    ident = {
        "repo_identity": "repo-1",
        "source_revision": revision,
        "tree_digest": tree,
        "semantic_configuration": "{}",
        "provider_set_digest": "psd-1",
    }
    ident["revision_digest"] = identity_revision_digest(ident)
    return ident


class GraphV2TestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self._tmp.name, "intel.db")
        self.graph = Graph.open(self.db_path)
        self.snap = self.graph.begin_draft(_identity())

    def tearDown(self):
        if self.graph is not None:
            self.graph.close()
        self._tmp.cleanup()

    # ------------------------------------------------------------ snapshots

    def test_schema_version_and_draft_identity(self):
        stats = self.graph.stats(self.snap)
        self.assertEqual(stats["schema_version"], 3)
        self.assertEqual(stats["state"], "draft")

    def test_begin_draft_idempotent_and_finalized_conflict(self):
        again = self.graph.begin_draft(_identity())
        self.assertEqual(self.snap, again)
        self.graph.finalize_snapshot(self.snap)
        with self.assertRaises(SnapshotError):
            self.graph.begin_draft(_identity())
        # a different tuple still works
        other = self.graph.begin_draft(_identity("sha-2", "tree-2"))
        self.assertNotEqual(self.snap, other)

    def test_finalize_snapshot_once(self):
        self.graph.finalize_snapshot(self.snap)
        row = self.graph.snapshot_for(_identity())
        self.assertEqual(row["state"], "finalized")
        self.assertIsNotNone(row["finalized_utc"])
        with self.assertRaises(SnapshotError):
            self.graph.finalize_snapshot(self.snap)

    def test_latest_finalized_snapshot_is_deterministic(self):
        self.assertEqual(self.graph.latest_finalized_snapshot(), None)
        self.graph.finalize_snapshot(self.snap)
        s2 = self.graph.begin_draft(_identity("sha-2", "tree-2"))
        self.assertEqual(self.graph.latest_finalized_snapshot()["id"], self.snap)
        self.graph.finalize_snapshot(s2)
        self.assertEqual(self.graph.latest_finalized_snapshot()["id"], s2)
        self.assertEqual(
            self.graph.snapshot_by_revision(_identity()["revision_digest"])["id"], self.snap
        )

    def test_abort_draft_removes_rows(self):
        draft = self.graph.begin_draft(_identity("sha-9", "tree-9"))
        self.graph.upsert_entity("Module", "x", "module:x", snapshot_id=draft)
        self.graph.abort_draft(draft)
        self.assertIsNone(self.graph.snapshot_for(_identity("sha-9", "tree-9")))
        conn = self.graph._require_conn()
        self.assertEqual(conn.execute(
            "SELECT COUNT(*) AS n FROM entity WHERE snapshot_id=?", (draft,)
        ).fetchone()["n"], 0)
        with self.assertRaises(SnapshotError):
            self.graph.finalize_snapshot(draft)

    def test_abort_finalized_rejected(self):
        self.graph.finalize_snapshot(self.snap)
        with self.assertRaises(SnapshotError):
            self.graph.abort_draft(self.snap)

    # -------------------------------------------------------------- upserts

    def test_upsert_entity_by_stable_id_idempotent(self):
        first = self.graph.upsert_entity(
            "Symbol", "run", "sym:python:pkg/mod.py::run", qualified_name="pkg.mod.run",
            file="pkg/mod.py", line=10, attrs={"visibility": "public"},
        )
        second = self.graph.upsert_entity(
            "Symbol", "run", "sym:python:pkg/mod.py::run", qualified_name="pkg.mod.run",
            file="pkg/mod.py", line=11, tier=2, provenance="inferred", confidence=0.75,
            derived_from=["fact:1", "fact:2"], attrs={"visibility": "private"},
        )
        self.assertEqual(first, second)
        rows = self.graph.entities_by_kind("Symbol")
        self.assertEqual(len(rows), 1)
        ent = rows[0]
        self.assertEqual(ent["id"], first)
        self.assertEqual(ent["stable_id"], "sym:python:pkg/mod.py::run")
        self.assertEqual(ent["line"], 11)
        self.assertEqual(ent["tier"], 2)
        self.assertEqual(ent["provenance"], "inferred")
        self.assertEqual(ent["epistemic_state"], "inferred")
        self.assertAlmostEqual(ent["confidence"], 0.75)
        self.assertEqual(ent["derived_from"], ["fact:1", "fact:2"])
        self.assertEqual(ent["attrs"], {"visibility": "private"})
        self.assertEqual(self.graph.find_entity("Symbol", "pkg.mod.run")["id"], first)

    def test_upsert_entity_derives_stable_id_when_omitted(self):
        eid = self.graph.upsert_entity("File", "x.py", qualified_name="x.py")
        row = self.graph.entity_row(eid)
        self.assertEqual(row["stable_id"], "file:x.py")
        repo = self.graph.upsert_entity("Repository", "r", qualified_name=".")
        self.assertEqual(self.graph.entity_row(repo)["stable_id"], "repo:.")

    def test_typed_stable_id_collision_resolves_by_key(self):
        file_id = self.graph.upsert_entity(
            "File", "x.py", "file:x.py", qualified_name="x.py"
        )
        test_id = self.graph.upsert_entity(
            "Test", "x.py", "test:x.py::x.py", qualified_name="x.py"
        )
        self.assertNotEqual(file_id, test_id)
        self.assertIsNone(self.graph.find_entity_by_qn("x.py"))  # ambiguous qn
        hit = self.graph.resolve_qn("x.py", kind="Test", stable_id="test:x.py::x.py")
        self.assertEqual(hit["id"], test_id)

    def test_relation_and_fact_idempotent(self):
        src = self.graph.upsert_entity("Module", "a", "module:a")
        dst = self.graph.upsert_entity("Module", "b", "module:b")
        r1 = self.graph.upsert_relation(src, dst, "depends_on", confidence=0.5)
        r2 = self.graph.upsert_relation(src, dst, "depends_on", confidence=0.9)
        self.assertEqual(r1, r2)
        edges = self.graph.edges_by_type("depends_on")
        self.assertEqual(len(edges), 1)
        self.assertAlmostEqual(edges[0]["confidence"], 0.9)
        self.assertEqual(edges[0]["src_key"], "module:a")
        self.assertEqual(edges[0]["dst_key"], "module:b")
        self.assertEqual(edges[0]["resolved"], 1)

        f1 = self.graph.upsert_fact("checkout", "publishes", "OrderCreated")
        f2 = self.graph.upsert_fact("checkout", "publishes", "OrderCreated",
                                    provenance="declared", confidence=0.8)
        self.assertEqual(f1, f2)
        stats = self.graph.stats(self.snap)
        self.assertEqual(stats["facts"], 1)
        self.assertEqual(stats["relations_by_kind"], {"depends_on": 1})

    def test_runtime_provenance_maps_to_observed_depth4(self):
        eid = self.graph.upsert_entity("Symbol", "hot", "sym:x:hot", provenance="runtime")
        row = self.graph.entity_row(eid)
        self.assertEqual(row["epistemic_state"], "observed")
        self.assertEqual(row["analysis_depth"], 4)
        fid = self.graph.upsert_fact("hot", "called", "100x", provenance="runtime")
        fact = self.graph._require_conn().execute(
            "SELECT epistemic_state, analysis_depth FROM fact WHERE id=?", (fid,)
        ).fetchone()
        self.assertEqual(fact["epistemic_state"], "observed")
        self.assertEqual(fact["analysis_depth"], 4)

    def test_relation_unresolved_edge_and_query(self):
        src = self.graph.upsert_entity("File", "a.py", "file:a.py", qualified_name="a.py")
        rel_id = self.graph.upsert_relation(
            src, None, "imports", snapshot_id=self.snap,
            src_key="file:a.py", dst_key="pkg::Missing", resolved=0,
        )
        edge_id = self.graph.add_unresolved_edge(
            self.snap, "file:a.py", "pkg::Missing", "imports",
            provider="generic-static", provider_revision="2.0",
            candidates=["sym:python:pkg.py::Missing", "module:pkg"],
            confidence=0.2,
        )
        self.assertGreater(rel_id, 0)
        self.assertGreater(edge_id, 0)
        rows = self.graph.unresolved_edges(self.snap)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["dst_raw"], "pkg::Missing")
        self.assertEqual(rows[0]["candidates"],
                         ["sym:python:pkg.py::Missing", "module:pkg"])
        edges = self.graph.edges_by_type("imports")
        self.assertEqual(len(edges), 1)
        self.assertEqual(edges[0]["resolved"], 0)
        self.assertIsNone(edges[0]["dst"])
        comp = self.graph.completeness(self.snap)
        self.assertEqual(comp["unresolved"]["count"], 1)
        self.assertEqual(comp["families"]["relations"], "partial")

    # ------------------------------------------------------------ neighbors

    def test_neighbors_directions_filter(self):
        a = self.graph.upsert_entity("Module", "a", "module:a")
        b = self.graph.upsert_entity("Module", "b", "module:b")
        c = self.graph.upsert_entity("Module", "c", "module:c")
        self.graph.upsert_relation(a, b, "calls")
        self.graph.upsert_relation(a, c, "imports")

        both = self.graph.neighbors(a)
        self.assertEqual(len(both), 2)
        self.assertEqual({rel["direction"] for rel in both}, {"out"})

        incoming = self.graph.neighbors(b, direction="in")
        self.assertEqual(len(incoming), 1)
        self.assertEqual(incoming[0]["direction"], "in")
        self.assertEqual(incoming[0]["entity"]["stable_id"], "module:a")

        filtered = self.graph.neighbors(a, kind="calls")
        self.assertEqual(len(filtered), 1)
        self.assertEqual(filtered[0]["entity"]["stable_id"], "module:b")

    # ---------------------------------------------------------- immutability

    def test_finalized_snapshot_is_immutable(self):
        self.graph.upsert_entity("Module", "a", "module:a")
        self.graph.finalize_snapshot(self.snap)
        with self.assertRaises(sqlite3.IntegrityError):
            self.graph.upsert_entity("Module", "b", "module:b", snapshot_id=self.snap)
        conn = self.graph._require_conn()
        with self.assertRaises(sqlite3.IntegrityError):
            conn.execute("UPDATE entity SET name='z' WHERE snapshot_id=?", (self.snap,))
        with self.assertRaises(sqlite3.IntegrityError):
            conn.execute("DELETE FROM entity WHERE snapshot_id=?", (self.snap,))
        conn.rollback()

    def test_cross_snapshot_relation_insert_raises(self):
        s2 = self.graph.begin_draft(_identity("sha-2", "tree-2"))
        e1 = self.graph.upsert_entity("Module", "a", "module:a", snapshot_id=self.snap)
        e2 = self.graph.upsert_entity("Module", "b", "module:b", snapshot_id=s2)
        with self.assertRaises(sqlite3.IntegrityError):
            self.graph.upsert_relation(e1, e2, "calls", snapshot_id=self.snap)
        self.graph._require_conn().rollback()
        # same-snapshot relation still works
        e3 = self.graph.upsert_entity("Module", "c", "module:c", snapshot_id=self.snap)
        self.graph.upsert_relation(e1, e3, "calls", snapshot_id=self.snap)

    # ----------------------------------------------------------------- batch

    def test_batch_commits_on_success_rolls_back_on_exception(self):
        with self.assertRaises(RuntimeError):
            with self.graph.batch():
                self.graph.upsert_entity("Module", "throwaway", "module:throwaway")
                raise RuntimeError("boom")
        self.assertIsNone(self.graph.find_entity("Module", "module:throwaway"))
        with self.graph.batch():
            self.graph.upsert_entity("Module", "kept", "module:kept")
        self.assertIsNotNone(self.graph.find_entity("Module", "module:kept"))

    def test_close_rolls_back_dirty_transaction(self):
        conn = self.graph._require_conn()
        conn.execute(
            "INSERT INTO entity (snapshot_id, kind, name, qualified_name, stable_id) "
            "VALUES (?, ?, ?, ?, ?)",
            (self.snap, "Module", "dirty", "dirty", "module:dirty"),
        )
        self.assertTrue(conn.in_transaction)
        self.graph.close()
        self.graph = None
        with Graph.open(self.db_path, create=False) as reopened:
            n = reopened._require_conn().execute(
                "SELECT COUNT(*) AS n FROM entity"
            ).fetchone()["n"]
            self.assertEqual(n, 0)

    def test_context_manager(self):
        with Graph.open(self.db_path, create=False) as graph:
            self.assertEqual(graph.stats(self.snap)["schema_version"], 3)

    # ------------------------------------------------------- write/read gate

    def test_export_and_stats_raise_without_finalized_snapshot(self):
        with self.assertRaises(SnapshotError):
            self.graph.export_json()
        with self.assertRaises(SnapshotError):
            self.graph.stats()

    def test_export_json_never_unions_snapshots(self):
        a = self.graph.upsert_entity("Module", "a", "module:a")
        self.graph.finalize_snapshot(self.snap)
        s2 = self.graph.begin_draft(_identity("sha-2", "tree-2"))
        self.graph.upsert_entity("Module", "b", "module:b", snapshot_id=s2)
        self.graph.finalize_snapshot(s2)

        export = self.graph.export_json()
        self.assertEqual([e["stable_id"] for e in export["entities"]], ["module:b"])
        self.assertEqual(len(export["snapshots"]), 1)
        self.assertEqual(export["snapshot"]["id"], s2)
        old = self.graph.export_json(self.snap)
        self.assertEqual([e["stable_id"] for e in old["entities"]], ["module:a"])
        self.assertEqual(self.graph.stats()["entities_by_kind"], {"Module": 1})
        self.assertEqual(a, old["entities"][0]["id"])

    # ---------------------------------------------------------------- search

    def test_find_path(self):
        p1 = self.graph.upsert_entity("Symbol", "p1", "sym:x:1")
        p2 = self.graph.upsert_entity("Symbol", "p2", "sym:x:2")
        p3 = self.graph.upsert_entity("Symbol", "p3", "sym:x:3")
        self.graph.upsert_relation(p1, p2, "calls")
        self.graph.upsert_relation(p2, p3, "calls")
        self.assertEqual(self.graph.find_path(p1, p3), [p1, p2, p3])
        self.assertEqual(self.graph.find_path(p1, p3, kinds=["calls"]), [p1, p2, p3])
        self.assertIsNone(self.graph.find_path(p3, p1))
        self.assertIsNone(self.graph.find_path(p1, p3, max_depth=1))
        self.assertEqual(self.graph.find_path(p1, p1), [p1])

    # --------------------------------------------------- impact/dependencies

    def test_impact_and_dependencies_diamond(self):
        a = self.graph.upsert_entity("Module", "a", "module:a")
        b = self.graph.upsert_entity("Module", "b", "module:b")
        c = self.graph.upsert_entity("Module", "c", "module:c")
        d = self.graph.upsert_entity("Module", "d", "module:d")
        for src, dst in ((a, b), (b, c), (a, d), (d, c)):
            self.graph.upsert_relation(src, dst, "depends_on")

        deps = self.graph.dependencies(a)
        self.assertEqual([level["depth"] for level in deps["levels"]], [0, 1, 2])
        self.assertEqual([e["qualified_name"] for e in deps["levels"][1]["entities"]],
                         ["module:b", "module:d"])
        self.assertEqual(len(deps["impacted"]), 4)
        self.assertIn("completeness", deps)
        self.assertIn("relations", deps["completeness"]["families"])

        impact = self.graph.impact(c)
        self.assertEqual([e["qualified_name"] for e in impact["levels"][1]["entities"]],
                         ["module:b", "module:d"])
        self.assertEqual(len(impact["impacted"]), 4)
        self.assertEqual(impact["roots"][0]["id"], c)

        self.graph.add_contract("api", "B-API", component_qn="module:b")
        self.graph.add_invariant("b must stay pure", component_qn="module:b")
        self.graph.add_incident("b regressed once", component_qn="module:b")
        enriched = self.graph.impact(c)
        self.assertEqual([con["name"] for con in enriched["contracts"]], ["B-API"])
        self.assertEqual(len(enriched["incidents"]), 1)

    def test_tests_edges_only_sourced_by_test_entities(self):
        target = self.graph.upsert_entity("Module", "b", "module:b")
        bogus = self.graph.upsert_entity("Symbol", "b", "sym:x:b")
        test = self.graph.upsert_entity("Test", "t", "test:t.py::t", qualified_name="t.py")
        self.graph.upsert_relation(bogus, target, "tests", src_key="sym:x:b")
        self.graph.upsert_relation(test, target, "tests",
                                   src_key="test:t.py::t",
                                   epistemic_state="observed")
        impact = self.graph.impact(target)
        self.assertEqual([t["stable_id"] for t in impact["tests"]],
                         ["test:t.py::t"])
        self.assertEqual(impact["tests"][0]["kind"], "Test")

    # -------------------------------------------------------- change_surface

    def test_change_surface_exact_and_suffix(self):
        self.graph.upsert_entity("Module", "A", "module:pkg.mod.A",
                                 qualified_name="pkg.mod.A")
        self.graph.upsert_entity("Symbol", "B", "sym:x:pkg.mod.B",
                                 qualified_name="pkg.mod.B")
        surface = self.graph.change_surface(["pkg.mod.A", "mod.B", "does.not.exist"])
        self.assertEqual(sorted(surface["matched"]), ["mod.B", "pkg.mod.A"])
        self.assertEqual(surface["unmatched"], ["does.not.exist"])
        # the suffix hit is FUZZY (namespace-boundary aware), the exact one
        # is not; a mere textual resemblance such as foo.barbaz vs bar is
        # not a match at all.
        self.assertEqual(surface["fuzzy"], ["mod.B"])
        self.graph.upsert_entity("Symbol", "barbaz", "sym:x:foo.barbaz",
                                 qualified_name="foo.barbaz")
        no_match = self.graph.change_surface(["bar"])
        self.assertEqual(no_match["matched"], {})
        self.assertEqual(no_match["fuzzy"], [])
        self.assertEqual(no_match["unmatched"], ["bar"])
        self.assertEqual(len(surface["impacted"]), 2)
        self.assertIn("completeness", surface)

    # --------------------------------------------------- support / providers

    def test_record_provider_and_accumulate_support(self):
        self.graph.record_provider(self.snap, "p", "1.0",
                                   {"entities": "complete", "relations": "partial"})
        self.graph.record_provider(self.snap, "p", "1.1",
                                   {"entities": "complete", "relations": "partial"})
        conn = self.graph._require_conn()
        self.assertEqual(conn.execute(
            "SELECT COUNT(*) AS n FROM provider_record"
        ).fetchone()["n"], 1)
        self.assertEqual(conn.execute(
            "SELECT provider_version FROM provider_record"
        ).fetchone()["provider_version"], "1.1")

        eid = self.graph.upsert_entity("Module", "a", "module:a")
        s1 = self.graph.accumulate_support(
            self.snap, "entity", eid, provider="p", detail="observed in source"
        )
        s2 = self.graph.accumulate_support(
            self.snap, "entity", eid, provider="p", detail="observed again",
            confidence=0.5,
        )
        self.assertEqual(s1, s2)
        comp = self.graph.completeness(self.snap)
        self.assertEqual(comp["providers"]["p"]["entities"], "complete")
        self.assertEqual(comp["families"]["relations"], "partial")

    # ------------------------------------------------------------------ diff

    def test_diff_snapshots(self):
        a = self.graph.upsert_entity("Module", "a", "module:a")
        b = self.graph.upsert_entity("Module", "b", "module:b")
        self.graph.upsert_relation(a, b, "depends_on")
        self.graph.upsert_fact("a", "uses", "b")
        self.graph.finalize_snapshot(self.snap)

        s2 = self.graph.begin_draft(_identity("sha-2", "tree-2"))
        b2 = self.graph.upsert_entity("Module", "b", "module:b", snapshot_id=s2, line=3)
        c = self.graph.upsert_entity("Module", "c", "module:c", snapshot_id=s2)
        self.graph.upsert_relation(b2, c, "depends_on", snapshot_id=s2)
        self.graph.upsert_fact("b", "uses", "c", snapshot_id=s2)
        self.graph.finalize_snapshot(s2)

        diff = self.graph.diff_snapshots(self.snap, s2)
        self.assertEqual(diff["added"], ["module:c"])
        self.assertEqual(diff["removed"], ["module:a"])
        self.assertEqual(diff["changed"], ["module:b"])
        self.assertEqual(diff["relations_removed"],
                         [{"src": "module:a", "dst": "module:b", "kind": "depends_on"}])
        self.assertIn("a|uses|b", diff["facts_removed"])
        self.assertIn("b|uses|c", diff["facts_added"])
        self.assertIn("relations", diff["completeness_delta"])

    # ------------------------------------------------------- deprecated sweep

    def test_stale_sweep_is_draft_only(self):
        self.graph.upsert_entity("Symbol", "s1", "sym:x:s1")
        self.graph.finalize_snapshot(self.snap)
        with self.assertRaises(SnapshotError):
            self.graph.stale_sweep(self.snap, {"Symbol": set()})
        s2 = self.graph.begin_draft(_identity("sha-2", "tree-2"))
        self.graph.upsert_entity("Symbol", "s1", "sym:x:s1", snapshot_id=s2)
        self.graph.upsert_entity("Symbol", "s2", "sym:x:s2", snapshot_id=s2)
        swept = self.graph.stale_sweep(s2, {"Symbol": {"sym:x:s1"}})
        self.assertEqual(swept, 1)


if __name__ == "__main__":
    unittest.main()
