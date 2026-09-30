#!/usr/bin/env bash
# test_prebootstrap_gates.sh — mutation-style regression tests for the
# pre-bootstrap gates themselves (audit: test the gates, not only the
# compiler).
#
# All fixtures are synthetic and live in a temp directory; the whole suite
# is sub-second.  Sections:
#   1. target-lane no-runner path: mocked UNAVAILABLE runner must not die
#      on an unbound variable and must print the disassembly-gate message
#      (the $host_arch regression).
#   2. strict image validation: ELF32 / wrong-endian / wrong-arch /
#      truncated / magic-only fixtures and Mach-O wrong-cputype must be
#      rejected; a correct-header fixture must be accepted for the target.
#   3. unit-test evidence rule: a missing, duplicated or wrong-count
#      summary line must be rejected.
#
# Usage: scripts/test_prebootstrap_gates.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "prebootstrap-gates: PASS - $*"; }
bad() {
  echo "prebootstrap-gates: FAIL - $*" >&2
  fail=1
}

# ── 1. target lane with an UNAVAILABLE runner ─────────────────────────
mkdir -p "$TMP/lane/tests/canary"
printf 'canary_dummy.tg\n' >"$TMP/lane/tests/canary/MANIFEST"
cat >"$TMP/lane/fakecc" <<'FAKECC'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o)
      out="$2"
      shift
      ;;
  esac
  shift
done
[ -n "$out" ] || exit 3
printf 'fake-binary' >"$out"
FAKECC
chmod +x "$TMP/lane/fakecc"

lane_rc=0
(
  cd "$TMP/lane"
  # shellcheck disable=SC1091
  source "$ROOT/scripts/bootstrap_helpers.sh"
  bh_require_canary_suites() { return 0; }
  bh_target_runner_for() { printf 'UNAVAILABLE'; }
  bh_assert_no_trap_stubs() { return 0; }
  bh_boot_target() { printf 'aarch64-apple-darwin'; }
  run_target_lane_canaries "$TMP/lane/fakecc" "$TMP/lane/out" "aarch64-apple-darwin"
) >"$TMP/lane/out.txt" 2>&1 || lane_rc=$?

if [ "$lane_rc" -ne 0 ]; then
  bad "no-runner target lane exited $lane_rc (see $TMP/lane/out.txt)"
elif grep -q "unbound variable" "$TMP/lane/out.txt"; then
  bad "no-runner target lane hit an unbound variable"
elif ! grep -q "disassembly/trap-stub gate only" "$TMP/lane/out.txt"; then
  bad "no-runner target lane did not print the disassembly-gate message"
else
  pass "no-runner target lane survives with the disassembly-gate message"
fi

# ── 2. strict image validation fixtures ──────────────────────────────
# Helper: write a little-endian ELF header prefix with the checked fields
# set (e_ident magic/class/data/version + 9 pad, e_type, e_machine) and a
# zero tail.
emit_byte() { printf '%b' "\\x$(printf '%02x' "$1")"; }

mk_elf() { # <path> <class> <data> <etype> <machine>
  local path="$1" cls="$2" data="$3" etype="$4" machine="$5"
  {
    printf '\x7fELF'
    emit_byte "$cls"
    emit_byte "$data"
    emit_byte 1
    head -c 9 /dev/zero
    emit_byte $((etype & 0xff))
    emit_byte $(((etype >> 8) & 0xff))
    emit_byte $((machine & 0xff))
    emit_byte $(((machine >> 8) & 0xff))
    head -c 200 /dev/zero
  } >"$path"
}

elf_x86="$TMP/elf_x86_64"
mk_elf "$elf_x86" 2 1 2 62 # class64, LE, ET_EXEC, EM_X86_64
elf32="$TMP/elf32"
mk_elf "$elf32" 1 1 2 62
elf_be="$TMP/elf_be"
mk_elf "$elf_be" 2 2 2 62
elf_arm="$TMP/elf_arm"
mk_elf "$elf_arm" 2 1 2 183
elf_magic_only="$TMP/elf_magic_only"
printf '\x7fELF' >"$elf_magic_only"
elf_trunc="$TMP/elf_trunc"
printf '\x7fELF\x02\x01' >"$elf_trunc"

