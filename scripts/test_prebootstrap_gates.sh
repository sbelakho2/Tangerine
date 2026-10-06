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
check_pin "digest is bound to the consumed root bytes" tg_compiler/compiler_core.tg   'tg_is_root_entry\(root_path.clone\(\), snap.sources\[i\].rel.clone\(\)\)'
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
check_pin "gate rejects closure mutation during the run" stage0_ocaml/selfcheck/tg_bootstrap_gate.ml \
  'closure changed while the gate ran'
check_pin "selfcheck rejects closure mutation during the run" stage0_ocaml/selfcheck/tg_bootstrap_selfcheck.ml \
  'closure changed while the preflight ran'
check_pin "seed identity cannot be faked as unreadable" stage0_ocaml/src/driver.ml   'vpc_seed_identity : string option'
check_pin "kernel parses --codegen=direct" tg_compiler/bootstrap_main.tg   '--codegen=lir requires the full driver'
check_pin "direct allocator canary has route evidence" scripts/bootstrap_helpers.sh   'X64_ALLOCATOR_CANARY route=direct'

# ── closure-snapshot authority (audit P0/P1) ─────────────────────────
# The proof digest and the dependency parser must consume the SAME loaded
# snapshot: the fingerprint composer contains no file read, the summary
# takes the compilation's precomputed digest, and the loader reads only
# through the snapshot lookup.
if sed -n '/^pub def emit_check_ok_summary/,/^end$/p' "$ROOT/tg_compiler/compiler_core.tg" | grep -q 'bootstrap_closure_fingerprint'; then
  bad "closure snapshot: summary recomputes the digest from a fresh read"
else
  pass "closure snapshot: summary consumes the compilation's digest"
fi
snap_fp_body="$(sed -n '/^pub def bootstrap_closure_fingerprint_snapshot/,/^end$/p' "$ROOT/tg_compiler/compiler_core.tg")"
if [ -z "$snap_fp_body" ]; then
  bad "closure snapshot: fingerprint-from-snapshot function missing"
elif printf '%s\n' "$snap_fp_body" | grep -q 'read_source_file'; then
  bad "closure snapshot: fingerprint re-reads a source file"
else
  pass "closure snapshot: fingerprint hashes the loaded snapshot (no re-read)"
fi
check_pin "closure snapshot: dep loader consumes the snapshot" tg_compiler/compiler_core.tg   'bootstrap_closure_snapshot_lookup\(snap, path.clone\(\)\)'
check_pin "closure snapshot: mutation probe exists" stage0_ocaml/selfcheck/linkprobe.tg   'bootstrap_closure_snapshot_at'

# (P0 closure authority): a manifest-closed walk REQUIRES the one snapshot.
# No fallback may re-read the manifest or the per-file sources.
merge_body="$(sed -n '/^def merge_imported_deps_snapshot/,/^end$/p' "$ROOT/tg_compiler/compiler_core.tg")"
if printf '%s\n' "$merge_body" | grep -q 'bootstrap_manifest_sources'; then
  bad "manifest-closed merge still reads bootstrap_manifest_sources() (legacy fallback)"
else
  pass "manifest-closed merge has no manifest re-read fallback"
fi
check_pin "manifest-closed snapshot is mandatory" tg_compiler/compiler_core.tg   'bootstrap_require_closure_snapshot'
check_pin "snapshot fail-closed probe exists" stage0_ocaml/selfcheck/linkprobe.tg   'bootstrap_require_closure_snapshot'
check_pin "snapshot loader pins the closure cardinality" tg_compiler/compiler_core.tg   'bootstrap_kernel_closure_files'
check_pin "snapshot path choice is snapshot-authoritative" tg_compiler/compiler_core.tg   'bootstrap_dep_choose'

