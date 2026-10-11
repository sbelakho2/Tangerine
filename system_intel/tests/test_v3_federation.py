"""Schema-v3 federation/observation integrity suite.

Covers the audit's P0/P1 federation items on top of the v2 core suite:

(1) three identity levels materialized: source_revision, provider_observation,
    snapshot_observation links;
(2) observation freshness: a new provider observation produces a NEW federated
    revision even when the source tree is unchanged;
(3) snapshot metadata freeze and full snapshot-owned immutability
    (invariant/contract/incident/change included);
(4) support integrity: cross-snapshot evidence and polymorphic invalid
    subjects are structurally rejected;
(5) symlinks are never followed into file content;
(6) the active DB can live inside the scanned root without contaminating the
    repository tree digest;
(7) the normal scan federates through the provider registry automatically;
(8) the relation completeness axes (site vs target-resolution) are stored and
    surfaced;
(9) fact identity is content-derived (subject + predicate + object);
(10) the revision digest is recomputed/self-enforcing at finalization.
"""

import hashlib
import os
import shutil
import sqlite3
import tempfile
import unittest
from pathlib import Path

from system_intel.extract_core import iter_files
from system_intel.graph import (
    Graph,
    fact_stable_id,
    identity_revision_digest,
)
from system_intel.persist import scan

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


class _GrowingProvider:
    """A provider whose observation content grows between invocations."""

    provider_id = "growing-static"
    provider_version = "1.0"
    capabilities = {"entities": "complete", "relations": "partial", "facts": "complete"}

    def __init__(self):
        self.calls = 0

    def snapshot(self, root, *, commit_sha=None):
        self.calls += 1
        facts = [{
            "subject": "repo", "predicate": "fact_count",
            "object": str(self.calls), "stable_subject": "repo:.",
        }]
        return {
            "entities": [{
                "kind": "Repository", "name": "repo", "qualified_name": ".",
                "stable_id": "repo:.",
            }],
            "relations": [],
            "facts": facts,
            "unresolved": [],
            "evidence": [],
            "providers": [{
                "provider_id": self.provider_id,
                "provider_version": self.provider_version,
                "capabilities": dict(self.capabilities),
            }],
        }


class _CompletenessProvider:
    provider_id = "axes-static"
    provider_version = "1.0"
    capabilities = {"entities": "complete", "relations": "partial"}

    def snapshot(self, root, *, commit_sha=None):
        return {
            "entities": [
                {"kind": "File", "name": "a.py", "qualified_name": "a.py",
                 "stable_id": "file:a.py"},
                {"kind": "File", "name": "b.py", "qualified_name": "b.py",
                 "stable_id": "file:b.py"},
            ],
            "relations": [{
                "kind": "imports", "src_key": "file:a.py", "dst_key": "file:b.py",
                "attrs": {"site_completeness": "complete",
                          "target_resolution_completeness": "partial"},
            }],
            "facts": [], "unresolved": [], "evidence": [],
            "providers": [{
                "provider_id": self.provider_id,
                "provider_version": self.provider_version,
                "capabilities": dict(self.capabilities),
            }],
        }