check_img() { # <expected-rc> <file> <triple> <label>
  local want="$1" file="$2" triple="$3" label="$4" rc=0
  (
    # shellcheck disable=SC1091
    source "$ROOT/scripts/bootstrap_helpers.sh"
    bh_boot_target() { printf '%s' "$triple"; }
    bh_is_elf64 "$file"
  ) >/dev/null 2>&1 || rc=$?
  if [ "$want" = "accept" ] && [ "$rc" -ne 0 ]; then
    bad "image ${label}: expected accept, rejected"
  elif [ "$want" = "reject" ] && [ "$rc" -eq 0 ]; then
    bad "image ${label}: expected reject, accepted"
  else
    pass "image ${label}: ${want}"
  fi
}

check_img accept "$elf_x86" "x86_64-unknown-linux-gnu" "ELF64 x86-64 fixture"
check_img reject "$elf_x86" "aarch64-unknown-linux-gnu" "ELF64 x86-64 under arm64 target"
check_img reject "$elf32" "x86_64-unknown-linux-gnu" "ELF32 despite ELF magic"
check_img reject "$elf_be" "x86_64-unknown-linux-gnu" "big-endian ELF64"
check_img reject "$elf_arm" "x86_64-unknown-linux-gnu" "ELF64 arm64 under x86-64 target"
check_img reject "$elf_magic_only" "x86_64-unknown-linux-gnu" "magic-only file"
check_img reject "$elf_trunc" "x86_64-unknown-linux-gnu" "truncated ELF header"

macho_x86="$TMP/macho_x86"
printf '\xcf\xfa\xed\xfe\x07\x00\x00\x01' >"$macho_x86"
macho_arm="$TMP/macho_arm"
printf '\xcf\xfa\xed\xfe\x0c\x00\x00\x01' >"$macho_arm"

check_macho() { # <expected-rc> <file> <triple> <label>
  local want="$1" file="$2" triple="$3" label="$4" rc=0
  (
    # shellcheck disable=SC1091
    source "$ROOT/scripts/bootstrap_helpers.sh"
    bh_boot_target() { printf '%s' "$triple"; }
    bh_is_macho64 "$file"
  ) >/dev/null 2>&1 || rc=$?
  if [ "$want" = "accept" ] && [ "$rc" -ne 0 ]; then
    bad "image ${label}: expected accept, rejected"
  elif [ "$want" = "reject" ] && [ "$rc" -eq 0 ]; then
    bad "image ${label}: expected reject, accepted"
  else
    pass "image ${label}: ${want}"
  fi
}

check_macho accept "$macho_arm" "aarch64-apple-darwin" "Mach-O arm64 fixture"
check_macho reject "$macho_x86" "aarch64-apple-darwin" "Mach-O x86-64 under arm64 target"
check_macho accept "$macho_x86" "x86_64-apple-darwin" "Mach-O x86-64 fixture"

# ── 3. unit-test evidence rule ───────────────────────────────────────
evidence_ok="$TMP/evidence_ok.txt"
printf '230 passed, 0 failed\n' >"$evidence_ok"
if ! "$ROOT/scripts/check_unit_test_evidence.sh" "$evidence_ok" 230; then
  bad "unit evidence: exact single summary rejected"
else
  pass "unit evidence: exact single summary accepted"
fi
for case_spec in "missing:garbage" "duplicate:230 passed, 0 failed\n230 passed, 0 failed" "wrong:231 passed, 0 failed"; do
  label="${case_spec%%:*}"
  content="${case_spec#*:}"
  printf '%b\n' "$content" >"$TMP/evidence_bad.txt"
  if "$ROOT/scripts/check_unit_test_evidence.sh" "$TMP/evidence_bad.txt" 230 >/dev/null 2>&1; then
    bad "unit evidence: ${label} summary accepted"
  else
    pass "unit evidence: ${label} summary rejected"
  fi