# (P0 closure GRAPH): dependency PATH CHOICE must not probe the live
# filesystem in a manifest-closed walk.
dep_body="$(sed -n '/^def dep_use_to_file_snapshot/,/^end$/p' "$ROOT/tg_compiler/compiler_core.tg")"
if printf '%s\n' "$dep_body" | grep -q 'file_exists'; then
  bad "snapshot dependency resolution still probes the live filesystem"
else
  pass "snapshot dependency resolution uses snapshot membership only"
fi
items_body="$(sed -n '/^def collect_dep_items_snapshot/,/^end$/p' "$ROOT/tg_compiler/compiler_core.tg")"
if printf '%s\n' "$items_body" | grep -q 'file_exists'; then
  bad "snapshot dependency walk still probes the live filesystem"
else
  pass "snapshot dependency walk performs no filesystem existence query"
fi

# (P0/P1 sysops): no-follow final-component resolution and virtual-absolute
# namespace are wired through the raw syscall layer.
check_pin "no-follow final-component resolver exists" stage0_ocaml/src/host.ml   'host_real_path_no_follow'
check_pin "unlink is a no-follow entry operation" stage0_ocaml/src/host.ml   'host_unlink t path)'
check_pin "rmdir is a no-follow entry operation" stage0_ocaml/src/host.ml   'host_rmdir t path)'
check_pin "rename is a no-follow entry operation" stage0_ocaml/src/host.ml   'host_rename t from_ to_)'
check_pin "readlink does not follow the final link" stage0_ocaml/src/host.ml   'host_readlink t path'
check_pin "virtual-absolute resolution exists" stage0_ocaml/src/host_fs.ml   'resolve_parent_abs'
check_pin "absolute chdir resolves from the virtual root" stage0_ocaml/src/host.ml   'resolve_existing_abs t.fs segs'
check_pin "RSS parser reads VmRSS kB" stage0_ocaml/src/vm.ml   'vmrss_kb_of_status_line'
for _utv in F32 F64 StaticStrPtr; do
  check_pin "unify covers Type::${_utv}" tg_compiler/types.tg "when Type::${_utv} then"
done
check_pin "snapshot structural-reject probe exists" stage0_ocaml/selfcheck/linkprobe.tg   'linkprobe_expect_snapshot_reject'

# ── P0 host-device capability authority ──────────────────────────────
# /dev/* facilities are OPEN/STAT/LSTAT/READLINK capabilities only.
# Every mutating resolver call site must use the non-dev default; a
# mutation that opts a mutating op into host-device authority goes red
# here even if no lane happens to execute that path.
dev_authority_ok() { # <host.ml path>
  local f="$1" ok=1 op body
  if ! grep -qF 'let host_real_path ?(allow_dev = false)' "$f"; then ok=0; fi
  if ! grep -qF 'let host_real_path_no_follow ?(allow_dev = false)' "$f"; then ok=0; fi
  for op in host_unlink host_rmdir host_mkdir host_symlink host_rename host_chmod; do
    body="$(sed -n "/^let ${op} /,/^let [a-z_]* /p" "$f")"
    if printf '%s\n' "$body" | grep -q 'allow_dev'; then ok=0; fi
  done
  local calls
  calls="$(grep -cE 'host_real_path(_no_follow)? ~allow_dev:true' "$f" || true)"
  [ "$calls" = 4 ] || ok=0
  [ "$ok" = 1 ]
}
if dev_authority_ok "$ROOT/stage0_ocaml/src/host.ml"; then
  pass "host-device authority is open-only (defaults refuse; 4 opt-in call sites; no mutating op opts in)"
else
  bad "host-device authority leaked into a mutating resolver path"
fi
# Mutation self-tests: the check must go red both when a mutating op opts
# in and when a resolver default is flipped to allow.
dev_mut="$TMP/host_dev_mut.ml"
cp "$ROOT/stage0_ocaml/src/host.ml" "$dev_mut"
sed 's/match host_real_path_no_follow t path with/match host_real_path_no_follow ~allow_dev:true t path with/' \
  "$dev_mut" >"$dev_mut.new" && mv "$dev_mut.new" "$dev_mut"
