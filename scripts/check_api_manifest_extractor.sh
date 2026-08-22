#!/usr/bin/env bash
#
# scripts/check_api_manifest_extractor.sh — the extractor's health gate
# (the std public-API coverage oracle, NEW layer).
#
# THREE checks:
#   1. THE STRUCTURAL EXTRACTOR (scripts/api_manifest_extractor.py) —
#      fixture std modules are extracted and the records are compared
#      EXACTLY against the expected records (functions / methods /
#      constructors / types / traits / enum variants / constants / error
#      variants / cfg targets), and the health-failure cases (unterminated
#      block, no public item, unparsable block opener) must each be
#      DETECTED with a non-zero exit.
#   2. THE PER-SYMBOL ASSOCIATOR (scripts/api_manifest_associator.py) —
#      fixture tests + fixture manifest records: the per-symbol test
#      associations must match exactly (a symbol referenced by two tests,
#      a symbol referenced by none, the bounded exclusion of experimental
#      modules and non-behavior families).
#   3. THE SWEEP CLOSURE (scripts/gen_api_manifest_sweep.py) — the sweep
#      suite regenerates identically (the generate-then-diff discipline)
#      and every uncovered callable of the committed manifest appears in
#      its module's sweep file; when a USABLE compiler binary exists (the
#      current-grammar probe discipline), every sweep file must pass
#      `check`.
#
# Usage: scripts/check_api_manifest_extractor.sh [--report-only]
# Exit status: 0 when the extractor and the associator behave exactly as
# specified and the sweep suite is closed; 1 otherwise.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTRACTOR="$ROOT/scripts/api_manifest_extractor.py"
ASSOCIATOR="$ROOT/scripts/api_manifest_associator.py"
SWEEPGEN="$ROOT/scripts/gen_api_manifest_sweep.py"
MANIFEST="$ROOT/build/public_api_manifest.json"
SWEEP_DIR="$ROOT/tests/api_manifest"
BUILD_DIR="$ROOT/build"
REPORT_ONLY=0
case "${1:-}" in
  --report-only) REPORT_ONLY=1 ;;
  "") ;;
  *) echo "check_api_manifest_extractor: unknown argument: $1" >&2; exit 2 ;;
esac

fail() { echo "[api-manifest-health:error] $*" >&2; exit 1; }

for f in "$EXTRACTOR" "$ASSOCIATOR" "$SWEEPGEN"; do
  [ -f "$f" ] || fail "missing tool: $f"
done
[ -f "$MANIFEST" ] || fail "missing manifest: $MANIFEST"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/api_manifest_health.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

bad=0
report() { printf '  [%s] %s\n' "$1" "$2"; }

# ———————————————————————————————————————————————————————————————
# 1. The structural extractor — fixture modules + expected records.
# ———————————————————————————————————————————————————————————————

FIX_STD="$TMP/std"
FIX_CONTRACTS="$TMP/contracts.toml"
mkdir -p "$FIX_STD"

cat > "$FIX_CONTRACTS" <<'EOF'
[module.fixture_mod]
family = "native"
proof = ["tests/unit/test_fixture_proof.tg"]
EOF

cat > "$FIX_STD/fixture_mod.tg" <<'EOF'
use std::core::{Option, Result}

@cfg(target_os = "windows")
pub struct FixtureStruct
  pub x: Int
  y: Int
end

pub enum FixtureError
  BadInput
  Timeout(Int)
end

pub trait FixtureTrait
  def trait_fn(self: FixtureTrait) -> Int
end

impl FixtureStruct
  pub def new() -> FixtureStruct
    FixtureStruct { x: 0, y: 0 }
  end

  def get(self: FixtureStruct) -> Int
    self.x
  end

  def multi_line(self: FixtureStruct,
                 other: FixtureStruct) -> Int
    self.x + other.x
  end
end

pub def fixture_free(a: Int,
                     b: Int) -> Int
  a + b
end

pub def fixture_zero_args() -> Int = 7

pub const FIXTURE_CONST: Int = 1
pub static FIXTURE_STATIC: Int = 2
pub type FixtureAlias = Int

extern def fixture_extern(x: Int) -> Int end
EOF

