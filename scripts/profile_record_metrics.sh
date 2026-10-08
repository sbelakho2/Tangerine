#!/usr/bin/env bash
# profile_record_metrics.sh — bounded-profiling evidence recorder (schema 2).
#
# Measurement-only tool: reads a TANGERINE_DEBUG_STEPS=1 bootstrap profile
# log (VM BEACON / VM ALLOC SITES / VM STEPS / TRAPPED / [phase] lines)
# and prints ONE STABLE machine-readable block, one KEY=VALUE per line.
# It never writes to the compiler tree and never prints an authorization
# sentinel; it exists so a completed cold+warm pair can be turned into
# measured budget numbers (scripts/repin_bootstrap_limits.py).
#
# Usage:
#   scripts/profile_record_metrics.sh <logfile> [label]
#
# LOG KINDS (detected, see LOG_KIND):
#   standalone  profile_ocaml_bootstrap.sh ran tg_bootstrap_selfcheck.exe:
#               one VM only — the self-host preflight.  That single VM is
#               recorded as VM_B_* (the same workload the aggregate gate's
#               VM B runs); VM_A_* stays UNKNOWN.
#   aggregate   profile_ocaml_bootstrap_gate.sh ran tg_bootstrap_gate.exe
#               (detected by the gate banner `BOOTSTRAP COMPLETENESS GATE
#               (tg_bootstrap_gate)` or an AGGREGATE_WALL_S= line).
#               Sectioning: everything after the banner and before the
#               [11/11] marker is VM A (the artifact-corpus compile);
#               everything after [11/11] until `SELF-HOST PREFLIGHT:` is
#               VM B (the strict self-host preflight).  Fields absent in
#               a section are UNKNOWN, never guessed.
#
# SUCCESS RECOGNITION (never a loose grep PASS; error descriptions
# legitimately contain "PASS"):
#   standalone: SELFCHECK_RESULT=PASS requires EXACTLY ONE line equal to
#     `TANGERINE_SELFCHECK_PASS name=tg_bootstrap_selfcheck version=1`
#     (ANSI-stripped/trimmed before comparison) and no failure-evidence
#     line.  Zero or more than one sentinel => FAIL with a reason.
#     The old wrong recognizer (`SELF-HOST PREFLIGHT: PASS`, the
#     AGGREGATE gate's wording) is gone from this path.
#   aggregate: SELFCHECK_RESULT=PASS requires exactly one
#     `BOOTSTRAP GATE: PASS` full-closure line, exactly one
#     `SELF-HOST PREFLIGHT: PASS` line, a `typecheck: 0 errors` line and
#     no failure-evidence line (the same facts
#     scripts/check_ocaml_bootstrap_complete.sh requires; the aggregate
#     wrapper can never print the authorization sentinel itself).
#   RUN_OUTCOME=PASS requires SELFCHECK_RESULT=PASS AND a present
#     numeric `RUN_EXIT=0` AND no TRAPPED / FAIL / NOT RUN / HIR_INVALID /
#     HIR_MISSING line.
#
# STATUS (first match wins):
#   TRAPPED_RSS    a `TRAPPED: vm: RSS limit exceeded: ...` line exists
#   TRAPPED_STEPS  a `TRAPPED: vm: step limit exceeded` line exists
#   TRAPPED_OTHER  any other VM trap
#   COMPLETED      a final `VM STEPS:` summary exists and no trap fired.
#   INCOMPLETE     the log is still being written / truncated: beacons or
#                  a header exist but no final VM STEPS summary (a
#                  partially written log is NOT an error).
#   FAILED_NO_VM   the log terminated (`RUN_EXIT=` line, legacy `exit=`
#                  line or selfcheck line) with no VM beacon and no VM
#                  STEPS line at all.
#
# Header fields (schema 2; every one UNKNOWN when absent):
#   RUN_SHA RUN_TREE_CLEAN RUN_TARGET SEED_SHA256 MANIFEST_SHA256
#   CLOSURE_FINGERPRINT RUN_GC_POLICY (from `GC_POLICY=`) RUN_EXIT
#   (numeric only; a non-numeric/absent value is UNKNOWN and can never
#   yield RUN_OUTCOME=PASS) plus OCAML_VERSION/DUNE_VERSION/
#   PROFILE_MAX_* and AGGREGATE_WALL_S for the aggregate wrapper.
#   CLOSURE_FINGERPRINT falls back to the harness's in-run
#   `  fingerprint: <64hex>` line.
#
# Field sources:
#   FINAL_STEPS      last `VM STEPS:` summary (falls back to last beacon);
#                    FINAL_STEPS_SOURCE names which.
#   FINAL_DT_S       last beacon dt=.
#   PEAK_RSS_MIB     max rss_mb= over all beacons (exact integer).
#   ALLOC_BYTES      last beacon alloc_bytes=/alloc=/vm_alloc_bytes= if the
#                    beacon carries one, else last `alloc_bytes=` line, else
#                    UNKNOWN; ALLOC_BYTES_SOURCE names the key used.
#   HOST_CALLS       `VM STEPS:` host-calls summary (falls back to beacon host=).
#   WALL_PHASE_*     for each `[phase] label: 123.4s` print, the final value
#                    per distinct label; WALL_PHASE_SUM_S sums those finals.
#   VM_A_*/VM_B_*    per-section VM measurements (see LOG KINDS); wall
#                    times come from the driver's
#                    `[phase] VM run (kernel in the seed VM)` occurrences
#                    (section-assigned) and the gate's own
#                    `phase] self-host preflight VM run` line.
#
# Robustness: streamed with awk (no full-file lists), tolerates truncated
# final lines, missing fields, ANSI escapes, and thousands of beacons.
set -euo pipefail

