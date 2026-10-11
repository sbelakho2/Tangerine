#!/usr/bin/env bash
# scripts/test_object_fingerprint_integrity.sh — mutation tests for the
# object-phase fingerprint integrity contract (the P0 release-proof bug).
#
# THE BUG THIS PINS: bh_fingerprints used to run the otool/nm probes through
# `... 2>/dev/null | sed ... || true` and hash the captured stdout. A FAILED
# probe left stdout empty, so the phase was recorded as sha256("") — a
# valid-looking digest. With both stages failing the same probe,
# sha256("") == sha256("") and the stage2==stage3 reproducibility gate proved
# equality of FAILURES instead of compiler output.
#
# THE CONTRACT ENFORCED HERE (through the real shared helpers — this test
# sources scripts/bootstrap_helpers.sh and calls bh_fingerprints /
# bh_phase_equality with stub otool/nm/compiler binaries on PATH):
#   1. every probe record carries probe_success/byte_count/digest;
#   2. a failed probe is recorded UNAVAILABLE with probe_success=false and is
#      NEVER hashed — a failed empty stdout can never become sha256("");
#   3. a legitimately successful empty capture (probe_success=true,
#      byte_count=0, digest=sha256("")) is allowed and compares equal only
#      when BOTH stages succeeded;
#   4. bh_phase_equality release mode fails on ANY UNAVAILABLE phase, and it
#      compares probe_success and byte_count as well as the digest;
#   5. successful-probe digests are byte-stable: the same captured bytes hash
#      to the same digest as before.
#
# Self-contained: stub toolchain + fake stage binaries; no OCaml seed and no
# built compiler are required.
#
# Usage: bash scripts/test_object_fingerprint_integrity.sh
# Exit status: 0 = every case correct; 1 = at least one case failed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tg-fp-integrity.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "fingerprint-integrity: PASS - $*"; }
bad() {
  echo "fingerprint-integrity: FAIL - $*" >&2
  fail=1
}

# ── portable sha256 (independent of the helpers under test) ───────────
sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}
sha256_str() { printf '%s' "$1" | sha256_stdin; }
byte_count_of() { printf '%s' "$1" | wc -c | tr -d ' '; }
EMPTY_SHA="$(sha256_str '')"

# ── stub toolchain ─────────────────────────────────────────────────────
# stubs-fail: otool/nm exit NONZERO with EMPTY stdout — the P0 mutation.
# stubs-ok:   otool/nm emit deterministic bytes; `otool -r` emits only the
#             header line, i.e. a legitimately EMPTY SUCCESSFUL capture.
# cc:         a --dump-* compiler stub (deterministic, nonempty dumps).
mkdir -p "$TMP/stubs-fail" "$TMP/stubs-ok"

cat >"$TMP/stubs-fail/otool" <<'STUB'
#!/usr/bin/env bash
# P0 mutation: fail with empty stdout.
exit 1
STUB
cat >"$TMP/stubs-fail/nm" <<'STUB'
#!/usr/bin/env bash
# P0 mutation: fail with empty stdout.
exit 1
STUB
chmod +x "$TMP/stubs-fail/otool" "$TMP/stubs-fail/nm"

cat >"$TMP/stubs-ok/otool" <<'STUB'
#!/usr/bin/env bash
mode=""
file=""
for arg in "$@"; do
  case "$arg" in
    -tv) mode=text ;;
    -l) mode=sections ;;
    -r) mode=relocs ;;
  esac
  file="$arg"
done
case "$mode" in
  text)
    printf '%s:\n' "$file"
    printf '\t.text\n'
    printf '\tmov x0, #0\n'
    ;;
  sections)
    printf '%s:\n' "$file"
    printf '  sectname __text\n'
    printf '  segname __TEXT\n'
    printf '  addr 0x1000\n'
    printf '  size 0x10\n'
    ;;
  relocs)
    # Header only: after the header strip the capture is legitimately empty.
    printf '%s:\n' "$file"
    ;;
  *)
    exit 2
    ;;
