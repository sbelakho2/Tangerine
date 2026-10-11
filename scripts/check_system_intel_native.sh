#!/usr/bin/env bash
# scripts/check_system_intel_native.sh — the system_intel NATIVE release gate.
#
# The native sibling of scripts/check_system_intel_gate.sh: instead of the
# pure-python suite it proves that the system_intel layer actually consumes
# the Tangerine compiler's native semantic surface. It is the body of the
# `.woodpecker/system-intel-native.yaml` `system-intel-native` step and runs
# on the Darwin/arm64 local-backend agent after `.woodpecker/bootstrap.yaml`
# publishes the materialized full driver `build/tg` (the CLI that carries
# the §30 snapshot route and the §39 server) inside the
# `tg-stages-macos-arm64` artifact. It never rebuilds the compiler.
#
# Contract (system_intel/INTERFACES.md §5/§7; fail closed, never skip):
#   1. the native compiler at $TANGERINE_NATIVE_COMPILER (default
#      `build/tg`, the authoritative bootstrap path) must exist and be
#      executable — a missing artifact FAILS, there is no stage3 fallback;
#   2. `system_intel.providers.registry.select_for` must select the
#      `tangerine-native` provider for the repository root;
#   3. a `system_intel.persist.scan` of the repository with that provider
#      must record the `tangerine-native` provider, and the persisted
#      snapshot must prove a REAL native semantic surface was consumed:
#        - §30 evidence `native_snapshot_artifact` with a sha256 digest and
#          the header's content-addressed revision;
#        - the provider-record capability `entities == "complete"`;
#        - at least one projected `native:*` entity;
#        - a §39 `native_server` session answering `revision` and
#          `snapshot.get` (the offline `--snapshot-only` route).
#
# Exactly one final verdict line is printed on every path (the FAIL line
# also covers unexpected tool errors):
#   SYSTEM_INTEL_NATIVE_GATE: PASS   (exit 0)
#   SYSTEM_INTEL_NATIVE_GATE: FAIL   (exit non-zero)
#
# Exit codes:
#   0  PASS
#   2  native compiler missing or not executable (fail closed)
#   3  the tangerine-native provider is not selectable via the registry
#   4  the scan / native snapshot consumption check failed
#   5  python3 is missing (the provider layer is python3)
#   any other non-zero: an unexpected tool failure
#
# Portable to GNU and BSD userlands: POSIX/bash builtins, mktemp and
# python3 only.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

workdir=""

fail() {
    # fail <exit-code> <message>
    printf 'error: system_intel native gate: %s\n' "$2" >&2
    exit "$1"
}

on_exit() {
    status=$?
    if [ -n "$workdir" ] && [ -d "$workdir" ]; then
        rm -rf "$workdir" || true
    fi
    if [ "$status" -ne 0 ]; then
        printf 'SYSTEM_INTEL_NATIVE_GATE: FAIL\n'
    fi
    return "$status"
}
trap on_exit EXIT