if dev_authority_ok "$dev_mut"; then
  bad "host-device mutation accepted: unlink/rmdir/mkdir opted into allow_dev"
else
  pass "host-device mutation rejected: a mutating op opted into allow_dev"
fi
cp "$ROOT/stage0_ocaml/src/host.ml" "$dev_mut"
sed 's/?(allow_dev = false)/?(allow_dev = true)/' "$dev_mut" >"$dev_mut.new" && mv "$dev_mut.new" "$dev_mut"
if dev_authority_ok "$dev_mut"; then
  bad "host-device mutation accepted: resolver default flipped to allow_dev"
else
  pass "host-device mutation rejected: resolver default flipped to allow_dev"
fi
# True NoFollowFinal: the final component is never realpath'd, so
# dangling and escaping symlinks can be lstat'd, readlink'd, renamed and
# unlinked as the directory entries they are.
nf_body="$(sed -n '/^let host_real_path_no_follow/,/^let host_open /p' "$ROOT/stage0_ocaml/src/host.ml")"
if printf '%s\n' "$nf_body" | grep -q 'Unix.realpath'; then
  bad "no-follow resolution still realpaths a final component"
else
  pass "no-follow resolution never realpaths the final component"
fi
check_pin "absolute symlink targets are virtualized at creation" stage0_ocaml/src/host.ml   'virtual_abs_physical'
check_pin "readlink re-spells targets into the guest namespace" stage0_ocaml/src/host.ml   'virtual_abs_guest'

# ── P0 generic Map/Set Clone contract ────────────────────────────────
# The O(1) pure-data clone fast path is REMOVED: no intrinsic may
# reappear and the generic clone must walk every element through its own
# Clone impl (tests/unit/test_collections_clone_semantics.tg is the
# behavioral proof; these pins keep the implementation surface).
if grep -qE '__intrinsic_(map|set)_clone_try' \
  "$ROOT/std/collections.tg" \
  "$ROOT/stage0_ocaml/src/host.ml" \
  "$ROOT/stage0_ocaml/src/intrinsic_registry.ml"; then
  bad "the removed Map/Set clone-try intrinsic is referenced again"
else
  pass "the generic Map/Set clone does not use the runtime pure-data fast path"
fi
check_pin "Map::clone clones every key and value exactly once" std/collections.tg   'result.insert\(key_ref.clone\(\), val_ref.clone\(\)\)'
check_pin "Set::clone clones every element exactly once" std/collections.tg   'result.insert\(item_ref.clone\(\)\)'
# The compiler-internal persistent-map snapshot (option-3 Clone
# performance recovery) MUST stay confined to the audited internal
# carrier: ResolvedNames/StableIdMap clone through it, the PUBLIC
# generic Map/Set clone surface never references it.
check_pin "ResolvedNames clones through the compiler-internal snapshot" tg_compiler/resolver.tg   '__intrinsic_map_clone\(self\.expr_resolutions\)'
check_pin "the snapshot intrinsic is declared compiler-internally" tg_compiler/resolver.tg   'extern def __intrinsic_map_clone'
if grep -q '__intrinsic_map_clone' "$ROOT/std/collections.tg"; then
  bad "the public generic Map/Set clone surface references the internal snapshot"
else
  pass "the internal snapshot is not reachable from the public generic Clone surface"
