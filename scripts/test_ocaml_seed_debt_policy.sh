#!/usr/bin/env bash
# test_ocaml_seed_debt_policy.sh — regression lane for the accepted-debt
# authority and the three-scalar monotonic policy (audit P0/P1-1).
#
# check_ocaml_seed_health.sh runs this lane after `dune build`, and the
# lane exercises the SAME helper the health script's debt policy invokes
# (scripts/check_ocaml_seed_debt_policy.sh), which in turn consumes the
# SAME authority (stage0_ocaml/selfcheck/tg_bootstrap_accepted.exe
# --print-debt-json).  Proves:
#
#   (a) a secondary-only regression against a synthetic accepted record
#       FAILS the comparison (total and primary flat: 100/50/50 accepted,
#       100/50/51 current), and primary-only / total regressions fail
#       too; unchanged and improved tuples pass;
#   (b) corrupted pointers — bad SHA-256, missing record, malformed debt
#       schema (total <> primary + secondary, negative, missing field),
#       malformed pointer (missing evidence_sha256) — make the authority
#       exit non-zero with empty stdout, and the policy helper fails
#       CLOSED instead of skipping the comparison; malformed/empty
#       authority output also fails closed (fake authorities);
#   (c) the real current tree resolves through the authority and passes
#       the policy (current == accepted);
#   (d) the bypass that caused P0/P1-1 cannot silently return: the health
#       script contains no accepted.json/python parsing of its own and
#       calls the policy helper with all three current scalars.
#
# Exit: 0 = all regression proofs hold; 1 = a proof failed; 2 = setup.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXE="$ROOT/stage0_ocaml/_build/default/selfcheck/tg_bootstrap_accepted.exe"
POLICY="$ROOT/scripts/check_ocaml_seed_debt_policy.sh"
HEALTH="$ROOT/scripts/check_ocaml_seed_health.sh"

