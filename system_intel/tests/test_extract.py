"""Extraction + scan tests over a fake multi-language fixture repository."""

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

    def test_repository_and_files(self):
        repos = self._entities("Repository")
        self.assertEqual(len(repos), 1)
        self.assertEqual(repos[0].qualified_name, ".")
        files = self._qns("File")
        for rel in ("Cargo.toml", "src/lib.rs", "src/main.rs", "schema.sql", ".env"):
            self.assertIn(rel, files)

    def test_directory_modules(self):
        mods = self._qns("Module")
        for d in ("src", "app", "tg", "web", "data"):
            self.assertIn(d, mods)
        contains = {
            (r.src_qn, r.dst_qn)
            for r in self.result.relations
            if r.kind == "contains"
        }
        self.assertIn(("src", "src/lib.rs"), contains)

    def test_manifest_packages_and_nested_project(self):
        by_qn = {e.qualified_name: e for e in self._entities("Package")}
        self.assertIn("Cargo.toml", by_qn)
        self.assertEqual(by_qn["Cargo.toml"].attrs["manifest"], "cargo")
        self.assertEqual(by_qn["Cargo.toml"].name, "mini")
        self.assertIn("web/package.json", by_qn)
        self.assertEqual(by_qn["web/package.json"].name, "mini-web")
        self.assertEqual(by_qn["pyproject.toml"].name, "mini-py")
        projects = self._qns("Project")
        self.assertIn("web", projects)

    def test_rust_symbols_and_contains(self):
        qns = self._qns("Symbol")
        self.assertIn("src.lib::Widget", qns)
        self.assertIn("src.lib::build", qns)
        self.assertIn("src.lib::Render", qns)
        sym = next(e for e in self._entities("Symbol") if e.qualified_name == "src.lib::Widget")
        self.assertEqual(sym.file, "src/lib.rs")
        self.assertIsNotNone(sym.line)
        self.assertEqual(sym.tier, 1)
        contains = {
            (r.src_qn, r.dst_qn) for r in self.result.relations if r.kind == "contains"
        }
        self.assertIn(("src/lib.rs", "src.lib::Widget"), contains)

    def test_relative_js_import_resolves(self):
        imports = {
            (r.src_qn, r.dst_qn, r.kind)
            for r in self.result.relations
            if r.kind == "imports"
        }
        self.assertIn(("web/index.js", "web/helper.js", "imports"), imports)
        rel = next(
            r
            for r in self.result.relations
            if r.kind == "imports" and r.src_qn == "web/index.js"
        )
        self.assertEqual(rel.provenance, "inferred")
        self.assertEqual(rel.tier, 1)
        self.assertGreaterEqual(rel.confidence, 0.9)

    def test_tangerine_adapter_symbols_tests_and_import(self):
        qns = self._qns("Symbol")
        for qn in ("tg::Item", "tg::State", "tg::Sink", "tg::make"):
            self.assertIn(qn, qns)
        tests = self._qns("Test")
        self.assertIn("tg/mod.tg::test_make", tests)
        tg_imports = [
            r
            for r in self.result.relations
            if r.kind == "imports" and r.src_qn == "tg/mod.tg"
        ]
        self.assertEqual(len(tg_imports), 1)
        self.assertEqual(tg_imports[0].dst_qn, "std::core")
        self.assertEqual(tg_imports[0].provenance, "declared")
        self.assertEqual(tg_imports[0].tier, 2)

    def test_sql_schema_columns_and_fk(self):
        schemas = self._qns("Schema")
        self.assertIn("schema.sql::orders", schemas)
        self.assertIn("schema.sql::customers", schemas)
        cols = {
            (f.subject, f.predicate, f.object)
            for f in self.result.facts
            if f.subject == "schema.sql::orders"
        }
        self.assertIn(("schema.sql::orders", "column:total", "DECIMAL(10,2)"), cols)
        fks = [
            r
            for r in self.result.relations
            if r.kind == "depends_on" and r.src_qn == "schema.sql::orders"
        ]
        self.assertEqual([r.dst_qn for r in fks], ["customers"])

    def test_env_values_are_never_recorded(self):
        configs = self._qns("Configuration")
        self.assertIn(".env::API_KEY", configs)
        self.assertIn(".env::DB_HOST", configs)
        self.assertNotIn("super-secret-value", _serialized(self.result))
        self.assertNotIn("localhost", _serialized(self.result))

    def test_unknown_extension_is_tier0_file_only(self):
        files = self._qns("File")
        self.assertIn("data/blob.xyz", files)
        blob = next(e for e in self._entities("File") if e.qualified_name == "data/blob.xyz")
        self.assertEqual(blob.tier, 0)
        symbols = [q for q in self._qns("Symbol") if q.startswith("data/blob.xyz")]
        self.assertEqual(symbols, [])

    def test_binary_file_degrades_gracefully(self):
        files = self._qns("File")
        self.assertIn("data/binary.bin", files)
        degraded = [
            f
            for f in self.result.facts
            if f.subject == "data/binary.bin" and f.object == "binary"
        ]
        self.assertEqual(len(degraded), 1)
        self.assertIsNotNone(degraded[0].uncertainty)

    def test_dockerfile_becomes_deployment(self):
        deployments = self._qns("Deployment")
        self.assertIn("Dockerfile", deployments)

    def test_empty_directory_yields_repository_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = extract(tmp)
            self.assertEqual(len(result.entities), 1)
            self.assertEqual(result.entities[0].kind, "Repository")


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
        self.assertEqual(report["schema_version"], 1)
        self.assertGreater(report["counts_by_kind"].get("Symbol", 0), 0)
        parsed = json.loads(report_to_json(report))
        self.assertEqual(parsed["commit_sha"], report["commit_sha"])

    def test_scan_is_idempotent(self):
        first = scan(self.repo, self.db)
        second = scan(self.repo, self.db)
        self.assertEqual(first["snapshot_id"], second["snapshot_id"])
        self.assertEqual(first["entities_upserted"], second["entities_upserted"])
        self.assertEqual(second["stale_entities"], 0)
        with Graph.open(self.db, create=False) as graph:
            stats = graph.stats()
        self.assertEqual(
            stats["entities_by_kind"], first["counts_by_kind"]
        )

    def test_rescan_marks_removed_file_stale(self):
        scan(self.repo, self.db)
        (self.repo / "src" / "main.rs").unlink()
        report = scan(self.repo, self.db)
        self.assertGreater(report["stale_entities"], 0)
        with Graph.open(self.db, create=False) as graph:
            row = graph.find_entity("File", "src/main.rs")
        self.assertIsNotNone(row)
        self.assertEqual(row["stale"], 1)

    def test_scan_creates_database_and_dirs(self):
        nested = Path(self.tmp) / "nested" / "dir" / "graph.db"
        report = scan(self.repo, nested)
        self.assertTrue(nested.exists())
        self.assertEqual(report["db_path"], str(nested))


if __name__ == "__main__":
    unittest.main()