# ── 1. the native compiler must exist and be executable ──────────────────
COMPILER="${TANGERINE_NATIVE_COMPILER:-build/tg}"
case "$COMPILER" in
    /*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac
export TANGERINE_NATIVE_COMPILER="$COMPILER"

echo "==> native compiler assertion ($COMPILER)"
if [ ! -f "$COMPILER" ]; then
    fail 2 "the native compiler does not exist at '$COMPILER' (the bootstrap lane publishes the materialized full driver as 'tg' inside the tg-stages-macos-arm64 artifact; this lane must consume it, never rebuild it or fall back to tg_stage3)"
fi
if [ ! -x "$COMPILER" ]; then
    fail 2 "the native compiler '$COMPILER' exists but is not executable (restore the bootstrap artifact's file mode, or point TANGERINE_NATIVE_COMPILER at an executable)"
fi

command -v python3 >/dev/null 2>&1 || fail 5 "python3 is required by the system_intel native gate"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/system-intel-native.XXXXXX")"
DB="$workdir/db"
echo "==> native provider selection + §30/§39 snapshot smoke (scratch DB: $DB)"

TG_SI_ROOT="$ROOT" TG_SI_DB="$DB" python3 - <<'PY'
import json
import os
import sys

ROOT = os.environ["TG_SI_ROOT"]
DB = os.environ["TG_SI_DB"]


def fail(code, message):
    print("error: system_intel native gate: %s" % message, file=sys.stderr)
    sys.exit(code)


if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

from system_intel.graph import Graph
from system_intel.persist import scan
from system_intel.providers.registry import select_for

# ── 2. the tangerine-native provider must be selected ────────────────────
selected = select_for(ROOT)
native = [p for p in selected
          if str(getattr(p, "provider_id", "") or "") == "tangerine-native"]
if not native:
    fail(3, "the tangerine-native provider is not selectable for %s "
            "(registry.select_for returned %r; the provider applies to .tg "
            "trees and to explicit TANGERINE_NATIVE_COMPILER / "
            "TANGERINE_NATIVE_SNAPSHOT overrides)"
         % (ROOT, [str(getattr(p, "provider_id", "") or "?") for p in selected]))
provider = native[0]
print("  selected providers (authority order): %s"
      % ", ".join("%s %s" % (str(getattr(p, "provider_id", "") or "?"),
                             str(getattr(p, "provider_version", "") or "?"))
                  for p in selected))
print("  native compiler: %s"
      % os.environ.get("TANGERINE_NATIVE_COMPILER", ""))

# ── 3. scan the repository with that provider ────────────────────────────
try:
    report = scan(ROOT, DB, provider=provider)
except Exception as exc:  # the gate must FAIL loudly, never degrade to a skip
    fail(4, "system_intel scan of %s raised %s: %s"
         % (ROOT, exc.__class__.__name__, exc))

recorded = [str(p) for p in report.get("providers", [])]
if "tangerine-native" not in recorded:
    fail(4, "the scan did not record the tangerine-native provider "
            "(providers=%r)" % recorded)
print("  scan: snapshot_id=%s entities=%s facts=%s relations=%s evidence=%s"
      % (report.get("snapshot_id"), report.get("entities_upserted"),
         report.get("facts_upserted"), report.get("relations_upserted"),
         report.get("evidence")))

with Graph.open(DB, create=False) as graph:
    doc = graph.export_json()


def payload_of(row):
    payload = row.get("payload")
    if isinstance(payload, str):
        try:
            payload = json.loads(payload)
        except ValueError:
            payload = {}
    return payload if isinstance(payload, dict) else {}


evidence = doc.get("evidence", [])
artifact_ev = [e for e in evidence
               if str(e.get("kind", "")) == "native_snapshot_artifact"]
server_ev = [e for e in evidence if str(e.get("kind", "")) == "native_server"]
notes = [str(e.get("summary", "")) for e in evidence
         if str(e.get("kind", "")) in ("provider_note", "provider_error")]

# ── 3a. a real §30 SemanticSnapshot artifact was consumed ────────────────
if not artifact_ev:
    fail(4, "no native_snapshot_artifact evidence: the tangerine-native "
            "provider did not consume a §30 SemanticSnapshot (notes: %s)"
         % (" | ".join(notes) or "none recorded"))
artifact = artifact_ev[0]
digest = str(artifact.get("digest", "") or "")
if not digest:
    fail(4, "the native_snapshot_artifact evidence carries no sha256 digest")
payload = payload_of(artifact)
revision = str(payload.get("revision", "") or "")
if not revision:
    fail(4, "the consumed §30 artifact has an empty revision header "
            "(compiler_version=%r) — this is not a finalized native snapshot"
         % str(payload.get("compiler_version", "") or ""))

# ── 3b. the provider record and the projected native entities ────────────
provider_records = [p for p in doc.get("provider_records", [])
                    if str(p.get("provider", "")) == "tangerine-native"]
if not provider_records:
    fail(4, "the persisted graph has no tangerine-native provider record")
capabilities = provider_records[0].get("capabilities") or {}
if str(capabilities.get("entities", "unavailable")) != "complete":
    fail(4, "the tangerine-native provider record does not report entities "
            "as 'complete' (capabilities=%r) — the native surface was not "
            "consumed" % capabilities)

native_entities = [e for e in doc.get("entities", [])
                   if str(e.get("stable_id", "")).startswith("native:")]
if not native_entities:
    fail(4, "no `native:` entities were projected from the §30 artifact "
            "(the artifact parsed but carried no symbol/type/contract/test rows)")

# ── 3c. the §39 server session (offline --snapshot-only route) ───────────
if not server_ev:
    fail(4, "no native_server evidence: the §39 semantic-server session did "
            "not answer (notes: %s)" % (" | ".join(notes) or "none recorded"))
kinds = payload_of(server_ev[0]).get("kinds") or {}
missing = [op for op in ("revision", "snapshot.get")
           if not str(kinds.get(op, ""))]
if missing:
    fail(4, "the §39 native server session did not answer %s "
            "(answered: %r; notes: %s)"
         % (", ".join(missing), kinds, " | ".join(notes) or "none recorded"))

print("  [ok] tangerine-native selected and consumed: §30 artifact revision "
      "%s (digest %s..., %d native entities); §39 session answered %s"
      % (revision, digest[:12], len(native_entities),
         ", ".join("%s=%s" % (op, kinds[op]) for op in sorted(kinds))))
PY

printf 'SYSTEM_INTEL_NATIVE_GATE: PASS\n'
