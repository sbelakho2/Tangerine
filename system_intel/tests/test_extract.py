"""Extraction + scan tests over the fake multi-language fixture repository (v2)."""

import json
import shutil
import tempfile
import unittest
from dataclasses import asdict
from pathlib import Path

from system_intel.extract_core import extract
from system_intel.graph import Graph
from system_intel.persist import report_to_json, scan

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "mini_repo"


def _serialized(result) -> str:
    payload = {
        "entities": [asdict(e) for e in result.entities],
        "relations": [asdict(r) for r in result.relations],
        "facts": [asdict(f) for f in result.facts],
    }
    return json.dumps(payload)


class ExtractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.result = extract(FIXTURE)

    def _entities(self, kind):
        return [e for e in self.result.entities if e.kind == kind]

    def _qns(self, kind):
        return {e.qualified_name for e in self._entities(kind)}

    def _stable(self, kind):
        return {e.stable_id for e in self._entities(kind)}

    def _rels(self, kind):
        return [r for r in self.result.relations if r.kind == kind]

    def test_repository_and_files(self):
        repos = self._entities("Repository")
        self.assertEqual(len(repos), 1)
        self.assertEqual(repos[0].qualified_name, ".")
        self.assertEqual(repos[0].stable_id, "repo:.")
        files = self._stable("File")
        for rel in ("Cargo.toml", "src/lib.rs", "src/main.rs", "schema.sql", ".env"):
            self.assertIn(f"file:{rel}", files)

    def test_directory_modules(self):
        self.assertIn("src", self._qns("Module"))
        self.assertIn("module:src", self._stable("Module"))
        contains = {
            (r.src_key, r.dst_key, r.kind) for r in self.result.relations
            if r.kind == "contains"
        }
        self.assertIn(("module:src", "file:src/lib.rs", "contains"), contains)
        self.assertIn(("repo:.", "module:src", "contains"), contains)

    def test_manifest_packages_and_nested_project(self):
        by_qn = {e.qualified_name: e for e in self._entities("Package")}
        self.assertIn("Cargo.toml", by_qn)
        cargo = by_qn["Cargo.toml"]
        self.assertEqual(cargo.attrs["manifest"], "cargo")
        self.assertEqual(cargo.name, "mini")
        self.assertEqual(cargo.stable_id, "pkg:Cargo.toml")
        self.assertEqual(cargo.epistemic_state, "declared")
        self.assertIn("web/package.json", by_qn)
        self.assertEqual(by_qn["web/package.json"].name, "mini-web")
        self.assertEqual(by_qn["pyproject.toml"].name, "mini-py")
        projects = self._stable("Project")
        self.assertIn("project:web", projects)

    def test_rust_symbols_typed_keys_and_epistemics(self):
        qns = self._qns("Symbol")
        self.assertIn("src.lib::Widget", qns)
        self.assertIn("src.lib::build", qns)
        self.assertIn("src.lib::Render", qns)
        sym = next(e for e in self._entities("Symbol") if e.qualified_name == "src.lib::Widget")
        self.assertEqual(sym.file, "src/lib.rs")
        self.assertEqual(sym.stable_id, "sym:rust:src/lib.rs::Widget")
        self.assertEqual(sym.epistemic_state, "observed")
        self.assertEqual(sym.analysis_depth, 1)
        self.assertEqual(sym.completeness, "partial")
        self.assertEqual(sym.provider, "generic-static")
        contains = {
            (r.src_key, r.dst_key, r.kind) for r in self.result.relations
            if r.kind == "contains"
        }
        self.assertIn(("file:src/lib.rs", "sym:rust:src/lib.rs::Widget", "contains"), contains)

    def test_relative_js_import_resolves_to_stable_id(self):
        imports = self._rels("imports")
        hit = next(
            r for r in imports
            if r.src_key == "file:web/index.js" and r.dst_key == "file:web/helper.js"
        )
        self.assertEqual(hit.src_kind, "File")
        self.assertEqual(hit.dst_kind, "File")
        self.assertEqual(hit.provenance, "inferred")
        self.assertGreaterEqual(hit.confidence, 0.9)

    def test_tangerine_fallback_symbols_tests_and_import(self):
        self.assertIn("sym:tg:tg/mod.tg::Item", self._stable("Symbol"))
        self.assertIn("test:tg/mod.tg::test_make", self._stable("Test"))
        tg_imports = [
            r for r in self.result.relations
            if r.kind == "imports" and r.src_key == "file:tg/mod.tg"
        ]
        self.assertEqual(len(tg_imports), 1)
        self.assertEqual(tg_imports[0].dst_key, "std::core")
        self.assertEqual(tg_imports[0].provenance, "declared")
        # typed tests relation: @test function -> its module (never tests(rel, rel))
        tests_rel = [
            r for r in self.result.relations
            if r.kind == "tests" and r.src_key == "test:tg/mod.tg::test_make"
        ]
        self.assertEqual(len(tests_rel), 1)
        self.assertEqual(tests_rel[0].src_kind, "Test")
        self.assertEqual(tests_rel[0].dst_key, "module:tg")
        self.assertEqual(tests_rel[0].dst_kind, "Module")

    def test_generic_test_file_emits_typed_tests_relation(self):
        self.assertIn("test:app/test_store.py::test_store.py", self._stable("Test"))
        tests_rel = [
            r for r in self.result.relations
            if r.kind == "tests" and r.src_key == "test:app/test_store.py::test_store.py"
        ]
        self.assertEqual(len(tests_rel), 1)
        rel = tests_rel[0]
        self.assertEqual(rel.src_kind, "Test")
        self.assertEqual(rel.dst_key, "file:app/store.py")
        self.assertEqual(rel.dst_kind, "File")
        # no relation may ever be tests(rel, rel)
        for r in self._rels("tests"):
            self.assertNotEqual(r.src_key, r.dst_key)

    def test_sql_schema_typed_fk(self):
        schemas = self._stable("Schema")
        self.assertIn("schema:schema.sql::orders", schemas)
        self.assertIn("schema:schema.sql::customers", schemas)
        cols = {
            (f.stable_subject, f.predicate, f.object)
            for f in self.result.facts
            if f.subject == "schema.sql::orders"
        }
        self.assertIn(("schema:schema.sql::orders", "column:total", "DECIMAL(10,2)"), cols)
        fks = [
            r
            for r in self.result.relations
            if r.kind == "depends_on" and r.src_key == "schema:schema.sql::orders"
        ]
        self.assertEqual([r.dst_key for r in fks], ["schema:schema.sql::customers"])

    def test_env_values_are_never_recorded(self):
        configs = self._stable("Configuration")
        self.assertIn("config:.env::API_KEY", configs)
        self.assertIn("config:.env::DB_HOST", configs)
        self.assertNotIn("super-secret-value", _serialized(self.result))
        self.assertNotIn("localhost", _serialized(self.result))

    def test_unknown_extension_is_tier0_file_only(self):
        self.assertIn("file:data/blob.xyz", self._stable("File"))
        blob = next(e for e in self._entities("File") if e.qualified_name == "data/blob.xyz")
        self.assertEqual(blob.tier, 0)
        symbols = [s for s in self._stable("Symbol") if "blob.xyz" in s]
        self.assertEqual(symbols, [])

    def test_binary_file_degrades_gracefully(self):
        degraded = [
            f
            for f in self.result.facts
            if f.subject == "data/binary.bin" and f.object == "binary"
        ]
        self.assertEqual(len(degraded), 1)
        self.assertIsNotNone(degraded[0].uncertainty)
        self.assertEqual(degraded[0].stable_subject, "file:data/binary.bin")

    def test_dockerfile_becomes_deployment(self):
        self.assertIn("deployment:Dockerfile", self._stable("Deployment"))

    def test_empty_directory_yields_repository_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = extract(tmp)
            self.assertEqual(len(result.entities), 1)
            self.assertEqual(result.entities[0].kind, "Repository")
            self.assertEqual(result.entities[0].stable_id, "repo:.")


class ScanTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="intel_fixture_")
        self.repo = Path(self.tmp) / "mini_repo"
        shutil.copytree(FIXTURE, self.repo)
        self.db = Path(self.tmp) / "graph.db"

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_scan_report_and_json(self):
        report = scan(self.repo, self.db)
        self.assertGreater(report["entities_upserted"], 10)
        self.assertGreater(report["relations_upserted"], 5)
        self.assertGreater(report["relations_unresolved"], 0)
        self.assertEqual(report["schema_version"], 2)
        self.assertEqual(report["state"], "finalized")
        self.assertFalse(report["reused"])
        self.assertGreater(report["counts_by_kind"].get("Symbol", 0), 0)
        self.assertIn("revision_digest", report)
        self.assertIn("completeness", report)
        parsed = json.loads(report_to_json(report))
        self.assertEqual(parsed["commit_sha"], report["commit_sha"])
        self.assertEqual(parsed["identity"]["revision_digest"], report["revision_digest"])

    def test_scan_is_idempotent_without_writes(self):
        first = scan(self.repo, self.db)
        before = self.db.read_bytes()
        second = scan(self.repo, self.db)
        after = self.db.read_bytes()
        self.assertEqual(first["snapshot_id"], second["snapshot_id"])
        self.assertTrue(second["reused"])
        self.assertEqual(first["entities_upserted"], second["entities_upserted"])
        self.assertEqual(second["stale_entities"], 0)
        self.assertEqual(before, after, "same-revision rescan must not write")
        with Graph.open(self.db, create=False) as graph:
            stats = graph.stats()
        self.assertEqual(stats["entities_by_kind"], first["counts_by_kind"])
        self.assertEqual(stats["snapshots"], 1)

    def test_new_revision_on_tree_change_and_diff(self):
        first = scan(self.repo, self.db)
        (self.repo / "data" / "binary.bin").unlink()
        second = scan(self.repo, self.db)
        self.assertNotEqual(first["snapshot_id"], second["snapshot_id"])
        self.assertFalse(second["reused"])
        with Graph.open(self.db, create=False) as graph:
            self.assertEqual(graph.stats()["snapshots"], 2)
            diff = graph.diff_snapshots(first["snapshot_id"], second["snapshot_id"])
            self.assertIn("file:data/binary.bin", diff["removed"])
            self.assertIn(
                {"src": "module:data", "dst": "file:data/binary.bin", "kind": "contains"},
                diff["relations_removed"],
            )
            self.assertIn("data/binary.bin|extraction|binary", diff["facts_removed"])
            # the old snapshot is untouched history
            old = graph.stats(first["snapshot_id"])
            self.assertIn("File", old["entities_by_kind"])

    def test_scan_creates_database_and_dirs(self):
        nested = Path(self.tmp) / "nested" / "dir" / "graph.db"
        report = scan(self.repo, nested)
        self.assertTrue(nested.exists())
        self.assertEqual(report["db_path"], str(nested))

    def test_empty_directory_scan_finalizes_with_repository_only(self):
        empty = Path(self.tmp) / "empty_repo"
        empty.mkdir()
        report = scan(empty, Path(self.tmp) / "empty.db")
        self.assertEqual(report["counts_by_kind"], {"Repository": 1})
        self.assertEqual(report["state"], "finalized")
        self.assertFalse(report["reused"])


if __name__ == "__main__":
    unittest.main()