esac
STUB
cat >"$TMP/stubs-ok/nm" <<'STUB'
#!/usr/bin/env bash
printf '0000000100000002 T _second\n'
printf '0000000100000000 T _main\n'
STUB
cat >"$TMP/stubs-ok/cc" <<'STUB'
#!/usr/bin/env bash
flag=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dump-tokens) flag=tokens ;;
    --dump-ast) flag=ast ;;
    --dump-resolved-ast) flag=hir ;;
    --dump-mir-lowered) flag=mir ;;
    --dump-mir-mono) flag=mir-mono ;;
  esac
  shift
done
if [ -z "$flag" ]; then
  exit 3
fi
printf 'normalized-dump %s\n' "$flag"
STUB
cat >"$TMP/stubs-ok/cc-fail" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
cat >"$TMP/stubs-ok/cc-empty" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP/stubs-ok/otool" "$TMP/stubs-ok/nm" "$TMP/stubs-ok/cc" \
  "$TMP/stubs-ok/cc-fail" "$TMP/stubs-ok/cc-empty"

# ── fixture drivers (the REAL helpers under test) ──────────────────────
mk_binaries() { # <outdir>: identical fake stage binaries
  local out="$1"
  mkdir -p "$out"
  printf 'fake-stage-binary-payload\n' >"$out/tg_stage2"
  printf 'fake-stage-binary-payload\n' >"$out/tg_stage3"
}

# run_stage_fp <outdir> <object-stub-dir> <stage>
# Sources scripts/bootstrap_helpers.sh with TG_BOOTSTRAP_TRACE=1 and runs the
# real bh_fingerprints phase collection for one fake stage.
run_stage_fp() {
  local out="$1" stubs="$2" stage="$3"
  (
    export PATH="$stubs:$TMP/stubs-ok:$PATH"
    export TG_BOOTSTRAP_TRACE=1
    # shellcheck disable=SC1091
    source "$ROOT/scripts/bootstrap_helpers.sh"
    bh_boot_target() { printf 'aarch64-apple-darwin'; }
    bh_fingerprints "$stage" "$TMP/stubs-ok/cc" \
      "$ROOT/tg_compiler/bootstrap_main.tg" "$out"
  ) >"$out/$stage.run.log" 2>&1
}

# run_equality <outdir> [release]
# Sources the real bh_phase_equality; prints its output to <outdir>/equality.log.
run_equality() {
  local out="$1"
  shift
  (
    # shellcheck disable=SC1091
    source "$ROOT/scripts/bootstrap_helpers.sh"
    bh_phase_equality tg_stage2 tg_stage3 "$out" "$@"
  ) >"$out/equality.log" 2>&1
}

record_digest_of() { # <fingerprint-file> <phase>
  awk -v p="$2" '$1 == "FINGERPRINT" && $3 == p { print $4; exit }' "$1"
}
record_field_of() { # <fingerprint-file> <phase> <field-prefix>
  awk -v p="$2" -v f="$3" '
    $1 == "FINGERPRINT" && $3 == p {
      for (i = 1; i <= NF; i++)
        if (index($i, f "=") == 1) { print substr($i, length(f) + 2); exit }
      exit
    }' "$1"
}
expect_grep() { # <file> <ere> <label>
  if grep -qE "$2" "$1" 2>/dev/null; then
    pass "$3"
  else
    bad "$3 (pattern not found: $2)"
  fi
}
expect_log() { # <file> <ere> <label>
  if grep -qE "$2" "$1" 2>/dev/null; then
    pass "$3"
  else
    bad "$3 (pattern not found in $1: $2)"
  fi
}

# ══════════════════════════════════════════════════════════════════════
# A. THE P0 MUTATION: otool/nm fail with empty stdout
# ══════════════════════════════════════════════════════════════════════
A="$TMP/fixture-fail"
mk_binaries "$A"
if run_stage_fp "$A" "$TMP/stubs-fail" tg_stage2; then
  pass "A: fingerprint collection completed for tg_stage2 with failing object probes"
else
  bad "A: bh_fingerprints tg_stage2 crashed (see $A/tg_stage2.run.log)"
fi
if run_stage_fp "$A" "$TMP/stubs-fail" tg_stage3; then
  pass "A: fingerprint collection completed for tg_stage3 with failing object probes"