fi
# The host binding must fail closed on a resource-bearing store.
check_pin "the snapshot refuses owned-region stores" stage0_ocaml/src/vm_value.ml   'map snapshot: the store carries an owned region ref'
# The obligation candidate index (trait + head) and its compiler-private
# enforcement, plus the discriminating Clone test.
check_pin "the obligation solver consumes the candidate index" tg_compiler/types.tg   'impl_candidate_indices\(env, obligation\.trait_ref\.trait_id\.id'
check_pin "the candidate index is maintained at registration" tg_compiler/types.tg   'register_impl_candidate_index\(env, registered_idx'
check_pin "the kernel gates compiler-private intrinsics" tg_compiler/types.tg   'compiler-private intrinsic gate'
check_pin "the registry declares the compiler-private name list" stage0_ocaml/src/intrinsic_registry.ml   'compiler_private_names'
check_pin "the seed gates private intrinsics on compile origin" stage0_ocaml/src/typecheck.ml   'trusted_compiler_origin'
check_pin "the closure manifest establishes the trusted origin" stage0_ocaml/src/driver.ml   'trusted_compiler_origin'
check_pin "the seed rejects compiler-private extern declarations" stage0_ocaml/src/typecheck.ml   'is a compiler-internal intrinsic and may only be declared'
check_pin "the seed skips compiler-private names at call classification" stage0_ocaml/src/typecheck.ml   'is_compiler_private_name n'
check_pin "the kernel origin requires the bootstrap-proof kernel-entry root" tg_compiler/compiler_core.tg   'env.trusted_compiler_origin = opts.emit_check_summary && bootstrap_proof_root_ok'
check_pin "the kernel rejects private declarations by provenance" tg_compiler/types.tg   'compiler-private declaration gate'
check_pin "the kernel records struct field defaults" tg_compiler/types.tg   'typed_field_defaults'
check_pin "the kernel enforces required fields (E0203)" tg_compiler/types.tg   'missing required field'
check_pin "the MIR aggregate fill materializes defaults" tg_compiler/mir.tg   'field_defaults'
# bare-name collision tripwire: the seed's nominal/flat tables are
# bare-keyed, so a NEW duplicate nominal is a latent identity hazard (the
# EnumLayout incident).  The pinned set is the closure's known five; the
# collision-parity corpus tracks fixing them properly.
closure_collisions="$(python3 "$ROOT/scripts/closure_bare_name_collisions.py" 2>/dev/null)"
if [ "$closure_collisions" = "AbiReturn Arch Error ErrorCode Span" ]; then
  pass "closure bare-name collisions are the pinned known set (no new identity hazard)"
else
  bad "closure bare-name collisions changed: '${closure_collisions}' (pin: 'AbiReturn Arch Error ErrorCode Span')"
fi
check_pin "the final gate installs the RSS ceiling unconditionally" scripts/check_ocaml_bootstrap_complete.sh   'TANGERINE_BOOTSTRAP_VM_MAX_RSS_MB=12288'
check_pin "the authorization gate accepts no RSS override" scripts/check_ocaml_bootstrap_complete.sh   'accepts NO resource-budget override'
check_pin "authorization pins the VM step budget" scripts/check_ocaml_bootstrap_complete.sh   'TANGERINE_BOOTSTRAP_VM_MAX_STEPS=30000000000'
check_pin "authorization pins the VM host-call budget" scripts/check_ocaml_bootstrap_complete.sh   'TANGERINE_BOOTSTRAP_VM_MAX_HOST_CALLS=1000000000'
check_pin "authorization pins the VM alloc budget" scripts/check_ocaml_bootstrap_complete.sh   'TANGERINE_BOOTSTRAP_VM_MAX_ALLOC=8589934592'
check_pin "authorization pins the outer gate timeout" scripts/check_ocaml_bootstrap_complete.sh   'GATE_TIMEOUT_S=4140'
check_pin "the profile entry point is explicitly non-authorizing" scripts/profile_ocaml_bootstrap.sh   'NON-AUTHORIZING'
if grep -q 'BOOTSTRAP COMPLETE: PASS' "$ROOT/scripts/profile_ocaml_bootstrap.sh"; then
  bad "the profile entry point can emit an authorization sentinel"
else
  pass "the profile entry point cannot emit an authorization sentinel"
