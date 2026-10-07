#!/usr/bin/env bash
# profile_record_metrics.sh — bounded-profiling evidence recorder.
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
# STATUS (first match wins):
#   TRAPPED_RSS    a `TRAPPED: vm: RSS limit exceeded: ...` line exists
#   TRAPPED_STEPS  a `TRAPPED: vm: step limit exceeded` line exists
#   TRAPPED_OTHER  any other VM trap
#   COMPLETED      a final `VM STEPS:` summary exists and no trap fired.
#                  SELFCHECK_RESULT separately reports PASS / FAIL / NOT_RUN
#                  when the log carries the selfcheck outcome, so a VM run
#                  that finished but whose kernel check failed is still
#                  flagged (STATUS=COMPLETED, SELFCHECK_RESULT=FAIL).
#   INCOMPLETE     the log is still being written / truncated: beacons or
#                  a header exist but no final VM STEPS summary (a
#                  partially written log is NOT an error).
#   FAILED_NO_VM   the log terminated (`exit=` line or selfcheck line)
#                  with no VM beacon and no VM STEPS line at all.
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

# A finalized log always ends with a newline (the wrapper appends
# `exit=N`).  An unterminated last line means the file is still being
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

{ log_lines = NR
  s = strip_ansi($0)
  t = trim(s)
  if (length(t) > 0) last_line = substr(t, 1, 300)
}

/VM BEACON / {
  beacons++
  b_line = NR
  for (i = 1; i <= NF; i++) {
    t = $i
    p = index(t, "=")
    if (p <= 1) continue
    k = substr(t, 1, p - 1)
    v = substr(t, p + 1)
    if (k == "steps") b_steps = v
    else if (k == "host") b_host = v
    else if (k == "dt") { sub(/[^0-9.].*$/, "", v); b_dt = v }
    else if (k == "live_mb") {
      b_live = v
      if (num(v) > peak_live) peak_live = num(v)
    } else if (k == "rss_mb") {
      b_rss = v
      if (num(v) > peak_rss) peak_rss = num(v)
    } else if (k == "mark_calls") b_mark_calls = v
    else if (k == "mark_nodes") b_mark_nodes = v
    else if (k == "regions") b_regions = v
    else if (k == "alloc_bytes") { b_alloc = v; b_alloc_key = "alloc_bytes" }
    else if (k == "alloc" && b_alloc_key == "") { b_alloc = v; b_alloc_key = "alloc" }
    else if (k == "vm_alloc_bytes" && b_alloc_key == "") { b_alloc = v; b_alloc_key = "vm_alloc_bytes" }
  }
  next
}

/VM ALLOC SITES / {
  s = extract_int($0, "vm_alloc_bytes:[0-9]+")
  if (s != "") sites_last = s
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

/tg_bootstrap_selfcheck: FAIL/ { if (selfcheck == "") selfcheck = "FAIL" }
/tg_bootstrap_selfcheck: NOT RUN/ { if (selfcheck == "") selfcheck = "NOT_RUN" }
/SELF-HOST PREFLIGHT: PASS/ { if (selfcheck == "") selfcheck = "PASS" }

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
        key = slug(lbl)
        if (!(key in phase_seen)) { phase_seen[key] = ++phase_n; phase_order[phase_n] = key }
        phase_val[key] = substr(rest, RSTART, RLENGTH)
      }
    }
  }
}

END {
  if (trap_kind == "RSS") status = "TRAPPED_RSS"
  else if (trap_kind == "STEPS") status = "TRAPPED_STEPS"
  else if (trap_kind == "OTHER") status = "TRAPPED_OTHER"
  else if (vm_steps != "") {
    if (ends_nl == 0 && (vm_steps_line == log_lines || b_line > vm_steps_line))
      status = "INCOMPLETE"
    else status = "COMPLETED"
  }
  else if (beacons > 0) status = "INCOMPLETE"
  else if (exit_seen || selfcheck != "") status = "FAILED_NO_VM"
  else status = "INCOMPLETE"

  if (vm_steps != "") { final_steps = vm_steps; final_steps_source = "vm_summary" }
  else if (b_steps != "") { final_steps = b_steps; final_steps_source = "last_beacon" }
  else { final_steps = "UNKNOWN"; final_steps_source = "none" }

  if (host_calls != "") host_source = "vm_summary"
  else if (b_host != "") { host_calls = b_host; host_source = "last_beacon" }
  else host_source = "none"

  if (b_alloc != "") { alloc_bytes = b_alloc; alloc_source = "last_beacon:" b_alloc_key }
  else { alloc_bytes = "UNKNOWN"; alloc_source = "none" }

  if (selfcheck == "PASS") outcome = "PASS"
  else if (selfcheck == "FAIL" || selfcheck == "NOT_RUN") outcome = "FAIL"
  else outcome = "UNKNOWN"

  sum = 0
  for (i = 1; i <= phase_n; i++) sum += phase_val[phase_order[i]]
  if (phase_n > 0) wall_sum = sprintf("%.1f", sum)
  else wall_sum = "UNKNOWN"

  print "RUN_LABEL=" label
  print "RUN_SHA=" put(run_sha != "", run_sha, "UNKNOWN")
  print "RUN_TARGET=" put(run_target != "", run_target, "UNKNOWN")
  print "STATUS=" status
  print "SELFCHECK_RESULT=" put(selfcheck != "", selfcheck, "UNKNOWN")
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
  print "CLOSURE_FINGERPRINT=" put(closure_fp != "", closure_fp, "UNKNOWN")
  print "TRAP_MESSAGE=" put(trap_msg != "", trap_msg, "none")
  print "TRAP_RSS_MIB=" put(trap_rss != "", trap_rss, "none")
  print "TRAP_RSS_LIMIT_MIB=" put(trap_rss_limit != "", trap_rss_limit, "none")
  print "WALL_PHASE_SUM_S=" wall_sum
  for (i = 1; i <= phase_n; i++) print "WALL_PHASE_" phase_order[i] "=" phase_val[phase_order[i]]
  print "FIRST_FAILURE_FINGERPRINT=" put(fingerprint != "", fingerprint, "none")
  print "EXIT_CODE=" put(exit_seen, exit_value, "none")
  print "LAST_LINE=" put(last_line != "", last_line, "none")
}
' "$LOG"
