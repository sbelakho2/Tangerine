"""Core v2 regression suite (INTERFACES.md §2/§3/§4).

Covers the reviewer items P0-1..P0-6 and the staleness redesign:

(a) two snapshots then reopen -> export_json returns ONLY the latest
(b) export_json/stats raise SnapshotError on an empty DB
(c) dirty-worktree identity = worktree:<sha>:<digest>; strict_clean raises
(d) non-git identity = content:<digest>
(e) failed scan leaves NO snapshot and NO rows
(f) finalized snapshot immutability
(g) cross-snapshot relation insert raises IntegrityError
(h) unresolved edge preserved with raw target/candidates
(i) typed endpoint collision (File and Test sharing a qualified_name)
(j) zero-entity scan finalizes with Repository-only
(k) runtime provenance maps to observed / analysis_depth 4
(l) removed file -> diff_snapshots shows removed entities AND relations AND facts
"""

import shutil
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path

from system_intel.graph import (
    Graph,
    SnapshotError,
    identity_revision_digest,
)
from system_intel.persist import compute_identity, scan

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "mini_repo"


def _identity(revision="sha-1", tree="tree-1", repo="repo-1"):
    ident = {
        "repo_identity": repo,
        "source_revision": revision,
        "tree_digest": tree,
        "semantic_configuration": "{}",
        "provider_set_digest": "psd",
    }
    ident["revision_digest"] = identity_revision_digest(ident)
    return ident