fi
check_pin "authorization refuses unbounded hosts (no escape)" scripts/check_ocaml_bootstrap_complete.sh   'unbounded authorization path'
check_pin "the env gate rejects unbounded final runs" scripts/prebootstrap_env_gate.sh   'TG_ALLOW_UNBOUNDED_FINAL'
check_pin "RSS measurement is declared Linux-only" stage0_ocaml/src/vm.ml   'Measurement is Linux-only'
check_pin "the Clone value test is discriminating (0/1/2 clones)" tests/unit/test_collections_clone_semantics.tg   'assert_eq\(v.value, 2\)'
check_pin "the Clone test covers custom KEY Clone" tests/unit/test_collections_clone_semantics.tg   'test_map_clone_invokes_each_key_clone_exactly_once'


# (P1 containment): the raw host path resolver must never fall back to an
# unchecked lexical repo-root join after Host_fs refused the path.  The
# check is scoped to the resolver body: virtual_abs_physical DOES perform
# the intentional lexical mapping of absolute guest symlink targets (its
# ".."-rejecting hygiene is proven behaviorally by tg_hostfs).
hrp_body="$(sed -n '/^let host_real_path /,/^let host_real_path_no_follow /p' "$ROOT/stage0_ocaml/src/host.ml")"
if printf '%s\n' "$hrp_body" | grep -q 'Filename.concat'; then
  bad "host_real_path still falls back to a lexical path after resolver refusal"
else
  pass "raw host path resolution is fail-closed (no lexical fallback)"
fi
check_pin "raw host path refusal maps to errno" stage0_ocaml/src/host.ml   'Error errno_acces'
check_pin "profiling runs can bound RSS" stage0_ocaml/src/vm.ml   'max_rss_bytes'
check_pin "VM beacon reports live region/capture telemetry" stage0_ocaml/src/vm.ml   'reg_live='
check_pin "linkprobe deletes stale outputs before the run" stage0_ocaml/selfcheck/tg_linkprobe.ml   'remove_if_exists'
check_pin "linkprobe validates this run's nonce" stage0_ocaml/selfcheck/tg_linkprobe.ml   'linkprobe_nonce.txt'

# Execution wording: the unavailable branch must never claim a run, and the
# performed branch must never claim structural-only.
if grep -n 'execution=unavailable structural-proof=pass' "$ROOT/stage0_ocaml/selfcheck/tg_linkprobe.ml" | grep -qE 'exit=42|performed'; then
  bad "linkprobe unavailable branch claims execution"
else
  pass "linkprobe unavailable branch never claims execution"
fi
if grep -n 'execution=performed exit=42' "$ROOT/stage0_ocaml/selfcheck/tg_linkprobe.ml" | grep -q 'unavailable'; then
  bad "linkprobe performed branch claims unavailability"
else
  pass "linkprobe performed branch names the real execution"
fi

# Direct-route allocator evidence must be counted in the lane totals.
alloc_block="$(sed -n '/DIRECT-emitter allocator canary/,/^  fi$/p' "$ROOT/scripts/bootstrap_helpers.sh")"
if printf '%s\n' "$alloc_block" | grep -q 'total=\$((total + 1))'; then
  pass "direct allocator canary increments the lane total"
else
  bad "direct allocator canary is not counted in the lane total"
fi

# The timeout facility is the single authority; no lane may call the bare
# `timeout` binary directly (portability: stock macOS has only gtimeout).
if grep -nE '(^|[;&|(])[[:space:]]*timeout[[:space:]]' \
  "$ROOT/scripts/prebootstrap_quick.sh" \
  "$ROOT/scripts/check_ocaml_seed_health.sh" \
  "$ROOT/scripts/check_ocaml_bootstrap_complete.sh" 2>/dev/null | grep -q .; then
  bad "a lane calls timeout directly instead of bh_run_with_timeout"
else
  pass "all lanes use the portable timeout facility"
fi

# ── the mixed-architecture fail-closed validator + mutations ─────────
# The validator checks behavior-bearing shapes case-insensitively; these
# mutations prove it goes red for every injection class.
if "$ROOT/scripts/check_codegen_arch_invariants.sh" >/dev/null 2>&1; then
  pass "codegen architecture invariants (clean tree)"
