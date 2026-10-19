#!/usr/bin/env bash
# ———————————————————————————————————————————————————————————————
# scripts/test_release_gate_skip_semantics.sh
#
# Pins the release-gate SKIP invariant:
#   dev/local: an absent optional capability may SKIP (exit 0)
#   TG_RELEASE_GATE=1: a REQUIRED compiler route or a required structural
#   parity surface being absent is a FAILURE (nonzero), never a green job.
#
# Uses a deliberately broken compiler (every subcommand exits 1) so the
# capability probes cannot be satisfied.  Also pins the required CI steps
# to the strict environment and rejects forced structural degradation in
# strict mode.
#
# Exit: 0 every assertion holds; 1 otherwise.
# ———————————————————————————————————————————————————————————————
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

WORK="$ROOT/build/.release_gate_skip_test"
rm -rf "$WORK"
mkdir -p "$WORK"

FAKE="$WORK/fake_tg"
cat > "$FAKE" <<'FAKE_EOF'
#!/usr/bin/env bash
# A compiler that serves no route (the capability-absent probe).
exit 1
FAKE_EOF
chmod +x "$FAKE"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILS=$((FAILS + 1)); }

run_case() {
  local name="$1" expect="$2" gate="$3" force="$4" script="$5"
  shift 5
  local out rc
  out="$("$@" 2>&1)"
  rc=$?
  case "$expect" in
    skip)
      if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "SKIP"; then
        pass "$name"
      else
        fail "$name (expected dev SKIP/exit 0, got rc=$rc: $out)"
      fi
      ;;
    fail)
      if [ "$rc" -ne 0 ]; then
        pass "$name"
      else
        fail "$name (expected release FAIL/nonzero, got rc=0: $out)"
      fi
      ;;
  esac
}

# Differential corpus: route absent.
run_case "differential dev SKIP" skip 0 0 x \
  env TG_RELEASE_GATE=0 bash tests/run_differential_corpus_tests.sh "$FAKE" "$WORK/diff_dev"
run_case "differential release FAIL (LIR/direct route absent)" fail 1 0 x \
  env TG_RELEASE_GATE=1 bash tests/run_differential_corpus_tests.sh "$FAKE" "$WORK/diff_gate"
run_case "differential --gate FAIL" fail 1 0 x \
  bash tests/run_differential_corpus_tests.sh --gate "$FAKE" "$WORK/diff_flag"
run_case "differential release rejects forced structural mode" fail 1 1 x \
  env TG_RELEASE_GATE=1 TG_DIFF_FORCE_STRUCTURAL=1 bash tests/run_differential_corpus_tests.sh "$FAKE" "$WORK/diff_force"

# Behavior suites: `tg test` route absent.
run_case "behavior dev SKIP" skip 0 0 x \
  env TG_RELEASE_GATE=0 bash tests/run_behavior_suites.sh "$FAKE" "$WORK/beh_dev"
run_case "behavior release FAIL (tg test absent)" fail 1 0 x \
  env TG_RELEASE_GATE=1 bash tests/run_behavior_suites.sh "$FAKE" "$WORK/beh_gate"

# Cross lanes: embedded / no_std routes absent.
run_case "embedded dev SKIP" skip 0 0 x \
  env TG_RELEASE_GATE=0 bash tests/run_embedded_lane.sh "$FAKE" "$WORK/emb_dev"
run_case "embedded release FAIL (route absent)" fail 1 0 x \
  env TG_RELEASE_GATE=1 bash tests/run_embedded_lane.sh "$FAKE" "$WORK/emb_gate"
run_case "nostd dev SKIP" skip 0 0 x \
  env TG_RELEASE_GATE=0 bash tests/run_nostd_bare_lane.sh "$FAKE" "$WORK/no_dev"
run_case "nostd release FAIL (route absent)" fail 1 0 x \
  env TG_RELEASE_GATE=1 bash tests/run_nostd_bare_lane.sh "$FAKE" "$WORK/no_gate"

# The required CI steps must actually opt into strict mode.
for required in \
  ".woodpecker/verify-core.yaml:TG_RELEASE_GATE=1 bash tests/run_differential_corpus_tests.sh" \
  ".woodpecker/verify-core.yaml:TG_RELEASE_GATE=1 bash tests/run_behavior_suites.sh" \
  ".woodpecker/verify-cross.yaml:TG_RELEASE_GATE=1 bash tests/run_embedded_lane.sh" \
  ".woodpecker/verify-cross.yaml:TG_RELEASE_GATE=1 bash tests/run_nostd_bare_lane.sh"; do
  file="${required%%:*}"
  needle="${required#*:}"
  if grep -Fq -- "$needle" "$file"; then
    pass "CI wiring: $file"
  else
    fail "CI wiring missing in $file: $needle"
  fi
done

if [ "$FAILS" -eq 0 ]; then
  echo "release-gate skip semantics: PASS"
  exit 0
fi
echo "release-gate skip semantics: $FAILS FAILURE(S)" >&2
exit 1