else
  bad "A: bh_fingerprints tg_stage3 crashed (see $A/tg_stage3.run.log)"
fi
fpA2="$A/.fingerprints/tg_stage2.fingerprints"
fpA3="$A/.fingerprints/tg_stage3.fingerprints"

for fp in "$fpA2" "$fpA3"; do
  name="$(basename "$fp")"
  for phase in text sections symbols relocs; do
    expect_grep "$fp" \
      "^FINGERPRINT [^ ]+ $phase UNAVAILABLE probe_success=false byte_count=0\$" \
      "A: $name $phase recorded UNAVAILABLE probe_success=false (failed probe never hashes)"
  done
  if grep -q "$EMPTY_SHA" "$fp" 2>/dev/null; then
    bad "A: $name contains sha256(\"\") — a FAILED probe forged the false-green empty digest"
  else
    pass "A: $name contains no sha256(\"\") digest for any phase"
  fi
done

# Only the object probes failed: the semantic dump routes still produced real
# digests, so the release-gate failure below is attributable to the probes.
expect_grep "$fpA2" \
  "^FINGERPRINT [^ ]+ tokens [0-9a-f]{64} probe_success=true byte_count=[1-9][0-9]*\$" \
  "A: tokens still carries a real digest (the object probes are the only failures)"

# The release comparison MUST fail: equality of failures is not equality.
if run_equality "$A" release; then
  bad "A: release fingerprint comparison PASSED with UNAVAILABLE object probes (the false green)"
else
  pass "A: release fingerprint comparison FAILS with UNAVAILABLE object probes"
  expect_log "$A/equality.log" "UNAVAILABLE" \
    "A: release comparison failed because of the UNAVAILABLE probe records"
fi
# The documented debug tolerance: both-unavailable is not comparable but only
# release/trace mode makes it fatal.
if run_equality "$A"; then
  pass "A: non-release comparison keeps the documented both-unavailable debug tolerance"
else
  bad "A: non-release comparison rejected the documented both-unavailable debug tolerance"
fi

# ══════════════════════════════════════════════════════════════════════
# B. ONE-SIDED FAILURE: stage2 probes fail, stage3 probes succeed
# ══════════════════════════════════════════════════════════════════════
B="$TMP/fixture-mixed"
mk_binaries "$B"
if run_stage_fp "$B" "$TMP/stubs-fail" tg_stage2 &&
  run_stage_fp "$B" "$TMP/stubs-ok" tg_stage3; then
  pass "B: mixed-probe fixtures collected"
else
  bad "B: mixed-probe fixture collection crashed"
fi
if run_equality "$B" release; then
  bad "B: release comparison accepted a one-sided probe failure"
else
  pass "B: release comparison fails on a one-sided probe failure"
  expect_log "$B/equality.log" "probe status mismatch|UNAVAILABLE" \
    "B: release failure is attributed to the probe status"
fi
if run_equality "$B"; then
  bad "B: non-release comparison accepted a one-sided probe failure (must fail in every mode)"
else
  pass "B: non-release comparison also fails on a one-sided probe failure"
fi

# ══════════════════════════════════════════════════════════════════════
# C. POSITIVE CONTROL: successful probes, including a legitimately empty
#    capture (otool -r prints only the header -> success with 0 bytes)
# ══════════════════════════════════════════════════════════════════════
C="$TMP/fixture-ok"
mk_binaries "$C"
if run_stage_fp "$C" "$TMP/stubs-ok" tg_stage2 &&
  run_stage_fp "$C" "$TMP/stubs-ok" tg_stage3; then
  pass "C: positive-control fixtures collected"
else
  bad "C: positive-control fixture collection crashed"
fi
fpC2="$C/.fingerprints/tg_stage2.fingerprints"
fpC3="$C/.fingerprints/tg_stage3.fingerprints"

for fp in "$fpC2" "$fpC3"; do
  name="$(basename "$fp")"
  n="$(grep -c 'probe_success=true' "$fp" || true)"
  if [ "$n" -eq 10 ]; then
    pass "C: $name records all 10 phases as successful probes"
  else
    bad "C: $name has $n successful records, want 10"
  fi
  # The legitimately empty successful capture: sha256("") is allowed ONLY
  # with probe_success=true and byte_count=0.
  expect_grep "$fp" \
    "^FINGERPRINT [^ ]+ relocs $EMPTY_SHA probe_success=true byte_count=0\$" \
    "C: $name relocs = sha256(\"\") probe_success=true byte_count=0 (legitimate empty success)"