else
  bad "codegen architecture invariants fail on the clean tree"
fi
mut_base="$TMP/codegen_mut.tg"

# Portable in-place edit: GNU sed wants `-i EXPR FILE`, BSD/macOS sed wants
# `-i SUFFIX EXPR FILE`.  A redirected rewrite + mv works on both, so the
# gate itself is not the thing that fails on a stock Darwin host.
apply_sed_mutation() { # <file> <sed-expression>
  local file="$1" expr="$2" tmp
  tmp="${file}.mut.new"
  sed "$expr" "$file" >"$tmp"
  mv "$tmp" "$file"
}

run_arch_mutation() { # <label> <sed-expression>
  local label="$1" expr="$2"
  cp "$ROOT/tg_compiler/codegen.tg" "$mut_base"
  apply_sed_mutation "$mut_base" "$expr"
  if "$ROOT/scripts/check_codegen_arch_invariants.sh" "$mut_base" >/dev/null 2>&1; then
    bad "arch mutation accepted: ${label}"
  else
    pass "arch mutation rejected: ${label}"
  fi
}
run_arch_mutation "uppercase # Tolerance comment" \
  's/# MOV reg, reg/# Tolerance: PhysReg variant mismatch/'
run_arch_mutation "permissive phys_reg_as_a64 helper" \
  's/^def emit_mov_ri/def phys_reg_as_a64(r: PhysReg) -> A64\n  match r\n  when PhysReg::A64Reg(a) then a\n  when PhysReg::X64Reg(_) then A64::X0\n  end\nend\n\ndef emit_mov_ri/'
run_arch_mutation "permissive phys_reg_as_x64 helper" \
  's/^def emit_mov_ri/def phys_reg_as_x64(r: PhysReg) -> X64\n  match r\n  when PhysReg::X64Reg(a) then a\n  when PhysReg::A64Reg(_) then X64::RAX\n  end\nend\n\ndef emit_mov_ri/'
run_arch_mutation "silent mixed-architecture mov arm" \
  's/panic("codegen ICE: mixed-architecture registers in emit_mov_rr")/()/g'
run_arch_mutation "silent architecture-mismatch mov arm" \
  's/when PhysReg::A64Reg(_) then panic("codegen ICE: mixed-architecture registers in emit_mov_rr")/when PhysReg::A64Reg(_) then ()/'
run_arch_mutation "silent architecture-mismatch load arm" \
  's/when PhysReg::A64Reg(_) then panic("codegen ICE: mixed-architecture registers in emit_load_mem")/when PhysReg::A64Reg(_) then ()/'
run_arch_mutation "silent architecture-mismatch store arm" \
  's/when PhysReg::A64Reg(_) then panic("codegen ICE: mixed-architecture registers in emit_store_mem")/when PhysReg::A64Reg(_) then ()/'
run_arch_mutation "missing load ICE" \
  's/panic("codegen ICE: mixed-architecture registers in emit_load_mem")/()/g'

# ── qemu capability must be EXECUTION-based, not presence-based ──────
# A qemu-<arch> that exists but cannot run the minimal target ELF must not
# be selected; one that does run it must be (and the aarch64 binary name is
# qemu-aarch64, never qemu-arm64).
qemu_mock="$TMP/qemu-mock"
mkdir -p "$qemu_mock"
cat >"$qemu_mock/qemu-x86_64" <<'MOCK_FAIL'
#!/usr/bin/env bash
exit 1
MOCK_FAIL
chmod +x "$qemu_mock/qemu-x86_64"
if PATH="$qemu_mock:$PATH" bash -c 'source "$1"; bh_qemu_can_execute x86_64' _ "$ROOT/scripts/bootstrap_helpers.sh"; then
  bad "qemu capability probe accepted a qemu that cannot run the target ELF"
else
  pass "qemu capability probe rejects a present-but-broken qemu"
fi