done

# ── 4. static allocator-policy invariant ─────────────────────────────
# The x86-64 allocatable set is CALLEE-SAVED ONLY (RBX, R12-R15) and must
# never contain the return register, the implicit lowering scratch R10,
# the designated scratch R11, or any other caller-saved register.  A
# regression here is a silent miscompile class, so pin it structurally.
alloc_block="$(sed -n '/^def x64_allocatable_regs/,/^end/p' "$ROOT/tg_compiler/codegen.tg")"
want_regs="RBX R12 R13 R14 R15"
got_regs="$(printf '%s\n' "$alloc_block" | grep -oE 'X64::R[A-Z0-9]+' | sed 's/X64:://' | tr '\n' ' ' | sed 's/ *$//')"
if [ "$got_regs" != "$want_regs" ]; then
  bad "allocator policy: x64_allocatable_regs = '${got_regs}', expected exactly '${want_regs}'"
else
  pass "allocator policy: x64 allocatable = callee-saved only (${want_regs})"
fi
if printf '%s\n' "$alloc_block" | grep -qE 'X64::(R10|R11|RAX|RCX|RDX|RSI|RDI|R8|R9)'; then
  bad "allocator policy: a caller-saved/scratch register appears in x64_allocatable_regs"
else
  pass "allocator policy: no caller-saved/scratch register allocatable"
fi

# ── 5. trap-scanner grammar (no binary required) ─────────────────────
# Feed synthetic otool- and objdump-style disassemblies into
# bh_scan_traps and pin allowed/banned classification, including local
# `.L`-label attribution and the whitelisted abort machinery.
scan() { # <arch> <disassembly> -> "allowed banned"
  (
    # shellcheck disable=SC1091
    source "$ROOT/scripts/bootstrap_helpers.sh"
    bh_scan_traps "$2" "$1"
  )
}
check_scan() { # <label> <arch> <dis> <want-allowed> <want-banned>
  local label="$1" arch="$2" dis="$3" wa="$4" wb="$5"
  local got
  got="$(scan "$arch" "$dis")"
  if [ "$got" != "$wa $wb" ]; then
    bad "trap-scan ${label}: got '${got}', want '${wa} ${wb}'"
  else
    pass "trap-scan ${label}: allowed=${wa} banned=${wb}"
  fi
}

check_scan "otool-x86 banned" "x86_64" "$(printf 'add:\n\tud2\n\tret')" 0 1
check_scan "otool-x86 whitelisted" "x86_64" "$(printf 'panic:\n\tud2\n\tret')" 1 0
check_scan "otool-x86 local-label attribution" "x86_64" "$(printf 'add:\n_.Ltmp1:\n\tud2')" 0 1
check_scan "objdump-x86 banned" "x86_64" "$(printf '0000000000401000 <add>:\n  401000:\t0f 0b\tud2\n  401002:\tc3\tret')" 0 1
check_scan "objdump-x86 whitelisted" "x86_64" "$(printf '0000000000401000 <panic>:\n  401000:\t0f 0b\tud2')" 1 0
check_scan "otool-arm64 banned" "arm64" "$(printf 'add:\n\tbrk #0x1\n\tret')" 0 1
check_scan "otool-arm64 whitelisted" "arm64" "$(printf 'panic:\n\tbrk #0x1\n\tret')" 1 0
check_scan "otool-arm64 vec sanity trap" "arm64" "$(printf 'add:\n\tbrk #0xbeef')" 1 0
check_scan "objdump-arm64 banned" "arm64" "$(printf '0000000000401000 <add>:\n  401000:\td4200001\tbrk #0x1')" 0 1

