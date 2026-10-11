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
            # every support row pins the EXACT level-2 observation
            support_obs = g._require_conn().execute(
                "SELECT DISTINCT observation_id FROM support WHERE snapshot_id=?",
                (int(snap["id"]),),
            ).fetchall()
            self.assertEqual(len(support_obs), 1)
            self.assertEqual(int(support_obs[0]["observation_id"]), int(obs["id"]))

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
            # a support observation from ANOTHER snapshot is rejected
            source = g.upsert_source_revision({
                "repo_identity": "r-x", "source_revision": "s-x",
                "tree_digest": "t-x", "semantic_configuration": "{}",
            })
            foreign_obs = g.add_provider_observation(
                source, "p", observation_digest="deadbeef",
            )
            with self.assertRaises(sqlite3.IntegrityError):
                g.accumulate_support(s1, "entity", e1, provider="p",
                                     observation_id=foreign_obs)
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

    # (11) ---------------------------------------------------------------
    def test_observation_digest_covers_the_complete_observation(self):
        """Metadata-only changes must change the observation digest."""
        from system_intel.persist import _snapshot_digest
        from system_intel.providers.base import (
            ProviderEntity, ProviderEvidence, ProviderSnapshot,
        )

        def snapshot(confidence=1.0, attrs=None, summary="observed"):
            return ProviderSnapshot(
                entities=[ProviderEntity(
                    kind="Symbol", name="f", qualified_name="m.f",
                    stable_id="native:decl:1", confidence=confidence,
                    attrs=attrs or {"visibility": "public"},
                )],
                evidence=[ProviderEvidence(kind="trace", ref="t:1",
                                           summary=summary, payload={"n": 1})],
                provider_id="p", provider_version="1",
                capabilities=[],
            )

        base = _snapshot_digest("p", "1", snapshot())
        self.assertEqual(base, _snapshot_digest("p", "1", snapshot()))
        self.assertNotEqual(base, _snapshot_digest("p", "1", snapshot(confidence=0.5)))
        self.assertNotEqual(base, _snapshot_digest("p", "1", snapshot(attrs={"visibility": "private"})))
        self.assertNotEqual(base, _snapshot_digest("p", "1", snapshot(summary="different")))

        # Checkout-independent: paths under the scan root are normalized.
        from system_intel.providers.base import ProviderEvidence
        def path_snapshot(path):
            return ProviderSnapshot(
                evidence=[ProviderEvidence(kind="note", ref=path)],
                provider_id="p", provider_version="1",
            )
        self.assertEqual(
            _snapshot_digest("p", "1", path_snapshot("/w/one/tg_semantic.jsonl"), "/w/one"),
            _snapshot_digest("p", "1", path_snapshot("/w/two/tg_semantic.jsonl"), "/w/two"),
        )

    # (12) ---------------------------------------------------------------
    def test_unique_secondary_provider_knowledge_is_included(self):
        """Authority is claim-scoped: unique non-primary knowledge survives."""
        from system_intel.persist import _project_snapshot
        from system_intel.providers.base import (
            ProviderEntity, ProviderFact, ProviderRelation, ProviderSnapshot,
        )

        with Graph.open(self.db) as g:
            snap = g.begin_draft(_identity("federation"))
            primary = ProviderSnapshot(
                entities=[ProviderEntity(kind="Module", name="m",
                                         qualified_name="module:m",
                                         stable_id="native:decl:1")],
                relations=[], facts=[], evidence=[],
                provider_id="tangerine-native", provider_version="1",
            )
            secondary = ProviderSnapshot(
                entities=[ProviderEntity(kind="Deployment", name="docker",
                                         qualified_name="deployment:docker",
                                         stable_id="deployment:docker")],
                relations=[ProviderRelation(
                    src_key="deployment:docker", dst_key="native:decl:1",
                    kind="deploys_with",
                    src_kind="Deployment", dst_kind="Module",
                )],
                facts=[ProviderFact(
                    subject="deployment:docker", predicate="uses_manifest",
                    object="Dockerfile", stable_subject="deployment:docker",
                )],
                evidence=[], provider_id="generic-static", provider_version="2",
            )
            _project_snapshot(g, snap, primary, "tangerine-native", "1", canonical=True)
            _project_snapshot(g, snap, secondary, "generic-static", "2", canonical=False)
            conn = g._require_conn()
            kinds = {r["kind"] for r in conn.execute(
                "SELECT kind FROM entity WHERE snapshot_id=?", (snap,)
            ).fetchall()}
            self.assertIn("Deployment", kinds,
                          "unique secondary knowledge must not be dropped")
            self.assertIn("Module", kinds)
            edge = conn.execute(
                "SELECT src_key, dst_key, provider FROM relation WHERE kind='deploys_with'"
            ).fetchone()
            self.assertIsNotNone(edge)
            self.assertEqual(edge["dst_key"], "native:decl:1")
            self.assertEqual(edge["provider"], "generic-static")
            facts = {r["predicate"] for r in conn.execute(
                "SELECT predicate FROM fact WHERE snapshot_id=?", (snap,)
            ).fetchall()}
            self.assertIn("uses_manifest", facts)
            providers = {r["provider"] for r in conn.execute(
                "SELECT DISTINCT provider FROM support WHERE snapshot_id=?", (snap,)
            ).fetchall()}
            self.assertEqual(providers, {"tangerine-native", "generic-static"})

    # (14) ---------------------------------------------------------------
    def test_data_bearing_pre_v3_database_is_refused(self):
        db = self.root / "legacy_v2.db"
        conn = sqlite3.connect(str(db))
        conn.execute("CREATE TABLE schema_version (version INTEGER NOT NULL)")
        conn.execute("INSERT INTO schema_version (version) VALUES (2)")
        conn.execute(
            "CREATE TABLE snapshot (id INTEGER PRIMARY KEY AUTOINCREMENT, "
            "repo_identity TEXT NOT NULL, source_revision TEXT NOT NULL, "
            "tree_digest TEXT NOT NULL, semantic_configuration TEXT NOT NULL DEFAULT '{}', "
            "provider_set_digest TEXT NOT NULL DEFAULT '', revision_digest TEXT NOT NULL, "
            "state TEXT NOT NULL DEFAULT 'draft')"
        )
        conn.execute(
            "INSERT INTO snapshot (repo_identity, source_revision, tree_digest, "
            "revision_digest, state) VALUES ('r', 's', 't', 'd', 'finalized')"
        )
        conn.commit()
        conn.close()
        with self.assertRaises(Exception) as ctx:
            Graph.open(db)
        self.assertIn("rescan into a fresh database", str(ctx.exception))

    def test_empty_pre_v3_database_is_rebuilt(self):
        db = self.root / "legacy_empty.db"
        conn = sqlite3.connect(str(db))
        conn.execute("CREATE TABLE schema_version (version INTEGER NOT NULL)")
        conn.execute("INSERT INTO schema_version (version) VALUES (2)")
        conn.execute(
            "CREATE TABLE snapshot (id INTEGER PRIMARY KEY AUTOINCREMENT, "
            "repo_identity TEXT NOT NULL, source_revision TEXT NOT NULL, "
            "tree_digest TEXT NOT NULL, semantic_configuration TEXT NOT NULL DEFAULT '{}', "
            "provider_set_digest TEXT NOT NULL DEFAULT '', revision_digest TEXT NOT NULL, "
            "state TEXT NOT NULL DEFAULT 'draft')"
        )
        conn.commit()
        conn.close()
        with Graph.open(db) as g:
            self.assertEqual(g._require_conn().execute(
                "SELECT version FROM schema_version"
            ).fetchone()["version"], 3)
            snap = g.begin_draft(_identity("rebuilt"))
            g.upsert_entity("File", "a.py", "file:a.py", qualified_name="a.py",
                            snapshot_id=snap)
            g.finalize_snapshot(snap)
            self.assertEqual(g.stats(snap)["entities_by_kind"]["File"], 1)

    # (15) ---------------------------------------------------------------
    def test_observation_canonicalization_is_schema_aware(self):
        from system_intel.persist import _snapshot_digest
        from system_intel.providers.base import (
            ProviderEntity, ProviderEvidence, ProviderSnapshot,
        )

        def with_entities(order):
            entities = {
                "a": ProviderEntity(kind="Symbol", name="a", qualified_name="m.a",
                                    stable_id="sym:a"),
                "b": ProviderEntity(kind="Symbol", name="b", qualified_name="m.b",
                                    stable_id="sym:b"),
            }
            return ProviderSnapshot(entities=[entities[key] for key in order],
                                    provider_id="p", provider_version="1")

        # Top-level record collections are order-INSENSITIVE.
        self.assertEqual(
            _snapshot_digest("p", "1", with_entities("ab")),
            _snapshot_digest("p", "1", with_entities("ba")),
        )

        # Nested lists are ORDERED semantic sequences.
        ordered_a = ProviderSnapshot(
            entities=[ProviderEntity(kind="Symbol", name="f", qualified_name="m.f",
                                     stable_id="sym:f",
                                     attrs={"params": ["Int", "String"]})],
            provider_id="p", provider_version="1",
        )
        ordered_b = ProviderSnapshot(
            entities=[ProviderEntity(kind="Symbol", name="f", qualified_name="m.f",
                                     stable_id="sym:f",
                                     attrs={"params": ["String", "Int"]})],
            provider_id="p", provider_version="1",
        )
        self.assertNotEqual(_snapshot_digest("p", "1", ordered_a),
                            _snapshot_digest("p", "1", ordered_b))

        # Transient-key removal is NOT recursive: a semantic attribute named
        # like plumbing must still count.
        attr_a = ProviderSnapshot(
            entities=[ProviderEntity(kind="Symbol", name="f", qualified_name="m.f",
                                     stable_id="sym:f", attrs={"stdout": "a"})],
            provider_id="p", provider_version="1",
        )
        attr_b = ProviderSnapshot(
            entities=[ProviderEntity(kind="Symbol", name="f", qualified_name="m.f",
                                     stable_id="sym:f", attrs={"stdout": "b"})],
            provider_id="p", provider_version="1",
        )
        self.assertNotEqual(_snapshot_digest("p", "1", attr_a),
                            _snapshot_digest("p", "1", attr_b))

        # A TOP-LEVEL transient key is plumbing and does not count.
        dict_a = {"entities": [], "relations": [], "facts": [],
                  "unresolved": [], "evidence": [], "cache_path": "/tmp/a"}
        dict_b = {"entities": [], "relations": [], "facts": [],
                  "unresolved": [], "evidence": [], "cache_path": "/tmp/b"}
        self.assertEqual(_snapshot_digest("p", "1", dict_a),
                         _snapshot_digest("p", "1", dict_b))

        # Path normalization applies ONLY to known path fields (`ref`), so
        # the same content from two checkouts hashes equally.
        def ref_snapshot(ref):
            return ProviderSnapshot(
                evidence=[ProviderEvidence(kind="note", ref=ref)],
                provider_id="p", provider_version="1",
            )
        self.assertEqual(
            _snapshot_digest("p", "1", ref_snapshot("/w/one/x"), "/w/one"),
            _snapshot_digest("p", "1", ref_snapshot("/w/two/x"), "/w/two"),
        )

        # A nested non-path field that merely looks path-like is NOT
        # normalized (semantic strings are never rewritten).
        def note_snapshot(note):
            return ProviderSnapshot(
                evidence=[ProviderEvidence(kind="note", ref="ref",
                                           payload={"note": note})],
                provider_id="p", provider_version="1",
            )
        self.assertNotEqual(
            _snapshot_digest("p", "1", note_snapshot("/w/one/x"), "/w/one"),
            _snapshot_digest("p", "1", note_snapshot("/w/two/x"), "/w/two"),
        )

    # (13) ---------------------------------------------------------------
    def test_duplicate_claim_preserves_disagreement(self):
        from system_intel.persist import _project_snapshot
        from system_intel.providers.base import ProviderEntity, ProviderSnapshot

        with Graph.open(self.db) as g:
            snap = g.begin_draft(_identity("conflict"))
            high = ProviderSnapshot(
                entities=[ProviderEntity(kind="Symbol", name="f",
                                         qualified_name="m.f",
                                         stable_id="sym:f", completeness="complete")],
                provider_id="high-authority", provider_version="1",
            )
            low = ProviderSnapshot(
                entities=[ProviderEntity(kind="Symbol", name="f",
                                         qualified_name="m.f",
                                         stable_id="sym:f", completeness="partial")],
                provider_id="low-authority", provider_version="1",
            )
            _project_snapshot(g, snap, high, "high-authority", "1", canonical=True)
            _project_snapshot(g, snap, low, "low-authority", "1", canonical=False)
            conn = g._require_conn()
            self.assertEqual(
                conn.execute("SELECT COUNT(*) AS n FROM entity").fetchone()["n"], 1,
                "the same typed claim must not duplicate the canonical row",
            )
            support = conn.execute(
                "SELECT provider, detail FROM support WHERE subject_table='entity' "
                "ORDER BY provider"
            ).fetchall()
            self.assertEqual(len(support), 2)
            conflict = [r for r in support if r["detail"].startswith("conflict:")]
            self.assertEqual(len(conflict), 1)
            self.assertIn("partial", conflict[0]["detail"])

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