cat >"$qemu_mock/qemu-x86_64" <<'MOCK_OK'
#!/usr/bin/env bash
# Emulates a working qemu deterministically on every host: the capability
# probe only needs "the resolved binary ran the probe and exited 0".
exit 0
MOCK_OK
chmod +x "$qemu_mock/qemu-x86_64"
if PATH="$qemu_mock:$PATH" bash -c 'source "$1"; bh_qemu_can_execute x86_64' _ "$ROOT/scripts/bootstrap_helpers.sh"; then
  pass "qemu capability probe accepts a qemu that runs the target ELF"
else
  bad "qemu capability probe rejected a working qemu"
fi

cat >"$qemu_mock/qemu-aarch64" <<'MOCK_ARM'
#!/usr/bin/env bash
[ "$(basename "$0")" = "qemu-aarch64" ] || exit 7
exit 0
MOCK_ARM
chmod +x "$qemu_mock/qemu-aarch64"
arm_runner="$(PATH="$qemu_mock:$PATH" bash -c 'source "$1"; bh_qemu_runner_for aarch64' _ "$ROOT/scripts/bootstrap_helpers.sh" || true)"
if [ "$arm_runner" = "qemu-aarch64" ]; then
  pass "aarch64 runner resolves to qemu-aarch64 (not qemu-arm64)"
else
  bad "aarch64 runner resolved to '$arm_runner', want qemu-aarch64"
fi

# The AArch64 probe must encode `movz x8, #93` (exit), not #141: a real
# qemu-aarch64 would reject the wrong syscall and the capability probe
# would report UNAVAILABLE.  Decode the second instruction word.
a64_hex="$(grep -o 'BH_QEMU_PROBE_AARCH64_HEX="[0-9a-f]*"' "$ROOT/scripts/bootstrap_helpers.sh" | head -1 | sed 's/.*="//; s/"//')"
case "$a64_hex" in
  *000080d2a80b80d2010000d4)
    a64_movz_hex="${a64_hex:248:8}"  # instruction 2 of code at byte 124
    a64_word=$((0x${a64_movz_hex:6:2}${a64_movz_hex:4:2}${a64_movz_hex:2:2}${a64_movz_hex:0:2}))
    a64_imm=$(((a64_word >> 5) & 0xFFFF))
    if [ "$a64_imm" -eq 93 ]; then
      pass "AArch64 qemu probe encodes movz x8,#93 then svc #0 (imm $a64_imm)"
    else
      bad "AArch64 qemu probe exit syscall immediate is $a64_imm, want 93"
    fi
    ;;
  *)
    bad "AArch64 qemu probe code bytes are not movz x8,#93; svc #0"
    ;;
esac

# Real-QEMU execution wherever the host provides qemu-aarch64: the shell
# mock proves the selection/capability plumbing, but only the real
# emulator proves the embedded machine code runs.  CI hosts without the
# binary skip this leg (the mock path above still runs everywhere).
real_qemu="$(command -v qemu-aarch64 2>/dev/null || command -v qemu-aarch64-static 2>/dev/null || true)"
if [ -n "$real_qemu" ]; then
  if bash -c 'source "$1"; p="$(mktemp)"; bh_write_hex_file "$BH_QEMU_PROBE_AARCH64_HEX" "$p"; chmod +x "$p"; "$2" "$p"; rc=$?; rm -f "$p"; exit $rc' \
    _ "$ROOT/scripts/bootstrap_helpers.sh" "$real_qemu"; then
    pass "real qemu-aarch64 executes the probe ELF to exit 0"
  else
    bad "real qemu-aarch64 could not execute the probe ELF (wrong syscall/encoding)"
  fi
else
  pass "real qemu-aarch64 absent on this host (mock capability path only)"
fi

if [ "$fail" -ne 0 ]; then
  echo "test_prebootstrap_gates: FAIL"
  exit 1
fi
echo "test_prebootstrap_gates: ALL PASS"
exit 0
