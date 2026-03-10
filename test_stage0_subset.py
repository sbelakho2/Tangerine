#!/usr/bin/env python3
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parent
STAGE0 = ROOT / "stage0" / "_build" / "default" / "bin" / "main.exe"


def run(command, cwd=None):
    return subprocess.run(command, cwd=cwd or ROOT, capture_output=True, text=True, check=True)


class Stage0SubsetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        run(["opam", "exec", "--", "dune", "build"], cwd=ROOT / "stage0")

    def compile_and_run(self, source_name, expected_exit):
        with tempfile.TemporaryDirectory(prefix="tgc0_subset_") as tmp_dir:
            output_path = pathlib.Path(tmp_dir) / pathlib.Path(source_name).stem
            compile_result = subprocess.run(
                [str(STAGE0), "compile", source_name, "-o", str(output_path)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                compile_result.returncode,
                0,
                msg=f"compile failed for {source_name}:\nSTDOUT:\n{compile_result.stdout}\nSTDERR:\n{compile_result.stderr}",
            )
            run_result = subprocess.run([str(output_path)], cwd=ROOT)
            self.assertEqual(run_result.returncode, expected_exit)

    def compile_only(self, source_name):
        with tempfile.TemporaryDirectory(prefix="tgc0_subset_") as tmp_dir:
            output_path = pathlib.Path(tmp_dir) / pathlib.Path(source_name).stem
            compile_result = subprocess.run(
                [str(STAGE0), "compile", source_name, "-o", str(output_path)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                compile_result.returncode,
                0,
                msg=f"compile failed for {source_name}:\nSTDOUT:\n{compile_result.stdout}\nSTDERR:\n{compile_result.stderr}",
            )
            self.assertTrue(output_path.exists(), msg=f"expected compiled output for {source_name}")

    def test_calc_mini_compiles_and_runs(self):
        self.compile_and_run("test_calc_mini.tg", 42)

    def test_import_compiles_and_runs(self):
        self.compile_and_run("test_import.tg", 0)

    def test_struct_enum_compiles_and_runs(self):
        self.compile_and_run("test_struct_enum.tg", 31)

    def test_calculator_app_compiles(self):
        self.compile_only("calculator_app/calculator.tg")


if __name__ == "__main__":
    unittest.main()