done

# Byte-stability of the successful-probe digests: the text digest must equal
# the digest of the exact captured bytes the old pipeline hashed.
text_expected="$(printf '\t.text\n\tmov x0, #0')"
text_sha="$(sha256_str "$text_expected")"
text_bytes="$(byte_count_of "$text_expected")"
expect_grep "$fpC2" \
  "^FINGERPRINT [^ ]+ text $text_sha probe_success=true byte_count=$text_bytes\$" \
  "C: text digest is byte-stable (same bytes as the original pipeline)"
if [ "$(record_digest_of "$fpC2" text)" = "$(record_digest_of "$fpC3" text)" ] &&
  [ "$(record_field_of "$fpC2" text byte_count)" = "$(record_field_of "$fpC3" text byte_count)" ]; then
  pass "C: identical successful captures compare equal"
else
  bad "C: identical successful captures did not compare equal"
fi

# The sections digest is recomputed with the same normalization pipeline so
# the check is host-grep-independent.
printf 'sections-stub:\n' >"$TMP/sections.raw"
printf '  sectname __text\n  segname __TEXT\n  addr 0x1000\n  size 0x10\n' >>"$TMP/sections.raw"
sec_expected="$(sed '1d' "$TMP/sections.raw" \
  | grep -E '^\s+(sectname|segname|addr|size|offset|align|reloff|nreloc|flags)\s')"
sec_sha="$(sha256_str "$sec_expected")"
sec_bytes="$(byte_count_of "$sec_expected")"
expect_grep "$fpC2" \
  "^FINGERPRINT [^ ]+ sections $sec_sha probe_success=true byte_count=$sec_bytes\$" \
  "C: sections digest/byte_count match the normalization pipeline"

if run_equality "$C" release; then
  pass "C: release fingerprint comparison PASSES for two successful identical runs"
else
  bad "C: release fingerprint comparison failed for the positive control (see $C/equality.log)"
fi

# ══════════════════════════════════════════════════════════════════════
# D. TAMPER MUTATIONS: byte_count / probe_success / digest are each
#    actually compared (same-digest records cannot pass)
# ══════════════════════════════════════════════════════════════════════
copy_fixture() { # <dest> ; copies the positive-control fixture
  local dest="$1"
  mkdir -p "$dest"
  cp -R "$C/." "$dest/"
  rm -f "$dest/equality.log"
}

# D1: byte_count tampered (digest unchanged) -> must fail in EVERY mode.
D1="$TMP/fixture-bytecount"
copy_fixture "$D1"
awk '
  $1 == "FINGERPRINT" && $3 == "text" && !done {
    sub(/byte_count=[0-9]+/, "byte_count=999999")
    done = 1
  }
  { print }
' "$D1/.fingerprints/tg_stage3.fingerprints" >"$TMP/d1.fp" &&
  mv "$TMP/d1.fp" "$D1/.fingerprints/tg_stage3.fingerprints"
if run_equality "$D1" release; then
  bad "D1: release comparison accepted a byte_count mismatch with an equal digest"
else
  pass "D1: release comparison fails on a byte_count mismatch"
  expect_log "$D1/equality.log" "byte_count differs" \
    "D1: failure is attributed to the byte_count comparison"
fi
if run_equality "$D1"; then
  bad "D1: non-release comparison accepted a byte_count mismatch"
else
  pass "D1: non-release comparison also fails on a byte_count mismatch"
fi

# D2: probe_success tampered (hex digest kept) -> inconsistent record,
#     malformed, never comparable.
D2="$TMP/fixture-status"
copy_fixture "$D2"
awk '
  $1 == "FINGERPRINT" && $3 == "tokens" && !done {
    sub(/probe_success=true/, "probe_success=false")
    done = 1
  }
  { print }
' "$D2/.fingerprints/tg_stage3.fingerprints" >"$TMP/d2.fp" &&
  mv "$TMP/d2.fp" "$D2/.fingerprints/tg_stage3.fingerprints"