# ── 6. parity manifest cannot drift from the kernel closure ──────────
# bootstrap/resolution_parity_mini.manifest must be EXACTLY the kernel
# manifest plus the probe entry; a drifted copy would silently validate a
# different closure.
kernel_entries="$(grep -E '^(std|compiler):' "$ROOT/bootstrap/compiler_kernel.manifest" | sort)"
parity_entries="$(grep -E '^(std|compiler):' "$ROOT/bootstrap/resolution_parity_mini.manifest" |
  grep -v 'resolution_parity_probe.tg' | sort)"
if [ "$kernel_entries" != "$parity_entries" ]; then
  bad "parity manifest drift: resolution_parity_mini.manifest != compiler_kernel.manifest + probe"
else
  pass "parity manifest = kernel closure + probe (no drift)"
fi
if ! grep -q '^compiler: resolution_parity_probe.tg$' "$ROOT/bootstrap/resolution_parity_mini.manifest"; then
  bad "parity manifest: probe entry missing"
else
  pass "parity manifest: probe entry present"
fi

# ── 7. contract provenance pins (audit follow-up) ────────────────────
# Each pin names the source line that implements a proof-integrity
# contract, so a future refactor that drops the contract goes red even if
# no lane happens to run.
check_pin() { # <label> <file> <regex>
  local label="$1" file="$2" pattern="$3"
  if grep -qE -- "$pattern" "$ROOT/$file"; then
    pass "contract pin: ${label}"
  else
    bad "contract pin missing: ${label} (${file}: /${pattern}/)"
  fi
}
check_pin "proof root requires the repository entry" tg_compiler/compiler_core.tg   'error: --bootstrap-proof requires the repository kernel entry root'
check_pin "proof root rejects absolute lookalikes" tg_compiler/compiler_core.tg   'pub def bootstrap_proof_root_ok'
check_pin "digest is bound to the consumed root bytes" tg_compiler/compiler_core.tg   'tg_is_root_entry\(root_path.clone\(\), rel.clone\(\)\)'
check_pin "linkprobe never SKIPs the closure digest" stage0_ocaml/selfcheck/linkprobe.tg   'no seed fingerprint supplied'
if grep -q 'LINKPROBE_CLOSURE_DIGEST=SKIP' "$ROOT/stage0_ocaml/selfcheck/linkprobe.tg"; then
  bad "contract pin: linkprobe still has a digest SKIP path"
else
  pass "contract pin: no digest SKIP path"
fi
check_pin "linkprobe manifest load fails closed" stage0_ocaml/selfcheck/tg_linkprobe.ml   'cannot load compiler kernel manifest'
check_pin "linkprobe is target/format aware" stage0_ocaml/selfcheck/tg_linkprobe.ml   'target_is_linux'
check_pin "parity harness inherits the bootstrap target" stage0_ocaml/selfcheck/tg_resolution_parity.ml   'resolved_target_str'
check_pin "parity evidence names the requested target" stage0_ocaml/selfcheck/tg_resolution_parity.ml   'does not name the requested target'
check_pin "seed identity cannot be faked as unreadable" stage0_ocaml/src/driver.ml   'vpc_seed_identity : string option'
check_pin "kernel parses --codegen=direct" tg_compiler/bootstrap_main.tg   '--codegen=lir requires the full driver'
check_pin "direct allocator canary has route evidence" scripts/bootstrap_helpers.sh   'X64_ALLOCATOR_CANARY route=direct'

# The mixed-architecture "tolerant" allowlist is now EMPTY: every
# architecture-impossible register combination must fail closed.
if [ "$(grep -c '# tolerant' "$ROOT/tg_compiler/codegen.tg" || true)" = "0" ]; then
  pass "mixed-architecture tolerant allowlist is empty"
else
  bad "mixed-architecture # tolerant branches remain in tg_compiler/codegen.tg"
fi

if [ "$fail" -ne 0 ]; then
  echo "test_prebootstrap_gates: FAIL"
  exit 1
fi
echo "test_prebootstrap_gates: ALL PASS"
exit 0