class CoreV2TestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="intel_v2_")
        self.root = Path(self.tmp)
        self.db = self.root / "graph.db"

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    # (a) -----------------------------------------------------------------
    def test_a_export_only_latest_snapshot_after_reopen(self):
        with Graph.open(self.db) as g:
            s1 = g.begin_draft(_identity("sha-1", "tree-1"))
            g.upsert_entity("File", "a.py", "file:a.py", qualified_name="a.py",
                            snapshot_id=s1)
            g.finalize_snapshot(s1)
            s2 = g.begin_draft(_identity("sha-2", "tree-2"))
            g.upsert_entity("File", "b.py", "file:b.py", qualified_name="b.py",
                            snapshot_id=s2)
            g.finalize_snapshot(s2)

        with Graph.open(self.db, create=False) as g:
            export = g.export_json()
            self.assertEqual([e["stable_id"] for e in export["entities"]], ["file:b.py"])
            self.assertEqual(len(export["snapshots"]), 1)
            self.assertEqual(export["snapshot"]["id"], s2)
            self.assertNotIn(
                "file:a.py", [e["stable_id"] for e in export["entities"]]
            )
            stats = g.stats()
            self.assertEqual(stats["snapshot_id"], s2)
            self.assertEqual(stats["entities_by_kind"], {"File": 1})
            # explicit old snapshot still exports its own rows only
            old = g.export_json(s1)
            self.assertEqual([e["stable_id"] for e in old["entities"]], ["file:a.py"])

    # (b) -----------------------------------------------------------------
    def test_b_empty_database_raises_snapshot_error(self):
        with Graph.open(self.db) as g:
            with self.assertRaises(SnapshotError):
                g.export_json()
            with self.assertRaises(SnapshotError):
                g.stats()
            with self.assertRaises(SnapshotError):
                g.completeness()

    # (c) -----------------------------------------------------------------
    def test_c_dirty_worktree_identity_and_strict_clean(self):
        repo = self.root / "gitrepo"
        repo.mkdir()
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        (repo / "f.txt").write_text("hello\n")
        subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
        subprocess.run(
            ["git", "-c", "user.email=t@example.com", "-c", "user.name=T",
             "-C", str(repo), "commit", "-q", "-m", "init"],
            check=True,
        )
        head = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()

        clean = compute_identity(repo)
        self.assertEqual(clean["source_revision"], head)
        self.assertEqual(compute_identity(repo, strict_clean=True)["source_revision"], head)

        (repo / "f.txt").write_text("hello\nchanged\n")
        dirty = compute_identity(repo)
        self.assertTrue(dirty["source_revision"].startswith("worktree:"))
        self.assertEqual(
            dirty["source_revision"], f"worktree:{head}:{dirty['tree_digest']}"
        )
        with self.assertRaises(SnapshotError):
            compute_identity(repo, strict_clean=True)

    # (d) -----------------------------------------------------------------
    def test_d_non_git_identity_is_content_digest(self):
        plain = self.root / "plain"
        plain.mkdir()
        (plain / "f.txt").write_text("not a repo\n")
        ident = compute_identity(plain)
        self.assertEqual(ident["source_revision"], f"content:{ident['tree_digest']}")
        self.assertEqual(compute_identity(plain)["revision_digest"], ident["revision_digest"])
        with self.assertRaises(SnapshotError):
            compute_identity(plain, strict_clean=True)

    # (e) -----------------------------------------------------------------
    def test_e_failed_scan_leaves_no_snapshot_or_rows(self):
        class BoomProvider:
            provider_id = "boom-provider"
            provider_version = "1.0"

            def snapshot(self, root, *, commit_sha=None):
                raise RuntimeError("provider exploded")

        repo = self.root / "repo"
        repo.mkdir()
        (repo / "x.py").write_text("def f():\n    return 1\n")
        with self.assertRaises(RuntimeError):
            scan(repo, self.db, provider=BoomProvider())

        self.assertTrue(self.db.exists())
        with Graph.open(self.db, create=False) as g:
            conn = g._require_conn()
            for table in ("snapshot", "entity", "relation", "fact",
                          "unresolved_edge", "support", "evidence", "provider_record"):
                n = conn.execute(f"SELECT COUNT(*) AS n FROM {table}").fetchone()["n"]
                self.assertEqual(n, 0, f"{table} must be empty after a failed scan")

    # (f) -----------------------------------------------------------------
    def test_f_finalized_snapshot_is_immutable(self):
        with Graph.open(self.db) as g:
            snap = g.begin_draft(_identity())
            g.upsert_entity("Module", "a", "module:a", snapshot_id=snap)
            g.finalize_snapshot(snap)
            with self.assertRaises(sqlite3.IntegrityError):
                g.upsert_entity("Module", "b", "module:b", snapshot_id=snap)
            conn = g._require_conn()
            with self.assertRaises(sqlite3.IntegrityError):
                conn.execute("UPDATE entity SET attrs='{}' WHERE snapshot_id=?", (snap,))
            conn.rollback()
            # finalized rows are still readable
            self.assertEqual(g.stats(snap)["entities_by_kind"], {"Module": 1})

    # (g) -----------------------------------------------------------------
    def test_g_cross_snapshot_relation_insert_raises_integrity_error(self):
        with Graph.open(self.db) as g:
            s1 = g.begin_draft(_identity("sha-1", "tree-1"))
            s2 = g.begin_draft(_identity("sha-2", "tree-2"))
            e1 = g.upsert_entity("Module", "a", "module:a", snapshot_id=s1)
            e2 = g.upsert_entity("Module", "b", "module:b", snapshot_id=s2)
            with self.assertRaises(sqlite3.IntegrityError):
                g.upsert_relation(e1, e2, "calls", snapshot_id=s1)
            g._require_conn().rollback()

    # (h) -----------------------------------------------------------------
    def test_h_unresolved_edge_preserved_and_surfaced(self):
        with Graph.open(self.db) as g:
            snap = g.begin_draft(_identity())
            src = g.upsert_entity("File", "a.py", "file:a.py", qualified_name="a.py",
                                  snapshot_id=snap)
            g.upsert_relation(
                src, None, "imports", snapshot_id=snap, src_key="file:a.py",
                dst_key="pkg::Missing", resolved=0,
            )
            g.add_unresolved_edge(
                snap, "file:a.py", "pkg::Missing", "imports",
                provider="generic-static", provider_revision="2.0",
                candidates=["sym:python:pkg.py::Missing"], confidence=0.2,
            )
            g.finalize_snapshot(snap)

            rows = g.unresolved_edges(snap)
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["dst_raw"], "pkg::Missing")
            self.assertEqual(rows[0]["candidates"], ["sym:python:pkg.py::Missing"])
            self.assertEqual(rows[0]["confidence"], 0.2)

            comp = g.completeness(snap)
            self.assertEqual(comp["unresolved"]["count"], 1)
            self.assertEqual(comp["families"]["relations"], "partial")
            self.assertEqual(comp["unresolved"]["sample"][0]["dst_raw"], "pkg::Missing")

            export = g.export_json(snap)
            self.assertEqual(len(export["unresolved_edges"]), 1)
            self.assertEqual(export["unresolved_edges"][0]["candidates"],
                             ["sym:python:pkg.py::Missing"])
            edges = g.edges_by_type("imports", snapshot_id=snap)
            self.assertEqual(edges[0]["resolved"], 0)
            self.assertIsNone(edges[0]["dst"])
            self.assertEqual(edges[0]["dst_key"], "pkg::Missing")

    # (i) -----------------------------------------------------------------
    def test_i_typed_endpoint_collision_resolves_by_stable_id(self):
        class CollisionProvider:
            provider_id = "collision-provider"
            provider_version = "1.0"
            capabilities = {"entities": "complete", "relations": "partial"}

            def snapshot(self, root, *, commit_sha=None):
                return {
                    "entities": [
                        {"kind": "File", "name": "x.py", "qualified_name": "x.py",
                         "stable_id": "file:x.py"},
                        {"kind": "Test", "name": "x.py", "qualified_name": "x.py",
                         "stable_id": "test:x.py::x.py"},
                    ],
                    "relations": [
                        {"kind": "tests", "src_key": "test:x.py::x.py",
                         "src_kind": "Test", "dst_key": "file:x.py", "dst_kind": "File"},
                    ],
                    "facts": [], "unresolved": [], "evidence": [],
                    "providers": [{
                        "provider_id": "collision-provider",
                        "provider_version": "1.0",
                        "capabilities": {"entities": "complete", "relations": "partial"},
                    }],
                }

        repo = self.root / "collide_repo"
        repo.mkdir()
        (repo / "x.py").write_text("def x():\n    return 1\n")
        report = scan(repo, self.db, provider=CollisionProvider())
        self.assertEqual(report["relations_upserted"], 1)

        with Graph.open(self.db, create=False) as g:
            # the qn is ambiguous across kinds...
            self.assertIsNone(g.find_entity_by_qn("x.py"))
            # ...but the typed (kind, stable_id) endpoints resolved exactly
            edges = g.edges_by_type("tests")
            self.assertEqual(len(edges), 1)
            self.assertEqual(edges[0]["src"]["kind"], "Test")
            self.assertEqual(edges[0]["src"]["stable_id"], "test:x.py::x.py")
            self.assertEqual(edges[0]["dst"]["kind"], "File")
            self.assertEqual(edges[0]["dst"]["stable_id"], "file:x.py")
            comp = g.completeness()
            self.assertEqual(comp["providers"]["collision-provider"]["entities"],
                             "complete")

    # (j) -----------------------------------------------------------------
    def test_j_zero_entity_scan_finalizes_repository_only(self):
        empty = self.root / "empty_repo"
        empty.mkdir()
        first = scan(empty, self.db)
        self.assertEqual(first["counts_by_kind"], {"Repository": 1})
        self.assertEqual(first["state"], "finalized")
        self.assertFalse(first["reused"])
        second = scan(empty, self.db)
        self.assertTrue(second["reused"])
        self.assertEqual(first["snapshot_id"], second["snapshot_id"])
        with Graph.open(self.db, create=False) as g:
            self.assertEqual(g.stats()["snapshots"], 1)
            self.assertEqual(g.export_json()["snapshot"]["state"], "finalized")

    # (k) -----------------------------------------------------------------
    def test_k_runtime_provenance_is_observed_depth4(self):
        with Graph.open(self.db) as g:
            snap = g.begin_draft(_identity())
            eid = g.upsert_entity("Symbol", "hot", "sym:python:x.py::hot",
                                  qualified_name="x::hot", provenance="runtime",
                                  snapshot_id=snap)
            row = g.entity_row(eid)
            self.assertEqual(row["epistemic_state"], "observed")
            self.assertNotEqual(row["epistemic_state"], "inferred")
            self.assertEqual(row["analysis_depth"], 4)

    # (l) -----------------------------------------------------------------
    def test_l_removed_file_shows_removed_entities_relations_and_facts(self):
        repo = self.root / "mini_repo"
        shutil.copytree(FIXTURE, repo)
        first = scan(repo, self.db)
        (repo / "data" / "binary.bin").unlink()
        second = scan(repo, self.db)
        self.assertNotEqual(first["snapshot_id"], second["snapshot_id"])

        with Graph.open(self.db, create=False) as g:
            diff = g.diff_snapshots(first["snapshot_id"], second["snapshot_id"])
            self.assertGreater(len(diff["removed"]), 0)
            self.assertIn("file:data/binary.bin", diff["removed"])
            self.assertGreater(len(diff["relations_removed"]), 0)
            self.assertIn(
                {"src": "module:data", "dst": "file:data/binary.bin", "kind": "contains"},
                diff["relations_removed"],
            )
            self.assertGreater(len(diff["facts_removed"]), 0)
            self.assertTrue(any(f.get("subject") == "data/binary.bin"
                            and f.get("predicate") == "extraction"
                            and f.get("object") == "binary"
                            for f in diff["facts_removed"]))
            # no in-place staleness: the old snapshot still has the file
            self.assertIn("File", g.stats(first["snapshot_id"])["entities_by_kind"])
            old_export = g.export_json(first["snapshot_id"])
            self.assertIn(
                "file:data/binary.bin", [e["stable_id"] for e in old_export["entities"]]
            )


if __name__ == "__main__":
    unittest.main()
