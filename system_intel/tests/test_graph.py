"""Unit tests for the core System Intelligence graph (stdlib only)."""

import os
import tempfile
import unittest

from system_intel.graph import Graph


class GraphTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self._tmp.name, "intel.db")
        self.repo_root = os.path.join(self._tmp.name, "repo")
        os.makedirs(self.repo_root, exist_ok=True)
        self.graph = Graph.open(self.db_path)
        self.snapshot_id = self.graph.ensure_snapshot(self.repo_root, "sha-1")

    def tearDown(self):
        if self.graph is not None:
            self.graph.close()
        self._tmp.cleanup()

    # ------------------------------------------------------------ snapshots

    def test_schema_version_and_snapshot_idempotent(self):
        stats = self.graph.stats()
        self.assertGreaterEqual(stats["schema_version"], 1)
        again = self.graph.ensure_snapshot(self.repo_root, "sha-1")
        self.assertEqual(self.snapshot_id, again)
        other = self.graph.ensure_snapshot(self.repo_root, "sha-2")
        self.assertNotEqual(self.snapshot_id, other)
        self.assertEqual(self.graph.stats()["snapshots"], 2)

    # -------------------------------------------------------------- upserts

    def test_upsert_entity_idempotent_and_roundtrip(self):
        first = self.graph.upsert_entity(
            "Symbol", "run", "pkg.mod.run", file="pkg/mod.py", line=10,
            attrs={"visibility": "public"},
        )
        second = self.graph.upsert_entity(
            "Symbol", "run", "pkg.mod.run", file="pkg/mod.py", line=11,
            tier=2, provenance="inferred", confidence=0.75,
            derived_from=["fact:1", "fact:2"], attrs={"visibility": "private"},
        )
        self.assertEqual(first, second)
        rows = self.graph.entities_by_kind("Symbol")
        self.assertEqual(len(rows), 1)
        ent = rows[0]
        self.assertEqual(ent["id"], first)
        self.assertEqual(ent["line"], 11)
        self.assertEqual(ent["tier"], 2)
        self.assertEqual(ent["provenance"], "inferred")
        self.assertAlmostEqual(ent["confidence"], 0.75)
        self.assertEqual(ent["derived_from"], ["fact:1", "fact:2"])
        self.assertEqual(ent["attrs"], {"visibility": "private"})
        self.assertFalse(ent["stale"])
        self.assertEqual(self.graph.find_entity("Symbol", "pkg.mod.run")["id"], first)

    def test_relation_and_fact_idempotent(self):
        src = self.graph.upsert_entity("Module", "a", "pkg.a")
        dst = self.graph.upsert_entity("Module", "b", "pkg.b")
        r1 = self.graph.upsert_relation(src, dst, "depends_on", confidence=0.5)
        r2 = self.graph.upsert_relation(src, dst, "depends_on", confidence=0.9)
        self.assertEqual(r1, r2)
        edges = self.graph.edges_by_type("depends_on")
        self.assertEqual(len(edges), 1)
        self.assertAlmostEqual(edges[0]["confidence"], 0.9)
        self.assertEqual(edges[0]["src"]["qualified_name"], "pkg.a")
        self.assertEqual(edges[0]["dst"]["qualified_name"], "pkg.b")

        f1 = self.graph.upsert_fact("checkout", "publishes", "OrderCreated")
        f2 = self.graph.upsert_fact("checkout", "publishes", "OrderCreated",
                                    provenance="declared", confidence=0.8)
        self.assertEqual(f1, f2)
        stats = self.graph.stats()
        self.assertEqual(stats["facts"], 1)
        self.assertEqual(stats["relations_by_kind"], {"depends_on": 1})

    # ------------------------------------------------------------ neighbors

    def test_neighbors_directions_filter_and_stale(self):
        a = self.graph.upsert_entity("Module", "a", "pkg.a")
        b = self.graph.upsert_entity("Module", "b", "pkg.b")
        c = self.graph.upsert_entity("Module", "c", "pkg.c")
        self.graph.upsert_relation(a, b, "calls")
        self.graph.upsert_relation(a, c, "imports")

        both = self.graph.neighbors(a)
        self.assertEqual(len(both), 2)
        self.assertEqual({rel["direction"] for rel in both}, {"out"})

        incoming = self.graph.neighbors(b, direction="in")
        self.assertEqual(len(incoming), 1)
        self.assertEqual(incoming[0]["direction"], "in")
        self.assertEqual(incoming[0]["entity"]["qualified_name"], "pkg.a")

        filtered = self.graph.neighbors(a, kind="calls")
        self.assertEqual(len(filtered), 1)
        self.assertEqual(filtered[0]["kind"], "calls")
        self.assertEqual(filtered[0]["entity"]["qualified_name"], "pkg.b")

        self.graph.mark_entity_stale(b)
        self.assertEqual(len(self.graph.neighbors(a)), 1)
        self.assertEqual(len(self.graph.neighbors(a, include_stale=True)), 2)

    # ------------------------------------------------------------ staleness

    def test_stale_sweep(self):
        s1 = self.graph.upsert_entity("Symbol", "s1", "pkg.s1")
        self.graph.upsert_entity("Symbol", "s2", "pkg.s2")
        s3 = self.graph.upsert_entity("Symbol", "s3", "pkg.s3")
        self.graph.upsert_entity("Module", "m", "pkg.m")

        stale_count = self.graph.stale_sweep(self.snapshot_id, {"Symbol": {"pkg.s1", "pkg.s2"}})
        self.assertEqual(stale_count, 1)
        self.assertFalse(self.graph.find_entity("Symbol", "pkg.s1")["stale"])
        self.assertTrue(self.graph.find_entity("Symbol", "pkg.s3")["stale"])
        self.assertIn("Symbol", self.graph.stats()["entities_by_kind"])
        self.assertFalse(self.graph.find_entity("Module", "pkg.m")["stale"])

        self.graph.mark_entity_fresh(s3)
        self.assertFalse(self.graph.find_entity("Symbol", "pkg.s3")["stale"])

        self.graph.mark_entity_stale(s3)
        self.graph.upsert_entity("Symbol", "s3", "pkg.s3")
        self.assertFalse(self.graph.find_entity("Symbol", "pkg.s3")["stale"])
        self.assertEqual(s1, self.graph.find_entity("Symbol", "pkg.s1")["id"])

        swept_all = self.graph.stale_sweep(self.snapshot_id, {"Symbol": set()})
        self.assertEqual(swept_all, 3)

    # -------------------------------------------------------------- find_path

    def test_find_path(self):
        p1 = self.graph.upsert_entity("Symbol", "p1", "pkg.p1")
        p2 = self.graph.upsert_entity("Symbol", "p2", "pkg.p2")
        p3 = self.graph.upsert_entity("Symbol", "p3", "pkg.p3")
        self.graph.upsert_relation(p1, p2, "calls")
        self.graph.upsert_relation(p2, p3, "calls")

        self.assertEqual(self.graph.find_path(p1, p3), [p1, p2, p3])
        self.assertEqual(self.graph.find_path(p1, p3, kinds=["calls"]), [p1, p2, p3])
        self.assertIsNone(self.graph.find_path(p3, p1))
        self.assertIsNone(self.graph.find_path(p1, p3, max_depth=1))
        self.assertEqual(self.graph.find_path(p1, p1), [p1])

    # --------------------------------------------------- impact/dependencies

    def test_impact_and_dependencies_diamond(self):
        a = self.graph.upsert_entity("Module", "a", "pkg.a")
        b = self.graph.upsert_entity("Module", "b", "pkg.b")
        c = self.graph.upsert_entity("Module", "c", "pkg.c")
        d = self.graph.upsert_entity("Module", "d", "pkg.d")
        for src, dst in ((a, b), (b, c), (a, d), (d, c)):
            self.graph.upsert_relation(src, dst, "depends_on")

        deps = self.graph.dependencies(a)
        self.assertEqual([level["depth"] for level in deps["levels"]], [0, 1, 2])
        self.assertEqual([e["qualified_name"] for e in deps["levels"][1]["entities"]],
                         ["pkg.b", "pkg.d"])
        self.assertEqual([e["qualified_name"] for e in deps["levels"][2]["entities"]],
                         ["pkg.c"])
        self.assertEqual(len(deps["impacted"]), 4)

        impact = self.graph.impact(c)
        self.assertEqual([e["qualified_name"] for e in impact["levels"][1]["entities"]],
                         ["pkg.b", "pkg.d"])
        self.assertEqual([e["qualified_name"] for e in impact["levels"][2]["entities"]],
                         ["pkg.a"])
        self.assertEqual(len(impact["impacted"]), 4)
        self.assertEqual(impact["roots"][0]["id"], c)

        self.graph.add_contract("api", "B-API", component_qn="pkg.b")
        self.graph.add_invariant("b must stay pure", component_qn="pkg.b")
        self.graph.add_incident("b regressed once", component_qn="pkg.b")
        enriched = self.graph.impact(c)
        self.assertEqual([con["name"] for con in enriched["contracts"]], ["B-API"])
        self.assertEqual([inv["statement"] for inv in enriched["invariants"]],
                         ["b must stay pure"])
        self.assertEqual(len(enriched["incidents"]), 1)

    # -------------------------------------------------------- change_surface

    def test_change_surface_exact_and_suffix(self):
        self.graph.upsert_entity("Module", "A", "pkg.mod.A")
        self.graph.upsert_entity("Symbol", "B", "pkg.mod.B")
        surface = self.graph.change_surface(["pkg.mod.A", "mod.B", "does.not.exist"])
        self.assertEqual(sorted(surface["matched"]), ["mod.B", "pkg.mod.A"])
        self.assertEqual(surface["matched"]["pkg.mod.A"][0]["qualified_name"], "pkg.mod.A")
        self.assertEqual(surface["matched"]["mod.B"][0]["qualified_name"], "pkg.mod.B")
        self.assertEqual(surface["unmatched"], ["does.not.exist"])
        self.assertEqual(len(surface["impacted"]), 2)

    # ---------------------------------------------------------------- export

    def test_export_json(self):
        a = self.graph.upsert_entity("Module", "a", "pkg.a", derived_from=["fact:1"],
                                     attrs={"role": "core"})
        b = self.graph.upsert_entity("Module", "b", "pkg.b")
        self.graph.upsert_relation(a, b, "imports")
        self.graph.upsert_fact("pkg.a", "contains", "b")

        export = self.graph.export_json()
        self.assertEqual(len(export["entities"]), 2)
        self.assertEqual(len(export["relations"]), 1)
        self.assertEqual(len(export["facts"]), 1)
        entity_a = [e for e in export["entities"] if e["qualified_name"] == "pkg.a"][0]
        self.assertEqual(entity_a["derived_from"], ["fact:1"])
        self.assertEqual(entity_a["attrs"], {"role": "core"})
        self.assertEqual(export["relations"][0]["derived_from"], [])
        self.assertEqual(export["snapshots"][0]["commit_sha"], "sha-1")
        self.assertIsInstance(export["schema_version"], int)

    # ----------------------------------------------------------------- stats

    def test_stats_counts(self):
        a = self.graph.upsert_entity("Module", "a", "pkg.a")
        b = self.graph.upsert_entity("Module", "b", "pkg.b")
        self.graph.upsert_relation(a, b, "depends_on")
        self.graph.upsert_fact("a", "uses", "b")
        self.graph.upsert_fact("a", "owns", "b")
        self.graph.add_invariant("stay consistent")
        self.graph.add_contract("api", "A-API", component_qn="pkg.a")
        self.graph.add_incident("boom", component_qn="pkg.a")
        self.graph.add_change("cafebabe", "tweak", files=["pkg/a.py"], outcome="ok")

        stats = self.graph.stats()
        self.assertEqual(stats["entities_by_kind"], {"Module": 2})
        self.assertEqual(stats["relations_by_kind"], {"depends_on": 1})
        self.assertEqual(stats["facts"], 2)
        self.assertEqual(stats["invariants"], 1)
        self.assertEqual(stats["contracts"], 1)
        self.assertEqual(stats["incidents"], 1)
        self.assertEqual(stats["changes"], 1)
        self.assertEqual(stats["stale_entities"], 0)
        self.assertEqual(stats["stale_relations"], 0)

    # ------------------------------------------------------- context manager

    def test_context_manager_closes_cleanly(self):
        self.graph.close()
        self.graph = None
        with Graph.open(self.db_path) as graph:
            graph.ensure_snapshot(self.repo_root, "sha-1")
            graph.upsert_entity("Module", "a", "pkg.a")
        self.assertIsNone(graph._conn)
        graph.close()
        with Graph.open(self.db_path, create=False) as reopened:
            self.assertEqual(reopened.stats()["entities_by_kind"], {"Module": 1})


class StaleSweepChunkTests(unittest.TestCase):
    """stale_sweep must stay correct past the IN-clause chunk size (500)."""

    def test_chunked_sweep_marks_only_unseen(self):
        with Graph.open(":memory:") as graph:
            snap = graph.ensure_snapshot("/repo", "sha-chunk")
            total = 1200
            for i in range(total):
                graph.upsert_entity("Symbol", f"s{i}", f"m::s{i}", snapshot_id=snap)
            seen = {"Symbol": {f"m::s{i}" for i in range(600)}}
            graph.stale_sweep(snap, seen)
            stale = graph._require_conn().execute(
                "SELECT COUNT(*) AS n FROM entity WHERE stale=1"
            ).fetchone()["n"]
            self.assertEqual(stale, 600)
            # a full rescan resurrects every previously stale row
            graph.stale_sweep(
                snap, {"Symbol": {f"m::s{i}" for i in range(total)}}
            )
            stale = graph._require_conn().execute(
                "SELECT COUNT(*) AS n FROM entity WHERE stale=1"
            ).fetchone()["n"]
            self.assertEqual(stale, 0)


if __name__ == "__main__":
    unittest.main()