if run_equality "$D2" release; then
  bad "D2: release comparison accepted a digest-bearing failed-probe record"
else
  pass "D2: release comparison rejects a mismatched probe status"
  expect_log "$D2/equality.log" "malformed fingerprint record in tg_stage3" \
    "D2: failure is attributed to the inconsistent probe_success record"
fi

# D3: digest tampered -> must fail.
D3="$TMP/fixture-digest"
copy_fixture "$D3"
awk '
  $1 == "FINGERPRINT" && $3 == "symbols" && !done {
    print "FINGERPRINT tg_stage3 symbols 0000000000000000000000000000000000000000000000000000000000000000 probe_success=true byte_count=1"
    done = 1
    next
  }
  { print }
' "$D3/.fingerprints/tg_stage3.fingerprints" >"$TMP/d3.fp" &&
  mv "$TMP/d3.fp" "$D3/.fingerprints/tg_stage3.fingerprints"
if run_equality "$D3" release; then
  bad "D3: release comparison accepted a digest mismatch"
else
  pass "D3: release comparison fails on a digest mismatch"
  expect_log "$D3/equality.log" "differs" \
    "D3: failure is attributed to the digest comparison"
fi

# ══════════════════════════════════════════════════════════════════════
# E. RECORD-LINE INVARIANTS (bh_phase_line refuses to forge records) and
#    bh_dump_hash never hashes a failed probe
# ══════════════════════════════════════════════════════════════════════
HEX64="$(sha256_str 'x')"
if ( source "$ROOT/scripts/bootstrap_helpers.sh"
     bh_phase_line tg_stage2 text "$HEX64" false 0 ) >/dev/null 2>&1; then
  bad "E: bh_phase_line accepted a digest on a failed probe"
else
  pass "E: bh_phase_line refuses a digest on a failed probe"
fi
if ( source "$ROOT/scripts/bootstrap_helpers.sh"
     bh_phase_line tg_stage2 text UNAVAILABLE true 0 ) >/dev/null 2>&1; then
  bad "E: bh_phase_line accepted UNAVAILABLE as a successful probe"
else
  pass "E: bh_phase_line refuses UNAVAILABLE as a successful probe"
fi
if ( source "$ROOT/scripts/bootstrap_helpers.sh"
     bh_phase_line tg_stage2 text UNAVAILABLE false 3 ) >/dev/null 2>&1; then
  pass "E: bh_phase_line accepts UNAVAILABLE probe_success=false byte_count=3"
else
  bad "E: bh_phase_line rejected a valid failure record"
fi
if ( source "$ROOT/scripts/bootstrap_helpers.sh"
     bh_phase_line tg_stage2 text "$HEX64" true notanumber ) >/dev/null 2>&1; then
  bad "E: bh_phase_line accepted a non-integer byte_count"
else
  pass "E: bh_phase_line rejects a non-integer byte_count"
fi
if bh_dump_hash_out="$(
  ( source "$ROOT/scripts/bootstrap_helpers.sh"
    bh_dump_hash "$TMP/stubs-ok/cc-fail" src.tg --dump-tokens ) 2>/dev/null
)"; then
  bad "E: bh_dump_hash produced a digest for a FAILED compile probe (out='$bh_dump_hash_out')"
else
  pass "E: bh_dump_hash emits no digest when the compile probe fails"
fi
if bh_dump_hash_out="$(
  ( source "$ROOT/scripts/bootstrap_helpers.sh"
    bh_dump_hash "$TMP/stubs-ok/cc-empty" src.tg --dump-tokens ) 2>/dev/null
)" && [ "$bh_dump_hash_out" = "$EMPTY_SHA" ]; then
  pass "E: bh_dump_hash keeps sha256(\"\") for a successful empty compile output"
else
  bad "E: bh_dump_hash did not return sha256(\"\") for a successful empty output"
fi

# ══════════════════════════════════════════════════════════════════════
if [ "$fail" -ne 0 ]; then
  echo "test_object_fingerprint_integrity: FAIL"
  exit 1
fi
echo "test_object_fingerprint_integrity: ALL PASS"