LOG="${1:-}"
LABEL="${2:-}"
if [ -z "$LOG" ]; then
  echo "usage: scripts/profile_record_metrics.sh <logfile> [label]" >&2
  exit 2
fi
if [ ! -f "$LOG" ]; then
  echo "profile_record_metrics: no such log: $LOG" >&2
  exit 2
fi
if [ ! -r "$LOG" ]; then
  echo "profile_record_metrics: unreadable log: $LOG" >&2
  exit 2
fi
if [ -z "$LABEL" ]; then
  LABEL="$(basename "$LOG")"
fi

# A finalized log always ends with a newline (the wrappers append a final
# line).  An unterminated last line means the file is still being
# written or was truncated, which downgrades a lone VM STEPS summary to
# INCOMPLETE instead of claiming COMPLETED on a cut-off number.
ends_nl=0
if [ -s "$LOG" ]; then
  last_byte="$(tail -c 1 -- "$LOG" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  if [ "$last_byte" = "0a" ]; then
    ends_nl=1
  fi
fi

awk -v label="$LABEL" -v ends_nl="$ends_nl" '
function trim(s) { sub(/^[ ]+/, "", s); sub(/[ \r\n]+$/, "", s); return s }
function strip_ansi(s) { gsub(/\033\[[0-9;]*[A-Za-z]/, "", s); return s }
function slug(s,   t) {
  t = s
  gsub(/[^A-Za-z0-9]+/, "_", t)
  sub(/^_+/, "", t)
  sub(/_+$/, "", t)
  return toupper(t)
}
function extract_int(src, re,   s) {
  if (match(src, re) == 0) return ""
  s = substr(src, RSTART, RLENGTH)
  sub(/^[^0-9]*/, "", s)
  sub(/[^0-9].*$/, "", s)
  return s
}
function num(s) { return s + 0 }
function put(cond, val, noval) { return (cond ? val : noval) }

BEGIN { section = "B" }  # standalone logs hold only the preflight VM (VM B)

{ log_lines = NR
  s = strip_ansi($0)
  t = trim(s)
  if (length(t) > 0) last_line = substr(t, 1, 300)
}

# ── scanner: sentinels, aggregate detection/sectioning, header fields,
#    failure evidence.  Runs before the `next` rules so no line escapes it.
{
  # The exact standalone selfcheck sentinel (the ONLY success signal of
  # the standalone path; never a loose PASS grep).
  if (t == "TANGERINE_SELFCHECK_PASS name=tg_bootstrap_selfcheck version=1") sentinel_count++

  # Aggregate log detection (gate banner or wrapper-appended wall field).
  if (index(t, "BOOTSTRAP COMPLETENESS GATE (tg_bootstrap_gate)") > 0) {
    agg = 1
    a_seen = 1
    section = "A"
  }
  if (index(t, "[11/11]") > 0) { b_seen = 1; section = "B" }
  if (index(t, "SELF-HOST PREFLIGHT:") > 0) section = ""

  # Aggregate success facts (the same ones the authorization script checks).
  if (index(t, "BOOTSTRAP GATE: PASS") == 1 && index(t, "full closure through every stage") > 0)
    gate_pass_count++
  if (index(t, "SELF-HOST PREFLIGHT: PASS") > 0) preflight_pass_count++
  if (t ~ /^typecheck: 0 errors/) tc_zero_count++

  # Failure evidence (RUN_OUTCOME can never be PASS with any of these).
  if (index(t, "TRAPPED") > 0) trapped_ev++
  if (index(t, "HIR_INVALID") > 0) hir_invalid_ev++
  if (index(t, "HIR_MISSING") > 0) hir_missing_ev++
  if (index(t, "NOT RUN") > 0) not_run_ev++
  if (t ~ /(^|[^A-Za-z])FAIL/) fail_ev++

  # Header fields: first occurrence wins; CLOSURE_FINGERPRINT=UNKNOWN
  # (the pre-launch placeholder) is ignored in favour of the in-run value.
  if (profile_schema == "" && index(t, "PROFILE_SCHEMA=") == 1) profile_schema = substr(t, 16)
  if (run_sha == "" && index(t, "RUN_SHA=") == 1) run_sha = substr(t, 9)
  if (run_tree_clean == "" && index(t, "RUN_TREE_CLEAN=") == 1) run_tree_clean = substr(t, 16)
  if (run_target == "" && index(t, "RUN_TARGET=") == 1) run_target = substr(t, 12)
  if (seed_sha256 == "" && index(t, "SEED_SHA256=") == 1) seed_sha256 = substr(t, 13)
  if (manifest_sha256 == "" && index(t, "MANIFEST_SHA256=") == 1) manifest_sha256 = substr(t, 17)
  if (closure_hdr == "" && index(t, "CLOSURE_FINGERPRINT=") == 1) {
    v = substr(t, 21)
    if (v ~ /^[0-9a-fA-F]{64}$/) closure_hdr = v
  }
  if (ocaml_version == "" && index(t, "OCAML_VERSION=") == 1) ocaml_version = substr(t, 15)
  if (dune_version == "" && index(t, "DUNE_VERSION=") == 1) dune_version = substr(t, 14)
  if (gc_policy == "" && index(t, "GC_POLICY=") == 1) gc_policy = substr(t, 11)
  if (max_steps == "" && index(t, "PROFILE_MAX_STEPS=") == 1) max_steps = substr(t, 19)
  if (max_rss == "" && index(t, "PROFILE_MAX_RSS_MIB=") == 1) max_rss = substr(t, 21)
  if (max_host == "" && index(t, "PROFILE_MAX_HOST_CALLS=") == 1) max_host = substr(t, 24)
  if (max_alloc == "" && index(t, "PROFILE_MAX_ALLOC=") == 1) max_alloc = substr(t, 19)
  if (index(t, "RUN_EXIT=") == 1) { run_exit = substr(t, 10); run_exit_seen = 1 }
  if (dry_run == "" && index(t, "PROFILE_DRY_RUN=") == 1) dry_run = substr(t, 17)
  if (agg_wall == "" && index(t, "AGGREGATE_WALL_S=") == 1) {
    v = substr(t, 18)
    if (v ~ /^[0-9]+(\.[0-9]+)?$/) { agg = 1; agg_wall = v }
  }
}

/VM BEACON / {
  beacons++
  b_line = NR
  if (section == "A") a_beacons++
  else if (section == "B") b_beacons++
  for (i = 1; i <= NF; i++) {
    t = $i
    p = index(t, "=")
    if (p <= 1) continue
    k = substr(t, 1, p - 1)
    v = substr(t, p + 1)
    if (k == "steps") {
      b_steps = v
      if (section == "A") a_steps = v
      else if (section == "B") sb_steps = v
    } else if (k == "host") {
      b_host = v
      if (section == "A") a_host = v
      else if (section == "B") sb_host = v
    } else if (k == "dt") { sub(/[^0-9.].*$/, "", v); b_dt = v }
    else if (k == "live_mb") {
      b_live = v
      if (num(v) > peak_live) peak_live = num(v)
      if (section == "A" && num(v) > a_peak_live) a_peak_live = num(v)
      else if (section == "B" && num(v) > sb_peak_live) sb_peak_live = num(v)
    } else if (k == "rss_mb") {
      b_rss = v
      if (num(v) > peak_rss) peak_rss = num(v)
      if (section == "A" && num(v) > a_peak_rss) a_peak_rss = num(v)
      else if (section == "B" && num(v) > sb_peak_rss) sb_peak_rss = num(v)
    } else if (k == "mark_calls") b_mark_calls = v
    else if (k == "mark_nodes") b_mark_nodes = v
    else if (k == "regions") b_regions = v
    else if (k == "alloc_bytes") {
      b_alloc = v; b_alloc_key = "alloc_bytes"
      if (section == "A") { a_alloc = v; a_alloc_key = "last_beacon:alloc_bytes" }
      else if (section == "B") { sb_alloc = v; sb_alloc_key = "last_beacon:alloc_bytes" }
    } else if (k == "alloc" && b_alloc_key == "") {
      b_alloc = v; b_alloc_key = "alloc"
      if (section == "A" && a_alloc_key == "") { a_alloc = v; a_alloc_key = "last_beacon:alloc" }
      else if (section == "B" && sb_alloc_key == "") { sb_alloc = v; sb_alloc_key = "last_beacon:alloc" }
    } else if (k == "vm_alloc_bytes" && b_alloc_key == "") {
      b_alloc = v; b_alloc_key = "vm_alloc_bytes"
      if (section == "A" && a_alloc_key == "") { a_alloc = v; a_alloc_key = "last_beacon:vm_alloc_bytes" }
      else if (section == "B" && sb_alloc_key == "") { sb_alloc = v; sb_alloc_key = "last_beacon:vm_alloc_bytes" }
    }
  }
  next
}

/VM ALLOC SITES / {
  s = extract_int($0, "vm_alloc_bytes:[0-9]+")
  if (s != "") {
    sites_last = s
    if (section == "A") a_sites = s
    else if (section == "B") sb_sites = s
  }
  next
}

/VM STEPS:/ {
  vm_steps_line = NR
  vm_steps = extract_int($0, "VM STEPS: *[0-9]+")
  s = $0
  sub(/.*VM STEPS: *[0-9]+ *\(limit */, "", s)
  sub(/\).*/, "", s)
  vm_steps_limit = s
  host_calls = extract_int($0, "host calls: *[0-9]+")
  s = $0
  sub(/.*host calls: *[0-9]+ *\(limit */, "", s)
  sub(/\).*/, "", s)
  host_calls_limit = s
  if (section == "A") {
    a_vm_steps = vm_steps; a_vm_steps_limit = vm_steps_limit
    a_host_calls = host_calls; a_host_calls_limit = host_calls_limit
  } else if (section == "B") {
    sb_vm_steps = vm_steps; sb_vm_steps_limit = vm_steps_limit
    sb_host_calls = host_calls; sb_host_calls_limit = host_calls_limit
  }
  next
}

/(TRAPPED:|vm trap:)/ {
  if (trap_kind == "") {
    if ($0 ~ /RSS limit exceeded/) {
      trap_kind = "RSS"
      s = $0
      sub(/.*RSS limit exceeded: */, "", s)
      sub(/ *MiB.*/, "", s)
      trap_rss = s
      s = $0
      sub(/.*RSS limit exceeded: *[0-9]+ *MiB *> */, "", s)
      sub(/ *MiB.*/, "", s)
      trap_rss_limit = s
      trap_msg = "vm: RSS limit exceeded: " trap_rss " MiB > " trap_rss_limit " MiB"
    } else if ($0 ~ /step limit exceeded/) {
      trap_kind = "STEPS"
      trap_msg = "vm: step limit exceeded"
    } else {
      trap_kind = "OTHER"
      s = strip_ansi($0)
      sub(/.*TRAPPED: */, "", s)
      sub(/ *\[fn .*$/, "", s)
      if (s == strip_ansi($0)) sub(/.*vm trap: */, "", s)
      trap_msg = substr(trim(s), 1, 200)
    }
  }
  next
}

# Legacy per-line selfcheck verdicts are only parsed for STATUS/telemetry:
# they are NOT success recognition (the exact sentinel is).
/^tg_bootstrap_selfcheck: FAIL/ { if (selfcheck_line == "") selfcheck_line = "FAIL" }
/^tg_bootstrap_selfcheck: NOT RUN/ { if (selfcheck_line == "") selfcheck_line = "NOT_RUN" }

/fingerprint: [0-9a-fA-F]+/ {
  if (closure_fp == "") {
    s = strip_ansi($0)
    sub(/.*fingerprint: */, "", s)
    sub(/[^0-9a-fA-F].*/, "", s)
    closure_fp = s
  }
}

/mono: post-instance count [0-9]+/ {
  if (mono_inst == "") mono_inst = extract_int($0, "post-instance count *[0-9]+")
}
/-> post [0-9]+ specialized instance/ {
  if (mono_inst == "") mono_inst = extract_int($0, "post *[0-9]+ specialized")
}

{
  if (typed_hir == "" && $0 ~ /[Tt]yped[ _]HIR[ _](count|nodes) *[=:] *[0-9]+/)
    typed_hir = extract_int($0, "[Tt]yped[ _]HIR[ _](count|nodes) *[=:] *[0-9]+")
  if (pending_calls == "" && $0 ~ /pending[ _]calls? *[=:] *[0-9]+/)
    pending_calls = extract_int($0, "pending[ _]calls? *[=:] *[0-9]+")
  if (candidate_probes == "" && $0 ~ /candidate[ _]probes? *[=:] *[0-9]+/)
    candidate_probes = extract_int($0, "candidate[ _]probes? *[=:] *[0-9]+")
}

# Legacy wrapper terminator (`exit=N`, no RUN_EXIT header): recorded as
# EXIT_CODE telemetry only; RUN_OUTCOME requires the schema-2 RUN_EXIT.
/^exit=[0-9]+$/ {
  exit_seen = 1
  exit_value = extract_int($0, "exit=[0-9]+")
}

{
  if (run_sha == "" && $0 ~ /(run_sha|git_sha|commit) *= *[0-9a-fA-F]{7,}/) {
    s = $0
    if (match(s, /(run_sha|git_sha|commit) *= *[0-9a-fA-F]{7,}/)) {
      t = substr(s, RSTART, RLENGTH)
      sub(/.*= */, "", t)
      run_sha = t
    }
  }
  if (run_target == "") {
    s = strip_ansi($0)
    if (match(s, /target *= *[A-Za-z0-9_.-]+/)) {
      t = substr(s, RSTART, RLENGTH)
      sub(/.*target *= */, "", t)
      run_target = t
    } else if (match(s, /^check_ocaml_bootstrap_complete: target [A-Za-z0-9_.-]+/)) {
      t = substr(s, RSTART, RLENGTH)
      sub(/.*target */, "", t)
      run_target = t
    }
  }
}

{
  if (fingerprint == "") {
    s = strip_ansi($0)
    cp = index(s, "HIR_MISSING|")
    if (cp == 0) cp = index(s, "HIR_INVALID|")
    if (cp == 0) cp = index(s, "FRONTEND_FAIL|")
    if (cp > 0) fingerprint = substr(s, cp, 1000)
  }
}

{
  if (index($0, "phase]") > 0 && $0 ~ /[0-9]+\.[0-9]+s/) {
    s = strip_ansi($0)
    sub(/.*phase\] */, "", s)
    p = index(s, ": ")
    if (p > 0) {
      lbl = substr(s, 1, p - 1)
      rest = substr(s, p + 2)
      if (match(rest, /[0-9]+\.[0-9]+/) > 0) {
        val = substr(rest, RSTART, RLENGTH)
        key = slug(lbl)
        if (!(key in phase_seen)) { phase_seen[key] = ++phase_n; phase_order[phase_n] = key }
        phase_val[key] = val
        if (lbl == "self-host preflight VM run") vm_b_preflight_wall = val
        else if (lbl == "VM run (kernel in the seed VM)") {
          if (section == "A") vmA_wall = val
          else { vmB_wall = val; vmB_wall_src = (agg == 1 ? "driver_phase" : "standalone_driver_phase") }
        }
      }
    }
  }
}

END {
  if (trap_kind == "RSS") status = "TRAPPED_RSS"
  else if (trap_kind == "STEPS") status = "TRAPPED_STEPS"
  else if (trap_kind == "OTHER") status = "TRAPPED_OTHER"
  else if (vm_steps != "") {
    if (ends_nl == 0 && !run_exit_seen && !exit_seen)
      status = "INCOMPLETE"
    else if (ends_nl == 0 && (vm_steps_line == log_lines || b_line > vm_steps_line))
      status = "INCOMPLETE"
    else status = "COMPLETED"
  }
  else if (beacons > 0) status = "INCOMPLETE"
  else if (run_exit_seen || exit_seen || selfcheck_line != "") status = "FAILED_NO_VM"
  else status = "INCOMPLETE"

  failure_evidence = trapped_ev + hir_invalid_ev + hir_missing_ev + not_run_ev + fail_ev

  # SELFCHECK_RESULT: exact-sentinel recognition.  Standalone success is
  # ONE exact standalone sentinel and no failure evidence; aggregate
  # success is the gate PASS pair plus zero debt and no failure evidence
  # (the authorization script requires the same facts, but this recorder
  # NEVER prints an authorization sentinel).
  reason = ""
  if (agg == 1) {
    if (sentinel_count == 0 && gate_pass_count == 1 && preflight_pass_count == 1 && tc_zero_count >= 1 && failure_evidence == 0)
      selfcheck = "PASS"
    else {
      selfcheck = "FAIL"
      if (sentinel_count > 0) reason = reason "unexpected standalone sentinel in aggregate log; "
      if (gate_pass_count != 1) reason = reason "gate full-closure PASS lines=" gate_pass_count+0 " (want exactly 1); "
      if (preflight_pass_count != 1) reason = reason "self-host preflight PASS lines=" preflight_pass_count+0 " (want exactly 1); "
      if (tc_zero_count < 1) reason = reason "no `typecheck: 0 errors` line; "
      if (failure_evidence > 0) reason = reason "failure evidence present; "
      if (reason == "") reason = "aggregate PASS facts incomplete"
    }
  } else {
    if (sentinel_count == 1 && failure_evidence == 0) selfcheck = "PASS"
    else {
      selfcheck = "FAIL"
      if (sentinel_count == 0) reason = "no TANGERINE_SELFCHECK_PASS name=tg_bootstrap_selfcheck version=1 line"
      else if (sentinel_count > 1) reason = sentinel_count " sentinel lines (want exactly 1)"
    }
  }
  if (failure_evidence > 0) {
    ev = "failure evidence: trapped=" trapped_ev+0 " fail=" fail_ev+0 " not_run=" not_run_ev+0 \
      " hir_invalid=" hir_invalid_ev+0 " hir_missing=" hir_missing_ev+0
    reason = (reason == "" ? ev : reason "; " ev)
  }
  if (reason == "") reason = "none"

  run_exit_numeric = (run_exit_seen && run_exit ~ /^[0-9]+$/)
  if (selfcheck == "PASS" && run_exit_numeric && run_exit + 0 == 0 && failure_evidence == 0)
    outcome = "PASS"
  else outcome = "FAIL"

  if (vm_steps != "") { final_steps = vm_steps; final_steps_source = "vm_summary" }
  else if (b_steps != "") { final_steps = b_steps; final_steps_source = "last_beacon" }
  else { final_steps = "UNKNOWN"; final_steps_source = "none" }

  if (host_calls != "") host_source = "vm_summary"
  else if (b_host != "") { host_calls = b_host; host_source = "last_beacon" }
  else host_source = "none"

  if (b_alloc != "") { alloc_bytes = b_alloc; alloc_source = "last_beacon:" b_alloc_key }
  else if (sites_last != "") { alloc_bytes = sites_last; alloc_source = "vm_alloc_sites" }
  else { alloc_bytes = "UNKNOWN"; alloc_source = "none" }

  sum = 0
  for (i = 1; i <= phase_n; i++) sum += phase_val[phase_order[i]]
  if (phase_n > 0) wall_sum = sprintf("%.1f", sum)
  else wall_sum = "UNKNOWN"

  # Standalone logs hold only the preflight VM; aggregate logs expose VM A
  # (artifact-corpus compile) and VM B (self-host preflight).
  if (agg == 0) { b_seen = 1; a_seen = 0 }

  vmA_steps = put(a_vm_steps != "", a_vm_steps, put(a_steps != "", a_steps, "UNKNOWN"))
  vmA_steps_src = put(a_vm_steps != "", "vm_summary", put(a_steps != "", "last_beacon", "none"))
  vmA_host = put(a_host_calls != "", a_host_calls, put(a_host != "", a_host, "UNKNOWN"))
  vmA_host_src = put(a_host_calls != "", "vm_summary", put(a_host != "", "last_beacon", "none"))
  vmA_alloc = put(a_alloc != "", a_alloc, put(a_sites != "", a_sites, "UNKNOWN"))
  vmA_alloc_src = put(a_alloc != "", a_alloc_key, put(a_sites != "", "vm_alloc_sites", "none"))
  vmA_rss = put(a_beacons > 0, sprintf("%d", a_peak_rss), "UNKNOWN")
  vmA_live = put(a_beacons > 0, sprintf("%d", a_peak_live), "UNKNOWN")

  vmB_steps = put(sb_vm_steps != "", sb_vm_steps, put(sb_steps != "", sb_steps, "UNKNOWN"))
  vmB_steps_src = put(sb_vm_steps != "", "vm_summary", put(sb_steps != "", "last_beacon", "none"))
  vmB_host = put(sb_host_calls != "", sb_host_calls, put(sb_host != "", sb_host, "UNKNOWN"))
  vmB_host_src = put(sb_host_calls != "", "vm_summary", put(sb_host != "", "last_beacon", "none"))
  vmB_alloc = put(sb_alloc != "", sb_alloc, put(sb_sites != "", sb_sites, "UNKNOWN"))
  vmB_alloc_src = put(sb_alloc != "", sb_alloc_key, put(sb_sites != "", "vm_alloc_sites", "none"))
  vmB_rss = put(b_beacons > 0, sprintf("%d", sb_peak_rss), "UNKNOWN")
  vmB_live = put(b_beacons > 0, sprintf("%d", sb_peak_live), "UNKNOWN")

  print "RUN_LABEL=" label
  print "LOG_KIND=" put(agg == 1, "aggregate", "standalone")
  print "PROFILE_SCHEMA=" put(profile_schema != "", profile_schema, "UNKNOWN")
  print "PROFILE_DRY_RUN=" put(dry_run != "", dry_run, "0")
  print "RUN_SHA=" put(run_sha != "", run_sha, "UNKNOWN")
  print "RUN_TREE_CLEAN=" put(run_tree_clean != "", run_tree_clean, "UNKNOWN")
  print "RUN_TARGET=" put(run_target != "", run_target, "UNKNOWN")
  print "SEED_SHA256=" put(seed_sha256 != "", seed_sha256, "UNKNOWN")
  print "MANIFEST_SHA256=" put(manifest_sha256 != "", manifest_sha256, "UNKNOWN")
  print "RUN_GC_POLICY=" put(gc_policy != "", gc_policy, "UNKNOWN")
  print "OCAML_VERSION=" put(ocaml_version != "", ocaml_version, "UNKNOWN")
  print "DUNE_VERSION=" put(dune_version != "", dune_version, "UNKNOWN")
  print "PROFILE_MAX_STEPS=" put(max_steps != "", max_steps, "UNKNOWN")
  print "PROFILE_MAX_RSS_MIB=" put(max_rss != "", max_rss, "UNKNOWN")
  print "PROFILE_MAX_HOST_CALLS=" put(max_host != "", max_host, "UNKNOWN")
  print "PROFILE_MAX_ALLOC=" put(max_alloc != "", max_alloc, "UNKNOWN")
  print "RUN_EXIT=" put(run_exit_seen, run_exit, "UNKNOWN")
  print "STATUS=" status
  print "SELFCHECK_RESULT=" selfcheck
  print "SELFCHECK_RESULT_REASON=" reason
  print "RUN_OUTCOME=" outcome
  print "BEACON_COUNT=" beacons + 0
  print "LOG_LINES=" log_lines + 0
  print "FINAL_STEPS=" final_steps
  print "FINAL_STEPS_LIMIT=" put(vm_steps_limit != "", vm_steps_limit, "UNKNOWN")
  print "FINAL_STEPS_SOURCE=" final_steps_source
  print "FINAL_DT_S=" put(b_dt != "", b_dt, "UNKNOWN")
  print "PEAK_RSS_MIB=" put(beacons > 0, sprintf("%d", peak_rss), "UNKNOWN")
  print "PEAK_LIVE_MB=" put(beacons > 0, sprintf("%d", peak_live), "UNKNOWN")
  print "FINAL_LIVE_MB=" put(b_live != "", b_live, "UNKNOWN")
  print "ALLOC_BYTES=" alloc_bytes
  print "ALLOC_BYTES_SOURCE=" alloc_source
  print "VM_ALLOC_SITE_COUNT=" put(sites_last != "", sites_last, "UNKNOWN")
  print "HOST_CALLS=" put(host_calls != "", host_calls, "UNKNOWN")
  print "HOST_CALLS_LIMIT=" put(host_calls_limit != "", host_calls_limit, "UNKNOWN")
  print "HOST_CALLS_SOURCE=" host_source
  print "MARK_CALLS=" put(b_mark_calls != "", b_mark_calls, "UNKNOWN")
  print "MARK_NODES=" put(b_mark_nodes != "", b_mark_nodes, "UNKNOWN")
  print "CANDIDATE_PROBES=" put(candidate_probes != "", candidate_probes, "UNKNOWN")
  print "PENDING_CALLS=" put(pending_calls != "", pending_calls, "UNKNOWN")
  print "MONO_INSTANCES=" put(mono_inst != "", mono_inst, "UNKNOWN")
  print "TYPED_HIR_COUNT=" put(typed_hir != "", typed_hir, "UNKNOWN")
  print "CLOSURE_FINGERPRINT=" put(closure_hdr != "", closure_hdr, put(closure_fp != "", closure_fp, "UNKNOWN"))
  print "TRAP_MESSAGE=" put(trap_msg != "", trap_msg, "none")
  print "TRAP_RSS_MIB=" put(trap_rss != "", trap_rss, "none")
  print "TRAP_RSS_LIMIT_MIB=" put(trap_rss_limit != "", trap_rss_limit, "none")
  print "WALL_PHASE_SUM_S=" wall_sum
  for (i = 1; i <= phase_n; i++) print "WALL_PHASE_" phase_order[i] "=" phase_val[phase_order[i]]
  print "AGGREGATE_WALL_S=" put(agg_wall != "", agg_wall, "UNKNOWN")
  print "VM_A_BEACONS=" put(a_seen, a_beacons + 0, "UNKNOWN")
  print "VM_A_FINAL_STEPS=" vmA_steps
  print "VM_A_FINAL_STEPS_LIMIT=" put(a_vm_steps_limit != "", a_vm_steps_limit, "UNKNOWN")
  print "VM_A_FINAL_STEPS_SOURCE=" vmA_steps_src
  print "VM_A_HOST_CALLS=" vmA_host
  print "VM_A_HOST_CALLS_LIMIT=" put(a_host_calls_limit != "", a_host_calls_limit, "UNKNOWN")
  print "VM_A_HOST_CALLS_SOURCE=" vmA_host_src
  print "VM_A_ALLOC_BYTES=" vmA_alloc
  print "VM_A_ALLOC_BYTES_SOURCE=" vmA_alloc_src
  print "VM_A_PEAK_RSS_MIB=" vmA_rss
  print "VM_A_PEAK_LIVE_MB=" vmA_live
  print "VM_A_WALL_S=" put(vmA_wall != "", vmA_wall, "UNKNOWN")
  print "VM_A_WALL_SOURCE=" put(vmA_wall != "", "driver_phase", "none")
  print "VM_B_BEACONS=" put(b_seen, b_beacons + 0, "UNKNOWN")
  print "VM_B_FINAL_STEPS=" vmB_steps
  print "VM_B_FINAL_STEPS_LIMIT=" put(sb_vm_steps_limit != "", sb_vm_steps_limit, "UNKNOWN")
  print "VM_B_FINAL_STEPS_SOURCE=" vmB_steps_src
  print "VM_B_HOST_CALLS=" vmB_host
  print "VM_B_HOST_CALLS_LIMIT=" put(sb_host_calls_limit != "", sb_host_calls_limit, "UNKNOWN")
  print "VM_B_HOST_CALLS_SOURCE=" vmB_host_src
  print "VM_B_ALLOC_BYTES=" vmB_alloc
  print "VM_B_ALLOC_BYTES_SOURCE=" vmB_alloc_src
  print "VM_B_PEAK_RSS_MIB=" vmB_rss
  print "VM_B_PEAK_LIVE_MB=" vmB_live
  print "VM_B_WALL_S=" put(vmB_wall != "", vmB_wall, "UNKNOWN")
  print "VM_B_WALL_SOURCE=" put(vmB_wall != "", vmB_wall_src, "none")
  print "VM_B_PREFLIGHT_WALL_S=" put(vm_b_preflight_wall != "", vm_b_preflight_wall, "UNKNOWN")
  print "VM_B_PREFLIGHT_WALL_SOURCE=" put(vm_b_preflight_wall != "", "gate_phase", "none")
  print "FAILURE_FINGERPRINT=" put(fingerprint != "", fingerprint, "NONE")
  print "FIRST_FAILURE_FINGERPRINT=" put(fingerprint != "", fingerprint, "none")
  print "EXIT_CODE=" put(exit_seen, exit_value, "none")
  print "LAST_LINE=" put(last_line != "", last_line, "none")
}
' "$LOG"