FAILURES=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() {
  printf '  FAIL: %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

if [ ! -x "$EXE" ]; then
  echo "test_ocaml_seed_debt_policy: building the authority (dune build selfcheck/tg_bootstrap_accepted.exe)"
  (cd "$ROOT/stage0_ocaml" && dune build selfcheck/tg_bootstrap_accepted.exe)
fi
if [ ! -x "$EXE" ]; then
  echo "test_ocaml_seed_debt_policy: FAIL — authority $EXE is not built" >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tg_seed_debt_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

sha256_text() { # text -> hex digest (via a temp file)
  printf '%s' "$1" >"$WORK/sha_input.txt"
  sha256_of "$WORK/sha_input.txt"
}

mk_repo() {
  local repo="$WORK/$1"
  mkdir -p "$repo/bootstrap/evidence/ocaml"
  printf '%s' "$repo"
}

write_pointer() { # repo record_name sha
  printf '{ "evidence_record": "%s", "evidence_sha256": "%s", "approved_by": "regression", "approval_reason": "regression" }\n' \
    "$2" "$3" >"$1/bootstrap/evidence/ocaml/accepted.json"
}

write_record() { # repo record_name content
  printf '%s\n' "$3" >"$1/bootstrap/evidence/ocaml/$2"
}

policy() { # repo current_total current_primary current_secondary [authority_exe]
  if [ $# -ge 5 ]; then
    "$POLICY" --repo-root "$1" --current-total "$2" --current-primary "$3" --current-secondary "$4" \
      --authority-exe "$5"
  else
    "$POLICY" --repo-root "$1" --current-total "$2" --current-primary "$3" --current-secondary "$4"
  fi
}

expect_zero() { # name cmd...
  local name="$1"
  shift
  set +e
  "$@" >"$WORK/out" 2>&1
  local status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    pass "$name"
  else
    cat "$WORK/out" >&2
    fail "$name (expected exit 0, got $status)"
  fi
}

expect_nonzero() { # name cmd...
  local name="$1"
  shift
  set +e
  "$@" >"$WORK/out" 2>&1
  local status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    pass "$name"
  else
    cat "$WORK/out" >&2
    fail "$name (expected non-zero, got 0)"
  fi
}

expect_nonzero_output_has() { # name needle cmd...
  local name="$1" needle="$2"
  shift 2
  set +e
  "$@" >"$WORK/out" 2>&1
  local status=$?
  set -e
  if [ "$status" -ne 0 ] && grep -q -- "$needle" "$WORK/out"; then
    pass "$name"
  else
    cat "$WORK/out" >&2
    fail "$name (expected non-zero containing '$needle', got exit $status)"
  fi
}

echo "TG SEED DEBT POLICY REGRESSION LANE"

# ── (a) synthetic accepted record: secondary-only regression fails ──
REC_OK='{ "bootstrap_check": { "debt_total": 100, "debt_primary": 50, "debt_secondary": 50 } }'
REPO_OK="$(mk_repo ok)"
write_record "$REPO_OK" aaaaaaa_1.json "$REC_OK"
write_pointer "$REPO_OK" aaaaaaa_1.json "$(sha256_of "$REPO_OK/bootstrap/evidence/ocaml/aaaaaaa_1.json")"

set +e
AUTH_LINE="$("$EXE" --print-debt-json --repo-root "$REPO_OK" 2>"$WORK/auth_err")"
AUTH_STATUS=$?
set -e
if [ "$AUTH_STATUS" -eq 0 ] &&
  [ "$AUTH_LINE" = '{"record":"aaaaaaa_1.json","total":100,"primary":50,"secondary":50}' ]; then
  pass "authority prints the canonical one-line debt object"
else
  cat "$WORK/auth_err" >&2
  fail "authority canonical output (exit $AUTH_STATUS): $AUTH_LINE"
fi

expect_zero "unchanged tuple passes (100/50/50)" policy "$REPO_OK" 100 50 50
expect_zero "improved tuple passes (99/50/49)" policy "$REPO_OK" 99 50 49
expect_nonzero_output_has "SECONDARY-ONLY regression fails (100/50/51)" "debt_secondary grew" \
  policy "$REPO_OK" 100 50 51
expect_nonzero_output_has "primary-only regression fails (100/51/49)" "debt_primary grew" \
  policy "$REPO_OK" 100 51 49
expect_nonzero_output_has "total regression fails (101/50/51)" "debt_total grew" \
  policy "$REPO_OK" 101 50 51

# ── (b) corrupted pointers fail the authority and the policy closed ──
REPO_BADHASH="$(mk_repo badhash)"
write_record "$REPO_BADHASH" bbbbbbb_2.json "$REC_OK"
write_pointer "$REPO_BADHASH" bbbbbbb_2.json "$(sha256_text tampered)"
expect_nonzero "bad SHA-256: authority rejected" "$EXE" --print-debt-json --repo-root "$REPO_BADHASH"
AUTH_STDOUT="$("$EXE" --print-debt-json --repo-root "$REPO_BADHASH" 2>/dev/null || true)"
if [ -z "$AUTH_STDOUT" ]; then pass "bad SHA-256: authority stdout is empty"; else fail "bad SHA-256: authority printed '$AUTH_STDOUT'"; fi
expect_nonzero "bad SHA-256: policy fails closed (no silent skip)" policy "$REPO_BADHASH" 0 0 0

REPO_MISSING="$(mk_repo missing)"
write_pointer "$REPO_MISSING" missing_record.json "$(sha256_text nothing)"
expect_nonzero "missing record: authority rejected" "$EXE" --print-debt-json --repo-root "$REPO_MISSING"
expect_nonzero "missing record: policy fails closed" policy "$REPO_MISSING" 0 0 0

REPO_POINTER="$(mk_repo malformed_pointer)"
printf '{ "evidence_record": "ddddddd_4.json" }\n' >"$REPO_POINTER/bootstrap/evidence/ocaml/accepted.json"
expect_nonzero "malformed pointer (no evidence_sha256): authority rejected" "$EXE" --print-debt-json \
  --repo-root "$REPO_POINTER"
expect_nonzero "malformed pointer: policy fails closed" policy "$REPO_POINTER" 0 0 0

corrupt_repo() { # name record_content
  local repo
  repo="$(mk_repo "$1")"
  write_record "$repo" ccccccc_3.json "$2"
  write_pointer "$repo" ccccccc_3.json "$(sha256_of "$repo/bootstrap/evidence/ocaml/ccccccc_3.json")"
  printf '%s' "$repo"
}

REPO_INCONSISTENT="$(corrupt_repo inconsistent '{ "debt_total": 10, "debt_primary": 3, "debt_secondary": 3 }')"
expect_nonzero "malformed schema (total <> primary + secondary): authority rejected" "$EXE" \
  --print-debt-json --repo-root "$REPO_INCONSISTENT"
expect_nonzero "malformed schema: policy fails closed" policy "$REPO_INCONSISTENT" 0 0 0

REPO_NEGATIVE="$(corrupt_repo negative '{ "debt_total": -1, "debt_primary": 0, "debt_secondary": -1 }')"
expect_nonzero "negative debt facts: authority rejected" "$EXE" --print-debt-json --repo-root "$REPO_NEGATIVE"
expect_nonzero "negative debt facts: policy fails closed" policy "$REPO_NEGATIVE" 0 0 0

REPO_NOFIELD="$(corrupt_repo nofield '{ "debt_total": 6, "debt_primary": 3 }')"
expect_nonzero "missing debt field: authority rejected" "$EXE" --print-debt-json --repo-root "$REPO_NOFIELD"
expect_nonzero "missing debt field: policy fails closed" policy "$REPO_NOFIELD" 0 0 0

# Malformed / empty / inconsistent AUTHORITY OUTPUT must also fail closed
# (fake authorities via the regression-only --authority-exe flag): prove
# the policy never skips when the authority line is unusable.
FAKE_VALID="$WORK/fake_valid.sh"
cat >"$FAKE_VALID" <<'EOF'
#!/bin/sh
printf '%s\n' '{"record":"fake.json","total":100,"primary":50,"secondary":50}'
EOF
FAKE_GARBAGE="$WORK/fake_garbage.sh"
cat >"$FAKE_GARBAGE" <<'EOF'
#!/bin/sh
echo "total=100 primary=50 secondary=50"
EOF
FAKE_EMPTY="$WORK/fake_empty.sh"
cat >"$FAKE_EMPTY" <<'EOF'
#!/bin/sh
exit 0
EOF
FAKE_TWOLINES="$WORK/fake_twolines.sh"
cat >"$FAKE_TWOLINES" <<'EOF'
#!/bin/sh
printf '%s\n' '{"record":"fake.json","total":100,"primary":50,"secondary":50}'
echo extra
EOF
FAKE_INCONSISTENT="$WORK/fake_inconsistent.sh"
cat >"$FAKE_INCONSISTENT" <<'EOF'
#!/bin/sh
printf '%s\n' '{"record":"fake.json","total":101,"primary":50,"secondary":50}'
EOF
FAKE_FAILING="$WORK/fake_failing.sh"
cat >"$FAKE_FAILING" <<'EOF'
#!/bin/sh
echo "authority exploded" >&2
exit 3
EOF
chmod +x "$FAKE_VALID" "$FAKE_GARBAGE" "$FAKE_EMPTY" "$FAKE_TWOLINES" "$FAKE_INCONSISTENT" "$FAKE_FAILING"

expect_zero "fake authority with valid JSON passes (flag plumbing)" policy "$REPO_OK" 100 50 50 "$FAKE_VALID"
expect_nonzero "garbage authority output fails closed" policy "$REPO_OK" 100 50 50 "$FAKE_GARBAGE"
expect_nonzero "empty authority output fails closed" policy "$REPO_OK" 100 50 50 "$FAKE_EMPTY"
expect_nonzero "two-line authority output fails closed" policy "$REPO_OK" 100 50 50 "$FAKE_TWOLINES"
expect_nonzero "inconsistent authority schema fails closed" policy "$REPO_OK" 100 50 50 "$FAKE_INCONSISTENT"
expect_nonzero "non-zero authority exit fails closed" policy "$REPO_OK" 100 50 50 "$FAKE_FAILING"

# ── (c) the real current tree loads and passes ─────────────────────
set +e
REAL_LINE="$("$EXE" --print-debt-json --repo-root "$ROOT" 2>"$WORK/real_err")"
REAL_STATUS=$?
set -e
if [ "$REAL_STATUS" -eq 0 ]; then
  REAL_SCALARS="$(printf '%s' "$REAL_LINE" |
    sed -nE 's/^\{"record":"[^"]*","total":([0-9]+),"primary":([0-9]+),"secondary":([0-9]+)\}$/\1 \2 \3/p')"
  if [ -n "$REAL_SCALARS" ]; then
    # shellcheck disable=SC2086
    expect_zero "real tree passes (current == accepted: $REAL_SCALARS)" policy "$ROOT" $REAL_SCALARS
  else
    fail "real tree authority output not canonical: $REAL_LINE"
  fi
else
  cat "$WORK/real_err" >&2
  fail "real tree authority failed (exit $REAL_STATUS)"
fi

# ── (d) static anti-bypass: the health script cannot silently revert ──
if grep -q 'python3' "$HEALTH"; then
  fail "health script still parses debt JSON with python3"
else
  pass "health script contains no python3 debt parsing"
fi
if grep -q 'EVIDENCE_JSON\|REC_TOTAL\|REC_PRIMARY\|REC_SECONDARY' "$HEALTH"; then
  fail "health script still has the old bypass variables"
else
  pass "health script has no old bypass variables"
fi
for needle in 'check_ocaml_seed_debt_policy.sh' '--current-total' '--current-primary' '--current-secondary'; do
  if grep -q -- "$needle" "$HEALTH"; then
    pass "health script invokes the policy helper with $needle"
  else
    fail "health script is missing '$needle' in its debt policy"
  fi
done

if [ "$FAILURES" -ne 0 ]; then
  printf 'TG SEED DEBT POLICY REGRESSION LANE: FAIL (%d)\n' "$FAILURES"
  exit 1
fi
printf 'TG SEED DEBT POLICY REGRESSION LANE: PASS\n'