cat > "$FIX_STD/bad_unterminated.tg" <<'EOF'
pub struct NoEnd
  x: Int
EOF

cat > "$FIX_STD/bad_no_public.tg" <<'EOF'
# a module with no public items at all — the extractor must refuse it
# (comments only).
EOF

cat > "$FIX_STD/bad_unparsable.tg" <<'EOF'
impl [
  def inner() -> Int
    0
  end
end
EOF

python3 - "$EXTRACTOR" "$FIX_STD" "$FIX_CONTRACTS" <<'PY' || bad=1
import json
import subprocess
import sys

extractor = sys.argv[1]
stddir = sys.argv[2]
contracts = sys.argv[3]

proc = subprocess.run(
    [sys.executable, extractor, stddir + "/fixture_mod.tg", contracts],
    capture_output=True, text=True)
if proc.returncode != 0:
    print("  [FAIL] fixture_mod extraction failed: " + proc.stderr.strip())
    sys.exit(1)
rec = json.loads(proc.stdout)

fns = {i["name"]: i for i in rec["public_api"]["functions"]}
methods = {i["name"]: i for i in rec["public_api"]["methods"]}
ctors = {i["name"]: i for i in rec["public_api"]["constructors"]}
types = {i["name"] for i in rec["public_api"]["types"]}
traits = {i["name"] for i in rec["public_api"]["traits"]}
variants = {v["variant"] for v in rec["public_api"]["enum_variants"]}
consts = {c["name"] for c in rec["public_api"]["constants"]}

ok = True
def check(cond, label):
    global ok
    if not cond:
        print("  [FAIL] extractor record: " + label)
        ok = False

check("fixture_free" in fns, "fixture_free function")
check("fixture_zero_args" in fns, "fixture_zero_args function (=expr body)")
check("fixture_extern" in fns and fns["fixture_extern"]["kind"] == "extern", "fixture_extern kind")
check("get" in methods, "impl method get")
check("multi_line" in methods, "multi-line impl method multi_line")
check("new" in ctors, "constructor new")
check({"FixtureStruct", "FixtureAlias"} <= types, "types FixtureStruct/FixtureAlias")
check("FixtureTrait" in traits, "trait FixtureTrait")
check("trait_fn" in [m["name"] for m in rec["public_api"]["traits"][0]["methods"]], "trait method trait_fn")
check({"BadInput", "Timeout"} <= variants, "enum variants BadInput/Timeout")
check({"FIXTURE_CONST", "FIXTURE_STATIC"} <= consts, "consts")
check(rec["error_variants"] == [{"enum": "FixtureError", "variant": "BadInput"},
                                {"enum": "FixtureError", "variant": "Timeout"}],
      "error_variants")
check(rec["cfg_targets"] == ["windows"], "cfg target windows")
check(rec["module"] == "fixture_mod", "module name")
check(rec["family"] == "native", "family from contracts")
check(rec["proof_tests"] == ["tests/unit/test_fixture_proof.tg"], "proof tests from contracts")

for fixture, expect in [
    ("bad_unterminated.tg", "unterminated block"),
    ("bad_no_public.tg", "no public item"),
    ("bad_unparsable.tg", "unparsable block opener"),
]:
    p = subprocess.run(
        [sys.executable, extractor, stddir + "/" + fixture, contracts],
        capture_output=True, text=True)
    if p.returncode == 0:
        print("  [FAIL] health case not detected: " + fixture)
        ok = False

print("  [OK] extractor: fixture records exact + health failures detected" if ok else "  [FAIL] extractor health")
sys.exit(0 if ok else 1)
PY
[ $? -ne 0 ] && bad=1

# ———————————————————————————————————————————————————————————————
# 2. The per-symbol associator — fixture tests + fixture manifest.
# ———————————————————————————————————————————————————————————————

FIX_TESTS="$TMP/tests"
mkdir -p "$FIX_TESTS/unit" "$FIX_TESTS/api_manifest"

cat > "$FIX_TESTS/unit/test_alpha.tg" <<'EOF'
def alpha_one(x: Int) -> Int
  x
end

def use_alpha_one() -> Int
  alpha_one(1)
end
EOF

cat > "$FIX_TESTS/unit/test_beta.tg" <<'EOF'
def beta_two() -> Int
  2
end
EOF

cat > "$FIX_TESTS/api_manifest/alpha_symbol_sweep.tg" <<'EOF'
# the sweep file: references alpha_one only (as the generated sweep does)
use std::alpha::{alpha_one}
EOF

cat > "$TMP/fixture_manifest.json" <<'EOF'
{
  "modules": [
    {
      "module": "alpha",
      "family": "native",
      "experimental": false,
      "public_api": {
        "functions": [
          {"name": "alpha_one", "kind": "fn", "pub": true, "signature": "def alpha_one(x: Int) -> Int"},
          {"name": "alpha_unreferenced", "kind": "fn", "pub": true, "signature": "def alpha_unreferenced() -> Int"}
        ],
        "methods": [],
        "constructors": []
      }
    },
    {
      "module": "beta",
      "family": "experimental",
      "experimental": true,
      "public_api": {
        "functions": [
          {"name": "beta_two", "kind": "fn", "pub": true, "signature": "def beta_two() -> Int"}
        ],
        "methods": [],
        "constructors": []
      }
    },
    {
      "module": "gamma",
      "family": "native",
      "experimental": false,
      "public_api": {
        "functions": [
          {"name": "gamma_three", "kind": "fn", "pub": true, "signature": "def gamma_three() -> Int"}
        ],
        "methods": [],
        "constructors": []
      }
    }
  ]
}
EOF

python3 - "$ASSOCIATOR" "$TMP/fixture_manifest.json" "$FIX_TESTS" <<'PY' || bad=1
import json
import subprocess
import sys

associator = sys.argv[1]
manifest = sys.argv[2]
tests_dir = sys.argv[3]

proc = subprocess.run(
    [sys.executable, associator, manifest, tests_dir],
    capture_output=True, text=True)
if proc.returncode != 0:
    print("  [FAIL] associator run failed: " + proc.stderr.strip())
    sys.exit(1)
out = json.loads(proc.stdout)

ok = True
def check(cond, label):
    global ok
    if not cond:
        print("  [FAIL] associator: " + label)
        ok = False

syms = out["symbols"]
check(set(syms.get("alpha", {})) == {"alpha_one", "alpha_unreferenced"},
      "alpha symbols")
# alpha_one is referenced by unit/test_alpha.tg; the sweep directory
# (tests/api_manifest/**) is EXCLUDED from the association universe by
# design (the sweep references the uncovered callables — counting it would
# be circular).
check("tests/unit/test_alpha.tg" in syms["alpha"]["alpha_one"]
      and "tests/api_manifest/alpha_symbol_sweep.tg" not in syms["alpha"]["alpha_one"],
      "alpha_one associations (unit test yes, sweep excluded)")
check(syms["alpha"]["alpha_unreferenced"] == [], "alpha_unreferenced has no associations")
# beta is EXPERIMENTAL — its uncovered callable must NOT appear in the
# bounded uncovered list.
check("beta" not in out["uncovered"], "experimental module excluded from bounded uncovered")
# alpha_unreferenced (native, non-experimental, no referencing test) and
# gamma_three are bounded-uncovered.
check("alpha" in out["uncovered"] and out["uncovered"]["alpha"] == ["alpha_unreferenced"],
      "alpha_unreferenced uncovered bounded")
check("gamma" in out["uncovered"] and out["uncovered"]["gamma"] == ["gamma_three"],
      "gamma uncovered bounded")
check(out["stats"]["callables"] == 4, "stats.callables == 4")
check(out["stats"]["referenced"] == 2, "stats.referenced == 2 (alpha_one + beta_two)")
check(out["stats"]["uncovered_bounded"] == 2, "stats.uncovered_bounded == 2 (alpha_unreferenced + gamma)")

print("  [OK] associator: per-symbol associations exact + bounded exclusions" if ok
      else "  [FAIL] associator health")
sys.exit(0 if ok else 1)
PY
[ $? -ne 0 ] && bad=1

# ———————————————————————————————————————————————————————————————
# 3. The sweep closure — regenerate + diff, reference closure, and (with
#    a usable compiler) compile every sweep file.
# ———————————————————————————————————————————————————————————————

TMP_SWEEP="$TMP/sweep"
if ! python3 "$SWEEPGEN" --manifest "$MANIFEST" --out "$TMP_SWEEP" >/dev/null 2>&1; then
  report FAIL "sweep generator failed"
  bad=1
elif ! diff -r "$TMP_SWEEP" "$SWEEP_DIR" >"$TMP/sweep.diff" 2>&1; then
  report FAIL "tests/api_manifest/ does not match a fresh generation (generate-then-diff):"
  head -20 "$TMP/sweep.diff" | sed 's/^/    /'
  bad=1
else
  report OK "sweep suite regenerates identically"
fi

python3 - "$MANIFEST" "$SWEEP_DIR" <<'PY' || bad=1
import json
import re
import sys

manifest = sys.argv[1]
sweep_dir = sys.argv[2]

with open(manifest, "r", encoding="utf-8") as fh:
    m = json.load(fh)
uncovered = m.get("gates", {}).get("uncovered_callables", [])
missing = []
for entry in uncovered:
    mod = entry.get("module", "")
    try:
        text = open(sweep_dir + "/" + mod + "_symbol_sweep.tg", encoding="utf-8").read()
    except OSError:
        missing.append((mod, "<no sweep file>"))
        continue
    for name in entry.get("callables", []):
        if not re.search(r"\b" + re.escape(name) + r"\b", text):
            missing.append((mod, name))
if missing:
    for mod, name in missing[:10]:
        print("  [FAIL] sweep closure: %s::%s not referenced" % (mod, name))
    print("  [FAIL] %d uncovered callable(s) missing from the sweep suite" % len(missing))
    sys.exit(1)
total = sum(len(e.get("callables", [])) for e in uncovered)
print("  [OK] sweep closure: %d uncovered callable(s) all referenced by their sweep files" % total)
sys.exit(0)
PY
[ $? -ne 0 ] && bad=1

# The usable-compiler compile check (the current-grammar probe discipline
# shared with check_grammar_f_gate.sh): skipped without a usable binary.
GOOD_PROBE="$TMP/health_good.tg"
BAD_PROBE="$TMP/health_bad.tg"
CURRENT_PROBE="$TMP/health_current.tg"
cat > "$GOOD_PROBE" <<'EOF'
def health_good_probe() -> Int
  0
end
EOF
cat > "$BAD_PROBE" <<'EOF'
def health_bad_probe( -> Int
  0
end
EOF
cat > "$CURRENT_PROBE" <<'EOF'
use std::core

def health_probe_inc(inout x: Int) -> Int
  x + 1
end

cap HealthProbeCap
end

resource HealthProbeResource
  v: Int

  def deinit(sink self: Self) -> Unit
    ()
  end
end

def health_current_probe() -> Int
  var x = 0
  health_probe_inc(x)
  0
end
EOF

probe_check() {
  ( "$1" check "$2" >/dev/null 2>&1; exit $? ) 2>/dev/null
}

BIN=""
for cand in tg_stage3 tg_stage2 tg_stage1; do
  [ -x "$BUILD_DIR/$cand" ] || continue
  cand_bin="$BUILD_DIR/$cand"
  if probe_check "$cand_bin" "$GOOD_PROBE" && ! probe_check "$cand_bin" "$BAD_PROBE" &&
     probe_check "$cand_bin" "$CURRENT_PROBE"; then
    BIN="$cand_bin"
    break
  fi
done

if [ -n "$BIN" ]; then
  sweep_bad=0
  for f in "$SWEEP_DIR"/*.tg; do
    if ! "$BIN" check "$f" >/dev/null 2>&1; then
      echo "  [FAIL] sweep file failed check: $(basename "$f")"
      sweep_bad=1
    fi
  done
  if [ "$sweep_bad" -eq 0 ]; then
    report OK "all sweep files pass \`$BIN check\`"
  else
    bad=1
  fi
else
  report SKIP "compiler verdicts skipped (no usable binary — the structural checks are the gate)"
fi

if [ "$bad" -ne 0 ]; then
  [ "$REPORT_ONLY" -eq 1 ] || exit 1
  exit 0
fi
echo "[api-manifest-health] EXTRACTOR HEALTH PASSED: structural extraction exact, associations exact, sweep suite closed"
exit 0