class FederationV3TestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="intel_v3_")
        self.root = Path(self.tmp)
        self.db = self.root / "graph.db"

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    # (1) ----------------------------------------------------------------
    def test_observation_model_materialized_and_reused(self):
        repo = self.root / "repo"
        repo.mkdir()
        (repo / "x.py").write_text("def f():\n    return 1\n")

        first = scan(repo, self.db, provider=_GrowingProvider())
        self.assertFalse(first["reused"])
        self.assertTrue(first["identity"]["observation_set_digest"])
        self.assertEqual(len(first["observations"]), 1)
        self.assertIsNotNone(first["source_revision_id"])

        with Graph.open(self.db, create=False) as g:
            snap = g.latest_finalized_snapshot()
            observations = g.observations(int(snap["id"]))
            self.assertEqual(len(observations), 1)
            obs = observations[0]
            self.assertEqual(obs["provider"], "growing-static")
            self.assertEqual(obs["observation_kind"], "static")
            self.assertTrue(obs["observation_digest"])
            source = g.source_revision_row(snap["source_revision_id"])
            self.assertIsNotNone(source)
            self.assertEqual(source["revision_digest"], source["revision_digest"])
            self.assertTrue(g.verify_snapshot_digest(int(snap["id"])))

    # (2) ----------------------------------------------------------------
    def test_new_observation_makes_a_new_federated_revision(self):
        repo = self.root / "repo"
        repo.mkdir()
        (repo / "x.py").write_text("def f():\n    return 1\n")
        provider = _GrowingProvider()
        first = scan(repo, self.db, provider=provider)
        second = scan(repo, self.db, provider=provider)

        self.assertFalse(first["reused"])
        self.assertFalse(second["reused"], "a new observation must not reuse the snapshot")
        self.assertNotEqual(
            first["identity"]["observation_set_digest"],
            second["identity"]["observation_set_digest"],
        )
        self.assertNotEqual(first["identity"]["revision_digest"],
                            second["identity"]["revision_digest"])
        with Graph.open(self.db, create=False) as g:
            self.assertEqual(g.stats()["snapshots"], 2)
            self.assertEqual(g.stats()["facts"], 1)
            observations = g.observations()
            self.assertEqual(len(observations), 1)
            self.assertEqual(observations[0]["observation_digest"],
                             second["observations"][0]["observation_digest"])

    # (3) ----------------------------------------------------------------
    def test_snapshot_metadata_freeze_and_all_family_immutability(self):
        with Graph.open(self.db) as g:
            snap = g.begin_draft(_identity())
            g.add_invariant("balance never negative", snapshot_id=snap)
            g.add_contract("api", "orders", snapshot_id=snap)
            g.add_incident("outage", snapshot_id=snap)
            g.add_change("abc123", "fix", snapshot_id=snap)
            g.finalize_snapshot(snap)
            conn = g._require_conn()
            with self.assertRaises(sqlite3.IntegrityError):
                conn.execute("UPDATE snapshot SET repo_root='elsewhere' WHERE id=?", (snap,))
            conn.rollback()
            with self.assertRaises(sqlite3.IntegrityError):
                conn.execute("UPDATE snapshot SET state='draft' WHERE id=?", (snap,))
            conn.rollback()
            with self.assertRaises(sqlite3.IntegrityError):
                conn.execute("DELETE FROM snapshot WHERE id=?", (snap,))
            conn.rollback()
            for call in (
                lambda: g.add_invariant("x", snapshot_id=snap),
                lambda: g.add_contract("api", "y", snapshot_id=snap),
                lambda: g.add_incident("z", snapshot_id=snap),
                lambda: g.add_change("def", "w", snapshot_id=snap),
            ):
                with self.assertRaises(sqlite3.IntegrityError):
                    call()
                conn.rollback()

    # (4) ----------------------------------------------------------------
    def test_support_integrity_rejects_cross_snapshot_evidence_and_bad_subject(self):
        with Graph.open(self.db) as g:
            s1 = g.begin_draft(_identity("sha-1", "tree-1"))
            s2 = g.begin_draft(_identity("sha-2", "tree-2"))
            e1 = g.upsert_entity("Module", "a", "module:a", snapshot_id=s1)
            ev2 = g.add_evidence(s2, "test_log", "artifact://log", digest="deadbeef")
            conn = g._require_conn()
            with self.assertRaises(sqlite3.IntegrityError):
                g.accumulate_support(s1, "entity", e1, provider="p", evidence_id=ev2)
            conn.rollback()
            with self.assertRaises(sqlite3.IntegrityError):
                g.accumulate_support(s1, "entity", 999999, provider="p")
            conn.rollback()
            # a same-snapshot evidence + real subject succeeds
            ev1 = g.add_evidence(s1, "test_log", "artifact://log2", digest="cafe")
            g.accumulate_support(s1, "entity", e1, provider="p", evidence_id=ev1)
            rows = conn.execute(
                "SELECT COUNT(*) AS n FROM support WHERE snapshot_id=?", (s1,)
            ).fetchone()["n"]
            self.assertEqual(rows, 1)

    # (5) ----------------------------------------------------------------
    def test_symlinks_are_never_followed(self):
        repo = self.root / "repo"
        repo.mkdir()
        outside = self.root / "outside.txt"
        outside.write_text("secret")
        link = repo / "link.txt"
        os.symlink(outside, link)

        yielded = {p.name for p in iter_files(repo)}
        self.assertNotIn("link.txt", yielded)

        from system_intel.persist import _tree_digest
        before = _tree_digest(repo)
        outside.write_text("changed secret")
        after = _tree_digest(repo)
        self.assertEqual(before, after, "symlink target content must not affect the digest")

    # (6) ----------------------------------------------------------------
    def test_db_inside_root_does_not_contaminate_identity(self):
        repo = self.root / "repo"
        repo.mkdir()
        (repo / "x.py").write_text("def f():\n    return 1\n")
        db_inside = repo / "graph.db"

        first = scan(repo, db_inside)
        second = scan(repo, db_inside)
        self.assertFalse(first["reused"])
        self.assertTrue(second["reused"],
                        "the scan's own DB must not change the repository tree digest")

    # (7) ----------------------------------------------------------------
    def test_default_scan_federates_through_the_registry(self):
        report = scan(FIXTURE, self.db)
        providers = set(report["providers"])
        self.assertIn("generic-static", providers)
        # the fixture contains a .tg file, so the native provider is selected;
        # without a compiler it degrades and every observation is recorded.
        self.assertIn("tangerine-native", providers)
        with Graph.open(self.db, create=False) as g:
            comp = g.completeness()
            self.assertIn("provider_scopes", comp)
            self.assertIn("generic-static", comp["providers"])

    # (8) ----------------------------------------------------------------
    def test_relation_completeness_axes_are_stored_and_surfaced(self):
        repo = self.root / "repo"
        repo.mkdir()
        (repo / "a.py").write_text("import b\n")
        report = scan(repo, self.db, provider=_CompletenessProvider())
        self.assertFalse(report["reused"])
        with Graph.open(self.db, create=False) as g:
            rel = g._require_conn().execute(
                "SELECT site_completeness, target_resolution_completeness "
                "FROM relation WHERE kind='imports'"
            ).fetchone()
            self.assertIsNotNone(rel)
            self.assertEqual(rel["site_completeness"], "complete")
            self.assertEqual(rel["target_resolution_completeness"], "partial")
            comp = g.completeness()
            axes = comp["relations_completeness"]
            self.assertEqual(axes["site"], "complete")
            self.assertEqual(axes["target_resolution"], "partial")

    # (9) ----------------------------------------------------------------
    def test_fact_identity_is_content_derived(self):
        with Graph.open(self.db) as g:
            snap = g.begin_draft(_identity())
            a = g.upsert_fact("checkout", "publishes", "OrderCreated",
                              snapshot_id=snap, stable_subject="sym:checkout")
            b = g.upsert_fact("checkout", "publishes", "OrderPaid",
                              snapshot_id=snap, stable_subject="sym:checkout")
            rows = {
                r["id"]: r["stable_id"]
                for r in g._require_conn().execute(
                    "SELECT id, stable_id FROM fact WHERE snapshot_id=?", (snap,)
                ).fetchall()
            }
            self.assertEqual(rows[a], fact_stable_id("sym:checkout", "publishes",
                                                     "OrderCreated"))
            self.assertNotEqual(rows[a], rows[b],
                                "two facts about one subject must differ")

    # (10) ---------------------------------------------------------------
    def test_finalization_recomputes_the_revision_digest(self):
        with Graph.open(self.db) as g:
            ident = _identity()
            ident["revision_digest"] = "0" * 64  # bogus on purpose
            snap = g.begin_draft(ident)
            g.finalize_snapshot(snap)
            self.assertTrue(g.verify_snapshot_digest(snap))
            row = g._snapshot_row(snap)
            self.assertNotEqual(row["revision_digest"], "0" * 64)


if __name__ == "__main__":
    unittest.main()
