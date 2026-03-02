from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
import importlib.util
import sys

ROOT = Path(__file__).resolve().parents[1]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


class ScriptTests(unittest.TestCase):
    def test_control_flow_defaults_include_golden(self):
        mod = load_module("check_tg_control_flow_forms", ROOT / "check_tg_control_flow_forms.py")
        self.assertIn("golden", mod.DEFAULT_ROOTS)

    def test_fix_struct_nested(self):
        mod = load_module("fix_struct_syntax", ROOT / "fix_struct_syntax.py")
        content = "struct A {\n  def f() {\n    1\n  }\n}\n"
        out, changes = mod.transform_content(Path("sample.tg"), content)
        self.assertIn("struct A", out)
        self.assertIn("def f()", out)
        self.assertGreaterEqual(changes, 3)
        self.assertNotIn("{", out)

    def test_fix_struct_generic_impl(self):
        mod = load_module("fix_struct_syntax", ROOT / "fix_struct_syntax.py")
        content = "impl[T] Box[T] {\n  def get(self: &Self) -> T {\n    self.value\n  }\n}\n"
        out, changes = mod.transform_content(Path("sample.tg"), content)
        self.assertIn("impl[T] Box[T]", out)
        self.assertIn("def get", out)
        self.assertGreaterEqual(changes, 3)
        self.assertNotIn("{", out)

    def test_check_encoding_detects_bom(self):
        mod = load_module("check_encoding", ROOT / "check_encoding.py")
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "x.tg"
            p.write_bytes(b"\xef\xbb\xbfdef main() -> Int\n  0\nend\n")
            old_argv = sys.argv
            try:
                sys.argv = ["check_encoding.py", td]
                rc = mod.main()
            finally:
                sys.argv = old_argv
            self.assertEqual(rc, 1)

    def test_control_flow_ignores_string_continue(self):
        mod = load_module("check_tg_control_flow_forms", ROOT / "check_tg_control_flow_forms.py")
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "x.tg"
            p.write_text('def demo()\n  let s = "continue in string"\n  # continue in comment\n  next\nend\n', encoding="utf-8")
            issues = mod.scan_file(p)
            self.assertEqual(issues, [])

    def test_tg_cov_merge_branch_aware(self):
        mod = load_module("tg_cov_merge", ROOT / "tg_cov_merge.py")
        r1 = {"file": "a.tg", "line": 10, "branch_id": "b1", "arm_id": "a1", "hits": 1, "count": 1}
        r2 = {"file": "a.tg", "line": 10, "branch_id": "b2", "arm_id": "a1", "hits": 1, "count": 1}
        merged = mod.merge_records([r1, r2])
        self.assertEqual(len(merged), 2)

    def test_tg_cov_merge_malformed_input(self):
        mod = load_module("tg_cov_merge", ROOT / "tg_cov_merge.py")
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "bad.json"
            p.write_text("{not json", encoding="utf-8")
            records = mod.load_coverage(p)
            self.assertEqual(records, [])


if __name__ == "__main__":
    unittest.main()
