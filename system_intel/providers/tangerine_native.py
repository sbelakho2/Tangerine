"""tangerine-native provider: the authoritative Tangerine semantic provider.

Native truth comes from the self-hosted Tangerine compiler, through the TWO
documented routes (verified in ``tg_compiler/driver.tg`` and
``tg_compiler/semantic_server.tg``):

* ``TANGERINE_SNAPSHOT=<path>`` on a compile writes the §30 SemanticSnapshot
  artifact (plus ``<path>.lineages``); the artifact is built from FINALIZED
  type state + VERIFIED MIR, never from source scanning.  Its header carries
  the content-addressed revision, the compiler version, the target record
  (semantic configuration) and the public-API / ABI / unsafe surface hashes.
* ``tg server --snapshot-only --snapshot=<path>`` serves the §39 request
  protocol over stdin/stdout: each frame is a 4-byte BIG-ENDIAN body length
  followed by length-prefixed UTF-8 fields; the request fields are
  ``protocol_version, request_id, operation, payload`` and the response
  fields ``protocol_version, request_id, ok, kind, keys-count, keys...,
  error``.  Parsers fail closed (``semantic_request_parse`` /
  ``semantic_response_parse``, semantic_server.tg:3788/3859).  The operation
  registry is ``server_operations()`` (semantic_server.tg:3159); the
  ``revision`` service op answers the one-row digest render
  (semantic_server.tg:3040) and ``snapshot.get`` answers the family counts
  (semantic_query.tg:2293).

Compiler discovery (release authority, requirement 1)
-----------------------------------------------------
The release compiler is ``build/tg`` — the full driver the bootstrap lane
materializes (``run_bootstrap.sh`` "Full Toolchain Materialization Complete";
``Makefile`` ``TG ?= build/tg``).  Discovery order is: explicit constructor
``binary`` -> ``TANGERINE_NATIVE_COMPILER`` -> ``<root>/build/tg`` ->
``<repo_root>/build/tg``.  ``TANGERINE_NATIVE_SNAPSHOT`` names an explicit
artifact.  ``build/bootstrap/tg`` is NOT consulted: it is a ladder/kernel
stage, not the release compiler.

Persistent native identity (requirement 2)
------------------------------------------
Stable IDs use the native PERSISTENT DIGEST carried by the artifact, never
the textual key:

* declaration rows (``symbol``, ``type``) carry ``i``, the persisted
  ``StableDefId`` digest render ``<hi>-<lo>``; the stable id is
  ``native:decl:<hi>-<lo>``.  The textual ``key``/``name``/``module`` fields
  become ATTRIBUTES (``key``, ``name``, ``module``); a rename keeps the
  digest (the identity) and only moves those attributes.
* ``test`` rows carry the persisted ``StableTestId`` digest in ``test``; the
  stable id is ``native:test:<hi>-<lo>`` and the canonical ``tkey`` text is
  an attribute.
* ``contract`` rows carry the persisted ``StableContractId`` digest in
  ``i``; the stable id is ``native:contract:<hi>-<lo>``.
* dependency rows (``dep-*``) and member/resource rows carry canonical KEY
  TEXTS; they are resolved to ``native:decl:<digest>`` through the artifact's
  ``key -> digest`` table (built from the symbol/type rows).
* A zero digest (``0-0``, the native "no identity" digest) or an artifact
  with genuinely no persistent digest (the server-only ``symbol_search``
  route) degrades to the deterministic textual fallback
  ``native:sym:<key text>`` / ``native:key:<key text>``; every degraded row
  records ``identity_degraded: True`` and an ``identity_basis`` attribute so
  consumers can never mistake it for persistent identity.

Projection into the universal vocabulary (§5)
---------------------------------------------
Every row family the §30 artifact exposes is projected (read from
``tg_compiler/semantic_snapshot.tg``'s parse loop, lines 11087-11329):
symbols/types (entity), typed members (``field``/``variant``/``signature``/
``trait-method`` facts), calls (``calls`` relations), indirect sites
(unresolved claims, empty candidates, completeness ``unknown`` — mirrored
exactly, semantic_snapshot.tg:7527), effects/capabilities/ownership facts,
contracts + ``dep-contract-ref`` (Contract entities + ``contract_ref``
facts + ``constrained_by``/``depends_on`` relations), tests (Test entities +
``tests`` relations), coverage (facts + tests relations), MIR summaries
(facts), concrete types + the typed dependency families
(``dep-type-use``/``dep-trait-impl``/``dep-trait-select``/
``dep-generic-inst``/``dep-layout``/``dep-const-eval``/``dep-derived-body``/
``dep-abi`` -> ``depends_on``/``implements`` relations), unsafe/drop/DMA and
resource-summary rows (facts), ABI surfaces (``API`` entities + facts), and
the header surface hashes (``Repository`` entity ``repo:.`` + ``native.*``
facts).  ``dep-completeness`` rows mirror the producer verdicts and are NEVER
upgraded.  Families the artifact does not carry (invariants, history) stay
``unknown`` with an honest capability note.

Contract canonicalization (requirement 4)
-----------------------------------------
The graph's canonical contract representation is the ``(kind, name)`` pair
(``graph.add_contract``).  The provider emits, for EVERY native ``contract``
row, a machine-readable fact ``predicate='contract_ref'`` with
``object='contract:<kind>:<name>'`` where ``<kind>`` is the native contract
kind word (``Pre``/``Post``/``Invariant``, the closed
``snapshot_contract_kind_of_word`` vocabulary) and ``<name>`` is the native
canonical contract row key ``<fn key>|<kind>|<clause>``
(``stable_contract_row_key``, stable_ids.tg:722) when the holder key is
known, else ``digest::<hi>-<lo>``.  A ``dep-contract-ref`` row emits the same
shape with the REFERENCED symbol as fact subject; when the contract row join
fails the object stays ``contract:unknown:<contract id>`` with
``contract_kind_unresolved`` recorded — never a fabricated kind.

Native semantic delta (requirement 5)
-------------------------------------
The artifact does not serialize a §31 delta and the §39 server's
``snapshot.diff`` op answers ``snapshot.diff_unavailable`` on the single
snapshot a session holds (semantic_query.tg:2891) — so no native pair delta
rides the provider's two routes.  ``delta(old, new)`` therefore translates
the native row identity diff computed from the two §30 artifacts the
provider parsed: entity families with persistent digests (declarations,
tests, contracts) plus the indirect unresolved additions, keyed by the
typed stable ids above.  The result carries ``source: "native"`` plus a
``note``.  When either snapshot has no cached accepted artifact (server-only
snapshots, rejected artifacts, snapshots from another provider instance),
``delta`` falls back to the generic ``_snapshot_delta`` with
``source: "generic"`` and an explanatory note.  Edge-only deltas are not
fabricated into the entity set (the federation shape has no edge channel;
the generic diff has the same boundary).

Server exchange bound (requirement 6)
-------------------------------------
``_talk_to_server`` runs the ENTIRE §39 exchange (spawn, request write,
response reads, exit wait) in a worker thread covered by one wall-clock
``server_timeout`` (default 30s).  A hung server is killed and the call
returns degraded within the bound — never an unbounded scan.

Corruption policy (requirement 7)
---------------------------------
* unknown FUTURE row tags are skipped and recorded in ``parse_notes``;
* a malformed row of a KNOWN family (missing/wrong-typed field, malformed
  digest, out-of-vocabulary word) invalidates THAT FAMILY: its capability
  becomes ``unavailable`` (never ``complete``), ``parse_notes`` explain it,
  and the family's projections are dropped;
* an unparseable line, a non-object row, a row without a tag, a missing/
  duplicate/malformed header, a wrong ``v``/``format``, or a malformed
  ``dep-completeness`` record rejects the WHOLE artifact (degraded; no
  entities from it).

Degradation is first-class: a missing binary, a compile failure, an absent
artifact or a protocol mismatch yields ``unavailable`` capabilities, an
empty snapshot, a note and a recorded evidence entry — ``snapshot()`` never
raises for these expected states and NEVER fabricates data.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import tempfile
import threading
from dataclasses import dataclass, field
from pathlib import Path

from system_intel import extract_core
from system_intel.providers.base import (
    ProviderCapability,
    ProviderEntity,
    ProviderEvidence,
    ProviderFact,
    ProviderRelation,
    ProviderSnapshot,
    ProviderUnresolved,
    normalize_verdict,
    worst_verdict,
)
from system_intel.providers.generic_static import _snapshot_delta

PROVIDER_ID = "tangerine-native"
PROVIDER_VERSION = "1.1"

NATIVE_COMPILER_ENV = "TANGERINE_NATIVE_COMPILER"
NATIVE_SNAPSHOT_ENV = "TANGERINE_NATIVE_SNAPSHOT"

# §39 framing constants (semantic_server.tg:379-381).
PROTOCOL_VERSION = 1
MAX_FRAME_BYTES = 16 * 1024 * 1024
MAX_FIELD_BYTES = 1024 * 1024
MAX_KEYS = 65536

SERVER_TIMEOUT_S = 30.0
COMPILE_TIMEOUT_S = 600.0

# The release compiler: `build/tg`, the full driver the bootstrap lane
# materializes (run_bootstrap.sh "Full Toolchain Materialization Complete").
# `build/bootstrap/tg` is a ladder/kernel stage and is never consulted.
DEFAULT_BINARY = "build/tg"

_ENTRY_CANDIDATES = (
    "tg_compiler/bootstrap_main.tg",
    "tg_compiler/main.tg",
    "main.tg",
    "src/main.tg",
)

_ALL_FAMILIES = (
    "entities", "relations", "facts", "calls", "tests", "contracts",
    "ownership", "invariants", "runtime", "history",
)

_CAPABILITY_NOTES = {
    "entities": (
        "native symbol/type declarations + typed member tables "
        "(field/variant/signature/trait-method) + ABI surfaces, from "
        "finalized type state"
    ),
    "relations": (
        "native call edges + the typed dependency families (type-use, trait "
        "impl/select, generic inst, layout, const-eval, derived-body, ABI, "
        "contract refs); mirrors the native family verdicts"
    ),
    "facts": (
        "effect/capability/ownership/MIR-summary/resource/unsafe/drop/DMA/"
        "concrete-type/coverage facts; no per-family producer status is "
        "published, so the verdict stays partial when rows exist"
    ),
    "calls": "native call edges; indirect rows stay 'unknown'",
    "tests": "native test relationships; mirrors TestReferences",
    "contracts": (
        "native contract rows + ContractReference edges; mirrors "
        "ContractReference completeness"
    ),
    "ownership": "ownership/drop-plan/DMA facts",
    "invariants": "no native invariant family is served",
    "runtime": "coverage-ingest rows only; the compile carries no runtime data",
    "history": "no history source in the native artifact",
}

# ── §30 row grammar (semantic_snapshot.tg parse loop, lines 11087-11329) ──

_ZERO_DIGEST = "0-0"

_DIGEST_RE = re.compile(r"^[0-9]+-[0-9]+$")
_ML_RE = re.compile(r"^[^|]+\|[0-9]+$")

_HEADER_FORMAT = "tg-semantic-snapshot/v1"
_HEADER_VERSION = 1

_HEADER_REQUIRED = (
    ("compiler_version", "str"), ("features", "str"), ("options", "str"),
    ("target", "str"), ("tarch", "str"), ("tcpu", "str"), ("tptr", "int"),
    ("tendian", "str"), ("tabi", "str"), ("tfloat", "str"), ("tisa", "str"),
    ("tnative", "str"), ("tident", "digest"), ("tdigest", "digest"),
    ("revision", "digest"), ("public_api_hash", "digest"),
    ("abi_hash", "digest"), ("unsafe_hash", "digest"),
)

_HEADER_OPTIONAL_DIGESTS = (
    "d_concrete_types", "d_drop_plans", "d_allocation_sites",
    "d_resource_summaries", "d_dma_ownership", "d_features",
)

_DEF_KINDS = frozenset((
    "Function", "Method", "Static", "Constant", "EnumVariant",
    "StructField", "Intrinsic", "TypeName", "Trait", "Other",
))
_TYPE_KINDS = frozenset(("Struct", "Enum", "Trait"))
_CALL_KINDS = frozenset(("Direct", "Indirect", "Intrinsic"))
_CAPABILITY_DIRS = frozenset(("Requires", "Provides"))
_CONTRACT_KINDS = frozenset(("Pre", "Post", "Invariant"))
_UNSAFE_KINDS = frozenset((
    "unsafe-block", "unsafe-fn", "raw-deref", "raw-pointer-cast",
    "transmute", "unchecked-index", "extern-call", "inline-asm",
    "volatile-raw-access", "unsafe-trait-impl", "unknown-call",
))
_DMA_STATES = frozenset((
    "not-pinned", "pinned-read", "pinned-write", "pinned-readwrite",
    "returns",
))
_PROOF_LEVELS = frozenset((
    "static-proof", "static-bound", "runtime-measured", "unavailable",
))
_ALLOC_SIZE_KINDS = frozenset(("Exact", "UpperBound", "Unbounded", "Unknown"))
_DEP_STATUSES = frozenset(("complete", "partial", "unavailable"))

# tag -> (required fields {name: kind}, optional fields {name: kind})
# kinds: str | int | bool | digest | ml
_ROW_SCHEMAS = {
    "symbol": (
        {"i": "digest", "key": "str", "kind": "str", "name": "str",
         "module": "str", "pub": "bool", "generic": "bool"}, {},
    ),
    "type": (
        {"i": "digest", "key": "str", "tkind": "str", "name": "str",
         "module": "str", "generic_arity": "int", "pub": "bool"}, {},
    ),
    "call": ({"from": "digest", "to": "digest", "ekind": "str"}, {}),
    "indirect": (
        {"caller": "str", "site": "str", "sig": "str", "candidates": "str",
         "completeness": "str"}, {},
    ),
    "effect": (
        {"f": "digest", "flags": "int", "caps": "str", "purity": "str",
         "pevidence": "str"}, {},
    ),
    "capability": ({"f": "digest", "cap": "int", "dir": "str"}, {}),
    "ownership": ({"f": "digest", "place": "str", "conv": "int"}, {}),
    "contract": (
        {"i": "digest", "f": "digest", "ckind": "str", "text": "str",
         "fp": "digest", "msg": "str"}, {},
    ),
    "test": (
        {"test": "digest", "target": "digest"},
        {"tkey": "str", "tkind": "str", "tname": "str", "tattrs": "str"},
    ),
    "coverage": (
        {"f": "digest", "branch": "str", "arm": "str", "kind": "str",
         "test": "str"}, {},
    ),
    "mir": (
        {"f": "digest", "blocks": "int", "statements": "int", "locals": "int",
         "reachable": "bool", "unsafe": "bool", "unknown": "bool",
         "flags": "int", "caps": "str", "purity": "str", "pevidence": "str"},
        {},
    ),
    "unsafe-fact": ({"i": "digest", "f": "str", "ukind": "str", "site": "str"}, {}),
    "drop-plan": (
        {"f": "str", "place": "str", "site": "str", "paths": "str",
         "kind": "str"}, {},
    ),
    "dma": (
        {"f": "str", "place": "str", "state": "str", "op": "str",
         "site": "str"}, {"pid": "digest"},
    ),
    "concrete-type": (
        {"i": "str", "template": "str", "args": "str", "size": "int",
         "align": "int", "status": "str", "fields": "str"}, {},
    ),
    "alloc-site": ({"f": "str", "site": "str", "kind": "str", "size": "int"}, {}),
    "alloc-summary": (
        {"f": "str", "dynamic": "int", "arena": "int", "sites": "int",
         "usites": "str", "blevel": "str", "alevel": "str", "slevel": "str"},
        {},
    ),
    "stack-summary": (
        {"f": "str", "frame": "int", "max": "int", "recursive": "bool",
         "flevel": "str", "mlevel": "str"}, {},
    ),
    "blocking-summary": (
        {"f": "str", "blocking": "bool", "bsites": "str", "unbounded": "bool",
         "level": "str"}, {},
    ),
    "code-size-summary": (
        {"f": "str", "bytes": "int", "exact": "bool", "level": "str"}, {},
    ),
    "field": (
        {"o": "digest", "name": "str", "index": "int", "ty": "str",
         "member": "str", "pub": "bool"}, {"ml": "ml"},
    ),
    "variant": (
        {"o": "digest", "name": "str", "index": "int", "payload": "str",
         "member": "str"}, {"ml": "ml"},
    ),
    "signature": (
        {"f": "digest", "params": "str", "ret": "str", "effects": "str",
         "variadic": "bool"}, {},
    ),
    "trait-method": (
        {"o": "digest", "name": "str", "index": "int", "params": "str",
         "ret": "str", "member": "str"}, {"ml": "ml"},
    ),
    "abi-surface": (
        {"surface": "str", "symbol": "str", "kind": "str", "size": "int",
         "align": "int", "args": "str", "ret": "str", "fields": "str",
         "conv": "str", "extern": "str", "pclasses": "str", "plocs": "str",
         "ownin": "str", "ownout": "str", "null": "str", "variadic": "bool",
         "ext": "str", "platform": "str", "failure": "str", "thread": "str",
         "taint": "str", "boundary": "str"}, {},
    ),
    "dep-type-use": ({"user": "str", "used": "str"}, {}),
    "dep-trait-impl": ({"impl": "str", "trait": "str", "self": "str"}, {}),
    "dep-trait-select": ({"fn": "str", "trait": "str", "impl": "str"}, {}),
    "dep-generic-inst": ({"instance": "str", "template": "str"}, {}),
    "dep-layout": ({"dependent": "str", "source": "str"}, {}),
    "dep-const-eval": ({"dependent": "str", "const": "str"}, {}),
    "dep-derived-body": ({"derived": "str", "source": "str"}, {}),
    "dep-contract-ref": ({"contract": "str", "symbol": "str"}, {}),
    "dep-abi": ({"surface": "str", "type": "str"}, {}),
}

_KNOWN_TAGS = frozenset(set(_ROW_SCHEMAS) | {"header", "dep-completeness"})

_WORD_VOCAB = {
    "symbol": {"kind": _DEF_KINDS},
    "type": {"tkind": _TYPE_KINDS},
    "call": {"ekind": _CALL_KINDS},
    "capability": {"dir": _CAPABILITY_DIRS},
    "contract": {"ckind": _CONTRACT_KINDS},
    "unsafe-fact": {"ukind": _UNSAFE_KINDS},
    "dma": {"state": _DMA_STATES},
    "alloc-site": {"kind": _ALLOC_SIZE_KINDS},
    "alloc-summary": {"blevel": _PROOF_LEVELS, "alevel": _PROOF_LEVELS,
                      "slevel": _PROOF_LEVELS},
    "stack-summary": {"flevel": _PROOF_LEVELS, "mlevel": _PROOF_LEVELS},
    "blocking-summary": {"level": _PROOF_LEVELS},
    "code-size-summary": {"level": _PROOF_LEVELS},
}

_INT_RANGE = {
    "ownership": {"conv": (0, 3)},
    "effect": {"flags": (0, 127)},
    "mir": {"flags": (0, 127)},
}

# Row-tag -> capability families whose verdict the family feeds.  A malformed
# row of the tag invalidates every listed capability.
_TAG_CAPABILITY = {
    "symbol": ("entities",),
    "type": ("entities",),
    "field": ("entities",),
    "variant": ("entities",),
    "signature": ("entities",),
    "trait-method": ("entities",),
    "abi-surface": ("entities",),
    "call": ("calls", "relations"),
    "indirect": ("calls",),
    "test": ("tests",),
    "contract": ("contracts",),
    "dep-contract-ref": ("contracts", "relations"),
    "effect": ("facts",),
    "capability": ("facts",),
    "ownership": ("facts", "ownership"),
    "coverage": ("facts", "runtime"),
    "mir": ("facts",),
    "unsafe-fact": ("facts",),
    "drop-plan": ("facts", "ownership"),
    "dma": ("facts", "ownership"),
    "concrete-type": ("facts",),
    "alloc-site": ("facts",),
    "alloc-summary": ("facts",),
    "stack-summary": ("facts",),
    "blocking-summary": ("facts",),
    "code-size-summary": ("facts",),
    "dep-type-use": ("relations",),
    "dep-trait-impl": ("relations",),
    "dep-trait-select": ("relations",),
    "dep-generic-inst": ("relations",),
    "dep-layout": ("relations",),
    "dep-const-eval": ("relations",),
    "dep-derived-body": ("relations",),
    "dep-abi": ("relations",),
}

_ENTITY_TAGS = ("symbol", "type", "field", "variant", "signature",
                "trait-method", "abi-surface")
_CALL_TAGS = ("call", "indirect")
_TEST_TAGS = ("test",)
_CONTRACT_TAGS = ("contract", "dep-contract-ref")
_FACT_TAGS = (
    "effect", "capability", "ownership", "coverage", "mir", "unsafe-fact",
    "drop-plan", "dma", "concrete-type", "alloc-site", "alloc-summary",
    "stack-summary", "blocking-summary", "code-size-summary",
)
_OWNERSHIP_TAGS = ("ownership", "drop-plan", "dma")
_RUNTIME_TAGS = ("coverage",)
_RELATION_TAGS = (
    "call", "dep-type-use", "dep-trait-impl", "dep-trait-select",
    "dep-generic-inst", "dep-layout", "dep-const-eval", "dep-derived-body",
    "dep-contract-ref", "dep-abi",
)
_MEMBER_TAGS = ("field", "variant", "signature", "trait-method")

# The producer's canonical dependency-family names (semantic_snapshot.tg:5892).
_DEP_FAMILY_BY_TAG = {
    "dep-type-use": "TypeUse",
    "dep-trait-impl": "TraitImpl",
    "dep-trait-select": "TraitSelection",
    "dep-generic-inst": "GenericInstantiation",
    "dep-layout": "LayoutDependency",
    "dep-const-eval": "ConstEvalDependency",
    "dep-derived-body": "DerivedBody",
    "dep-abi": "AbiDependency",
}


class NativeProtocolError(ValueError):
    """A §39 framing/parse violation (fail closed)."""


# ── §39 framing ──────────────────────────────────────────────────────────


def _pack_text(text) -> bytes:
    payload = str(text).encode("utf-8")
    return struct.pack(">I", len(payload)) + payload


def frame_request(protocol_version, request_id, operation, payload) -> bytes:
    """Encode one §39 request frame: 4-byte BE length + length-prefixed fields."""
    body = (
        _pack_text(protocol_version)
        + _pack_text(request_id)
        + _pack_text(operation)
        + _pack_text(payload)
    )
    return struct.pack(">I", len(body)) + body


def _read_exact(stream, size: int) -> bytes | None:
    if size < 0:
        return None
    chunks = []
    remaining = size
    while remaining > 0:
        chunk = stream.read(remaining)
        if not chunk:
            return None
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_frame(stream) -> bytes | None:
    """Read one frame body from ``stream``; None on clean EOF; fail closed."""
    header = _read_exact(stream, 4)
    if header is None:
        return None
    (length,) = struct.unpack(">I", header)
    if length > MAX_FRAME_BYTES:
        raise NativeProtocolError(f"frame length {length} exceeds MAX_FRAME_BYTES")
    body = _read_exact(stream, length)
    if body is None:
        raise NativeProtocolError("truncated frame body")
    return body


def _read_text(body: bytes, at: int) -> tuple[str, int]:
    if at + 4 > len(body):
        raise NativeProtocolError("truncated field length")
    (length,) = struct.unpack(">I", body[at:at + 4])
    at += 4
    if length > MAX_FIELD_BYTES:
        raise NativeProtocolError(f"field length {length} exceeds MAX_FIELD_BYTES")
    if at + length > len(body):
        raise NativeProtocolError("truncated field text")
    try:
        text = body[at:at + length].decode("utf-8")
    except UnicodeDecodeError as exc:  # fail closed like the native parser
        raise NativeProtocolError(f"non-UTF-8 field: {exc}") from exc
    return text, at + length


def parse_response_body(body: bytes) -> dict:
    """Strict §39 response parser (the inverse of ``semantic_response_frame``).

    Fields in order: protocol_version, request_id, ok ("true"/"false"), kind,
    keys-count, keys..., error.  Any framing/length/numeric disagreement or
    trailing bytes fails closed with :class:`NativeProtocolError`.
    """
    at = 0
    pv_text, at = _read_text(body, at)
    rid_text, at = _read_text(body, at)
    ok_text, at = _read_text(body, at)
    kind, at = _read_text(body, at)
    count_text, at = _read_text(body, at)
    try:
        protocol_version = int(pv_text)
        request_id = int(rid_text)
        count = int(count_text)
    except ValueError as exc:
        raise NativeProtocolError("non-numeric protocol/request/count field") from exc
    if ok_text not in ("true", "false"):
        raise NativeProtocolError(f"invalid ok word {ok_text!r}")
    if count < 0 or count > MAX_KEYS:
        raise NativeProtocolError(f"keys count {count} out of range")
    keys = []
    for _ in range(count):
        key, at = _read_text(body, at)
        keys.append(key)
    error, at = _read_text(body, at)
    if at != len(body):
        raise NativeProtocolError("trailing bytes inside response body")
    return {
        "protocol_version": protocol_version,
        "request_id": request_id,
        "ok": ok_text == "true",
        "kind": kind,
        "keys": keys,
        "error": error,
    }


# ── §30 artifact ─────────────────────────────────────────────────────────


def _is_digest(value) -> bool:
    return isinstance(value, str) and bool(_DIGEST_RE.match(value))


def _field_ok(value, kind: str) -> bool:
    if kind == "str":
        return isinstance(value, str)
    if kind == "int":
        return isinstance(value, int) and not isinstance(value, bool)
    if kind == "bool":
        return isinstance(value, bool)
    if kind == "digest":
        return _is_digest(value)
    if kind == "ml":
        return isinstance(value, str) and (
            value == "" or bool(_ML_RE.match(value))
        )
    return False


def _header_error(row: dict) -> str:
    """Return a rejection reason for a malformed header row, else ''."""
    version = row.get("v")
    if not _field_ok(version, "int") or version != _HEADER_VERSION:
        return (
            f"unsupported or missing snapshot version {version!r} "
            f"(expected {_HEADER_VERSION})"
        )
    if row.get("format") != _HEADER_FORMAT:
        return f"unsupported snapshot format {row.get('format')!r}"
    for key, kind in _HEADER_REQUIRED:
        if not _field_ok(row.get(key), kind):
            return f"header field {key!r} missing or malformed"
    for key in _HEADER_OPTIONAL_DIGESTS:
        value = row.get(key)
        if value in (None, ""):
            continue
        if not _is_digest(value):
            return f"header optional digest {key!r} malformed"
    return ""


def _row_error(tag: str, row: dict) -> str:
    """Return a family-invalidating reason for a known-schema row, else ''."""
    required, optional = _ROW_SCHEMAS[tag]
    for key, kind in required.items():
        if key not in row:
            return f"missing required field {key!r}"
        if not _field_ok(row.get(key), kind):
            return f"malformed field {key!r}"
    for key, kind in optional.items():
        if key in row and not _field_ok(row.get(key), kind):
            return f"malformed optional field {key!r}"
    for key, allowed in _WORD_VOCAB.get(tag, {}).items():
        if row.get(key) not in allowed:
            return f"unknown {key} word {row.get(key)!r}"
    for key, (low, high) in _INT_RANGE.get(tag, {}).items():
        value = row.get(key)
        if not isinstance(value, int) or isinstance(value, bool):
            return f"field {key!r} is not an integer"
        if value < low or value > high:
            return f"field {key!r} out of range [{low}, {high}]"
    return ""


def _dep_completeness_error(row: dict) -> str:
    family = row.get("family")
    status = row.get("status")
    if not isinstance(family, str) or not family:
        return "family must be a non-empty string"
    if status not in _DEP_STATUSES:
        return f"invalid completeness status {status!r}"
    return ""


@dataclass
class NativeArtifact:
    """Parsed ``tg-semantic-snapshot/v1`` artifact (semantic_snapshot.tg).

    ``rejected`` artifacts are integrity failures (bad header/version/format,
    unparseable lines, a malformed ``dep-completeness`` record): they carry no
    trustworthy projections at all.  ``invalid_families`` lists known row tags
    whose rows were malformed: each tag's capability is ``unavailable`` and
    its projections are dropped, while the rest of the artifact stays usable.
    """

    path: str
    sha256: str
    header: dict = field(default_factory=dict)
    rows: dict[str, list[dict]] = field(default_factory=dict)
    dependency_completeness: dict[str, str] = field(default_factory=dict)
    digest_to_key: dict[str, str] = field(default_factory=dict)
    key_to_digest: dict[str, str] = field(default_factory=dict)
    parse_notes: list[str] = field(default_factory=list)
    invalid_families: set[str] = field(default_factory=set)
    rejected: bool = False
    reject_reason: str = ""

    @property
    def accepted(self) -> bool:
        return not self.rejected

    @property
    def revision(self) -> str:
        return str(self.header.get("revision", "") or "")

    @property
    def compiler_version(self) -> str:
        return str(self.header.get("compiler_version", "") or "")

    @property
    def surface_hashes(self) -> dict:
        out = {}
        for field_name in ("public_api_hash", "abi_hash", "unsafe_hash"):
            value = self.header.get(field_name)
            if value:
                out[field_name] = str(value)
        return out

    @property
    def semantic_configuration(self) -> dict:
        header = self.header
        conf: dict = {}
        for source, name in (
            ("target", "target"), ("tarch", "arch"), ("tcpu", "cpu"),
            ("tptr", "pointer_width"), ("tendian", "endian"),
            ("tabi", "abi"), ("tfloat", "float_abi"),
        ):
            value = header.get(source)
            if value not in (None, ""):
                conf[name] = value
        for source, name in (
            ("tisa", "isa_features"), ("features", "features"),
            ("options", "options"),
        ):
            value = header.get(source)
            if isinstance(value, str) and value:
                parts = value.split(";;") if source != "tisa" else value.split(",")
                joined = [part for part in parts if part]
                if joined:
                    conf[name] = joined
        return conf


def _parse_artifact(path) -> NativeArtifact | None:
    """Parse a §30 artifact fail-closed; None when absent/empty/unreadable.

    Unknown FUTURE row tags are skipped (recorded in ``parse_notes``).  A
    malformed row of a known family invalidates that family; a malformed/
    missing header, an unparseable line, a tag-less row, or a malformed
    ``dep-completeness`` record rejects the whole artifact.
    """
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError:
        return None
    if not text.strip():
        return None
    artifact = NativeArtifact(
        path=str(path), sha256=hashlib.sha256(text.encode("utf-8")).hexdigest()
    )

    def reject(reason: str) -> NativeArtifact:
        artifact.rejected = True
        artifact.reject_reason = reason
        artifact.parse_notes.append(reason)
        return artifact

    header_seen = False
    for line_no, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            return reject(f"line {line_no}: unparseable JSON row")
        if not isinstance(row, dict):
            return reject(f"line {line_no}: non-object row")
        tag = row.get("s")
        if not isinstance(tag, str) or not tag:
            return reject(f"line {line_no}: row without a tag")
        if tag == "header":
            if header_seen:
                return reject(f"line {line_no}: duplicate header row")
            reason = _header_error(row)
            if reason:
                return reject(f"line {line_no}: malformed header ({reason})")
            artifact.header = row
            header_seen = True
            continue
        if not header_seen:
            return reject(
                f"line {line_no}: row {tag!r} appears before the header row"
            )
        if tag not in _KNOWN_TAGS:
            if len(artifact.parse_notes) < 50:
                artifact.parse_notes.append(
                    f"line {line_no}: unknown future row tag {tag!r} skipped"
                )
            continue
        if tag == "dep-completeness":
            reason = _dep_completeness_error(row)
            if reason:
                return reject(
                    f"line {line_no}: malformed dep-completeness row ({reason})"
                )
            artifact.dependency_completeness[str(row["family"])] = normalize_verdict(
                row["status"], default="unknown"
            )
            continue
        reason = _row_error(tag, row)
        if reason:
            artifact.invalid_families.add(tag)
            if len(artifact.parse_notes) < 50:
                artifact.parse_notes.append(
                    f"line {line_no}: malformed {tag} row ({reason}); "
                    "family invalidated"
                )
            continue
        artifact.rows.setdefault(tag, []).append(row)
    if not header_seen:
        return reject("missing header row (headerless artifact)")
    for tag in ("symbol", "type"):
        for row in artifact.rows.get(tag, []):
            digest = str(row.get("i", "") or "")
            key = str(row.get("key", "") or "")
            if digest and key:
                artifact.digest_to_key.setdefault(digest, key)
                artifact.key_to_digest.setdefault(key, digest)
    return artifact


@dataclass
class _ServerSession:
    binary: str
    responses: dict[str, dict] = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)
    counts: dict[str, int] = field(default_factory=dict)
    timed_out: bool = False

    def responded(self) -> bool:
        return bool(self.responses)


def _parse_counts(response: dict | None) -> dict[str, int]:
    counts: dict[str, int] = {}
    if not response:
        return counts
    for row in response.get("keys", []):
        if not str(row).startswith("rows:"):
            continue
        parts = str(row).split(":", 2)
        if len(parts) != 3:
            continue
        try:
            counts[parts[1]] = int(parts[2])
        except ValueError:
            continue
    return counts


# ── provider ─────────────────────────────────────────────────────────────


class TangerineNativeProvider:
    """§5 provider fronting the native compiler's §30 artifact + §39 server."""

    provider_id = PROVIDER_ID
    provider_version = PROVIDER_VERSION
    authority = 0  # lower number = higher authority (native is authoritative)

    def __init__(self, binary=None, artifact=None, server_timeout=None) -> None:
        self._binary_override = str(binary) if binary else None
        self._artifact_override = str(artifact) if artifact else None
        self._server_timeout = (
            float(server_timeout) if server_timeout else SERVER_TIMEOUT_S
        )
        self._completeness = {family: "unknown" for family in _ALL_FAMILIES}
        self._invalid_families: set[str] = set()
        self._degrade_note = ""
        self._last_snapshot: ProviderSnapshot | None = None
        self._last_artifact: NativeArtifact | None = None
        self._last_server: _ServerSession | None = None
        # Accepted artifacts parsed by THIS instance, for the native delta.
        self._native_by_digest: dict[str, NativeArtifact] = {}
        self._native_by_revision: dict[str, NativeArtifact] = {}

    # ------------------------------------------------------------ discovery

    def applies_to(self, root) -> bool:
        if (
            self._artifact_override
            or self._binary_override
            or os.environ.get(NATIVE_SNAPSHOT_ENV)
            or os.environ.get(NATIVE_COMPILER_ENV)
        ):
            return True
        root_path = Path(root).expanduser()
        if not root_path.is_dir():
            return False
        seen = 0
        for dirpath, dirnames, filenames in os.walk(root_path):
            dirnames[:] = sorted(
                d for d in dirnames if d not in extract_core.SKIP_DIRS
            )
            for name in filenames:
                seen += 1
                if name.endswith(".tg"):
                    return True
                if seen > 50000:
                    return False
        return False

    def _locate_binary(self, root: Path) -> Path | None:
        if self._binary_override:
            return Path(self._binary_override)
        env = os.environ.get(NATIVE_COMPILER_ENV)
        if env:
            return Path(env)
        repo_root = Path(__file__).resolve().parents[2]
        for candidate in (
            root / DEFAULT_BINARY,
            repo_root / DEFAULT_BINARY,
        ):
            if candidate.is_file():
                return candidate
        return None

    def _locate_artifact(self, root: Path) -> Path | None:
        if self._artifact_override:
            return Path(self._artifact_override)
        env = os.environ.get(NATIVE_SNAPSHOT_ENV)
        if env:
            return Path(env)
        return None

    @staticmethod
    def _find_entry(root: Path) -> Path | None:
        for rel in _ENTRY_CANDIDATES:
            candidate = root / rel
            if candidate.is_file():
                return candidate
        return None

    # ------------------------------------------------------------ SPI

    def identity(self, root) -> dict:
        root_path = Path(root).expanduser()
        identity = {
            "repo_root": str(root_path),
            "source_revision": "",
            "tree_digest": "",
            "semantic_configuration": "{}",
            "revision_digest": "",
            "provider": self.provider_id,
            "provider_version": self.provider_version,
            "artifact": "",
            "surface_hashes": {},
            "compiler_version": "",
        }
        artifact_path = self._locate_artifact(root_path)
        if artifact_path is None or not Path(artifact_path).is_file():
            return identity
        artifact = _parse_artifact(artifact_path)
        if artifact is None or artifact.rejected:
            return identity
        config = artifact.semantic_configuration
        identity.update({
            "source_revision": artifact.revision,
            "revision_digest": artifact.revision,
            "semantic_configuration": (
                json.dumps(config, sort_keys=True, separators=(",", ":"))
                if config else "{}"
            ),
            "artifact": str(artifact_path),
            "surface_hashes": artifact.surface_hashes,
            "compiler_version": artifact.compiler_version,
        })
        return identity

    def _capability_note(self, family: str) -> str:
        note = _CAPABILITY_NOTES.get(family, "")
        invalid = sorted(
            tag for tag in self._invalid_families
            if family in _TAG_CAPABILITY.get(tag, ())
        )
        if invalid:
            note = (
                f"{note}; corrupted native row family(ies) "
                f"{', '.join(invalid)}: capability unavailable"
            ).strip("; ")
        if self._degrade_note:
            note = f"{note}; {self._degrade_note}" if note else self._degrade_note
        return note

    def capabilities(self) -> list[ProviderCapability]:
        return [
            ProviderCapability(
                family, self._completeness.get(family, "unknown"),
                self._capability_note(family),
            )
            for family in _ALL_FAMILIES
        ]

    def completeness(self, family: str) -> str:
        return normalize_verdict(self._completeness.get(str(family), "unknown"))

    def snapshot(self, root, *, commit_sha: str | None = None) -> ProviderSnapshot:
        root_path = Path(root).expanduser()
        notes: list[str] = []
        tmpdir: Path | None = None
        try:
            binary = self._locate_binary(root_path)
            artifact_path = self._locate_artifact(root_path)

            if artifact_path is None and binary is not None and binary.is_file():
                entry = self._find_entry(root_path)
                if entry is not None:
                    artifact_path, tmpdir, compile_notes = self._compile_artifact(
                        root_path, binary, entry
                    )
                    notes.extend(compile_notes)

            artifact: NativeArtifact | None = None
            if artifact_path is not None:
                if Path(artifact_path).is_file():
                    artifact = _parse_artifact(artifact_path)
                    if artifact is None:
                        notes.append(
                            f"native artifact {artifact_path} is empty or unreadable"
                        )
                    elif artifact.rejected:
                        notes.append(
                            f"native artifact {artifact_path} rejected: "
                            f"{artifact.reject_reason}"
                        )
                    else:
                        notes.extend(
                            f"native artifact: {note}"
                            for note in artifact.parse_notes
                        )
                        self._register_artifact(artifact)
                else:
                    notes.append(f"native artifact {artifact_path} does not exist")

            usable_artifact = artifact if (
                artifact is not None and not artifact.rejected
            ) else None
            invalid_families = (
                set(artifact.invalid_families) if usable_artifact else set()
            )

            server: _ServerSession | None = None
            if binary is not None and binary.is_file():
                server = self._talk_to_server(
                    root_path, binary,
                    Path(artifact_path) if usable_artifact else None,
                )
                notes.extend(server.notes)
            elif binary is None:
                repo_root = Path(__file__).resolve().parents[2]
                notes.append(
                    f"native compiler not found (env {NATIVE_COMPILER_ENV}, "
                    f"{root_path / DEFAULT_BINARY}, or "
                    f"{repo_root / DEFAULT_BINARY})"
                )
            else:
                notes.append(f"native compiler {binary} is not a file")

            if usable_artifact is None and (server is None or not server.responded()):
                return self._degraded(root_path, notes, artifact=artifact,
                                      server=server)

            entities: list[ProviderEntity] = []
            relations: list[ProviderRelation] = []
            facts: list[ProviderFact] = []
            unresolved: list[ProviderUnresolved] = []
            if usable_artifact is not None:
                self._project_artifact(
                    usable_artifact, root_path, entities, relations, facts,
                    unresolved, notes,
                )
            if server is not None and server.responded():
                self._project_server(
                    server, usable_artifact is not None, entities, facts, notes
                )

            completeness = self._mirror_completeness(usable_artifact, server)
            self._invalid_families = invalid_families
            capabilities = [
                ProviderCapability(
                    family, completeness.get(family, "unknown"),
                    self._capability_note(family),
                )
                for family in _ALL_FAMILIES
            ]
            evidence: list[ProviderEvidence] = []
            if artifact is not None:
                evidence.append(ProviderEvidence(
                    kind="native_snapshot_artifact",
                    ref=artifact.path,
                    digest=artifact.sha256,
                    summary=(
                        "Tangerine §30 semantic snapshot artifact "
                        f"(revision {artifact.revision or 'unknown'})"
                        + (" [REJECTED]" if artifact.rejected else "")
                    ),
                    payload={
                        "revision": artifact.revision,
                        "compiler_version": artifact.compiler_version,
                        "surface_hashes": artifact.surface_hashes,
                        "dependency_completeness": artifact.dependency_completeness,
                        "parse_notes": artifact.parse_notes,
                        "invalid_families": sorted(artifact.invalid_families),
                        "rejected": artifact.rejected,
                        "reject_reason": artifact.reject_reason,
                    },
                    provider=self.provider_id,
                ))
            if server is not None and server.responded():
                evidence.append(ProviderEvidence(
                    kind="native_server",
                    ref=server.binary,
                    summary=(
                        "Tangerine §39 semantic server session: "
                        + ", ".join(sorted(server.responses))
                    ),
                    payload={
                        "protocol_version": PROTOCOL_VERSION,
                        "kinds": {
                            op: resp.get("kind", "")
                            for op, resp in sorted(server.responses.items())
                        },
                        "counts": server.counts,
                        "timed_out": server.timed_out,
                        "revision": next(
                            (resp["keys"][0]
                             for op, resp in server.responses.items()
                             if resp.get("kind") == "revision" and resp.get("keys")),
                            "",
                        ),
                        "notes": server.notes,
                    },
                    provider=self.provider_id,
                ))
            for note in notes:
                evidence.append(ProviderEvidence(
                    kind="provider_note",
                    ref=str(root_path),
                    summary=note,
                    provider=self.provider_id,
                ))

            capabilities_dict = {
                cap.family: cap.verdict for cap in capabilities
            }
            snap = ProviderSnapshot(
                entities=entities,
                relations=relations,
                facts=facts,
                unresolved=unresolved,
                evidence=evidence,
                providers=[{
                    "provider_id": self.provider_id,
                    "provider_version": self.provider_version,
                    "capabilities": capabilities_dict,
                    "invoked": True,
                }],
                semantic_configuration=(
                    usable_artifact.semantic_configuration
                    if usable_artifact else {}
                ),
                provider_id=self.provider_id,
                provider_version=self.provider_version,
                capabilities=capabilities,
            )
            self._completeness = completeness
            self._degrade_note = ""
            self._last_snapshot = snap
            self._last_artifact = usable_artifact
            self._last_server = server
            return snap
        except Exception as exc:  # noqa: BLE001 - degrade, never crash a scan
            return self._degraded(
                root_path,
                notes + [
                    f"native provider error: {exc.__class__.__name__}: {exc}"
                ],
            )
        finally:
            if tmpdir is not None:
                shutil.rmtree(tmpdir, ignore_errors=True)

    def query(self, snapshot: ProviderSnapshot, operation: str, **kwargs) -> dict:
        op = str(operation)
        if op in ("entity", "entity.get", "symbol.get", "symbol_get"):
            key = kwargs.get("stable_id") or kwargs.get("key") or kwargs.get("qualified_name")
            records = [
                ent for ent in snapshot.entities
                if key and (
                    ent.stable_id == key
                    or ent.qualified_name == key
                    or ent.name == key
                )
            ]
            return {
                "kind": "entity.get",
                "records": records,
                "completeness": snapshot.completeness("entities"),
            }
        if op == "entities":
            kind = kwargs.get("kind")
            records = [ent for ent in snapshot.entities
                       if kind is None or ent.kind == kind]
            return {
                "kind": "entities",
                "records": records,
                "completeness": snapshot.completeness("entities"),
            }
        if op in ("search", "symbol_search"):
            needle = str(kwargs.get("query") or kwargs.get("needle") or "")
            records = [
                ent for ent in snapshot.entities
                if not needle or needle in ent.name or needle in ent.qualified_name
            ]
            return {
                "kind": "search",
                "records": records,
                "completeness": snapshot.completeness("entities"),
            }
        if op in ("relations", "edges"):
            kind = kwargs.get("kind")
            records = [rel for rel in snapshot.relations
                       if kind is None or rel.kind == kind]
            return {
                "kind": "relations",
                "records": records,
                "completeness": snapshot.completeness("relations"),
            }
        if op == "unresolved":
            kind = kwargs.get("kind")
            records = [edge for edge in snapshot.unresolved
                       if kind is None or edge.kind == kind]
            return {
                "kind": "unresolved",
                "records": records,
                "completeness": snapshot.completeness("relations"),
            }
        if self._last_server and op in self._last_server.responses:
            resp = self._last_server.responses[op]
            return {
                "kind": str(resp.get("kind", op)),
                "keys": list(resp.get("keys", [])),
                "records": [],
                "ok": bool(resp.get("ok", False)),
                "error": str(resp.get("error", "")),
                "source": "native-server",
            }
        return {
            "kind": f"{op}_unavailable",
            "records": [],
            "keys": [],
            "note": f"tangerine-native does not answer {op!r} without a session",
            "completeness": "unavailable",
        }

    # ------------------------------------------------------------ delta

    def _register_artifact(self, artifact: NativeArtifact) -> None:
        if not artifact.accepted:
            return
        self._native_by_digest[artifact.sha256] = artifact
        if artifact.revision:
            self._native_by_revision[artifact.revision] = artifact

    def _artifact_for_snapshot(
        self, snapshot: ProviderSnapshot
    ) -> NativeArtifact | None:
        for ev in snapshot.evidence:
            if ev.kind != "native_snapshot_artifact":
                continue
            if ev.digest and ev.digest in self._native_by_digest:
                return self._native_by_digest[ev.digest]
            payload = ev.payload if isinstance(ev.payload, dict) else {}
            revision = str(payload.get("revision", "") or "")
            if revision and revision in self._native_by_revision:
                return self._native_by_revision[revision]
        return None

    def delta(self, old_snapshot: ProviderSnapshot,
              new_snapshot: ProviderSnapshot) -> dict:
        """Set diff of two snapshots, preferring the NATIVE artifact delta.

        The native §31 pair delta is not serialized by the artifact and the
        §39 server answers ``snapshot.diff_unavailable`` for its single
        snapshot, so the native translation is the identity diff over the two
        §30 artifacts THIS provider parsed (declarations/tests/contracts by
        persistent digest + indirect unresolved additions).  When either
        artifact is unavailable the generic ``_snapshot_delta`` is used; the
        returned dict records ``source`` ('native'|'generic') and a ``note``.
        """
        old_artifact = self._artifact_for_snapshot(old_snapshot)
        new_artifact = self._artifact_for_snapshot(new_snapshot)
        if old_artifact is not None and new_artifact is not None:
            translated = _native_artifact_delta(old_artifact, new_artifact)
            translated["source"] = "native"
            translated["note"] = (
                "native §30 artifact delta over persistent-digest identities "
                "(declarations, tests, contracts) + indirect unresolved "
                "additions"
            )
            return translated
        generic = _snapshot_delta(old_snapshot, new_snapshot)
        generic["source"] = "generic"
        generic["note"] = (
            "native artifact pair unavailable in this provider session "
            "(server-only or rejected artifact, or a different provider "
            "instance parsed the artifact); fell back to the generic "
            "snapshot diff"
        )
        return generic

    # ------------------------------------------------------------ projection

    @staticmethod
    def _decl_stable(digest, key=None) -> tuple[str, bool]:
        """Typed stable id for a persistent declaration digest.

        Returns ``(stable_id, degraded)``; a zero/absent digest degrades to
        the deterministic textual fallback (``native:sym:<key>`` when the
        textual key is known, else ``native:key:<digest>``).
        """
        text = str(digest or "")
        if text and text != _ZERO_DIGEST:
            return f"native:decl:{text}", False
        if key:
            return f"native:sym:{key}", True
        return f"native:key:{text or 'unknown'}", True

    @staticmethod
    def _key_stable(artifact: NativeArtifact, text) -> tuple[str, bool]:
        """Resolve a canonical key TEXT to a declaration digest stable id."""
        value = str(text or "")
        digest = artifact.key_to_digest.get(value)
        if digest and digest != _ZERO_DIGEST:
            return f"native:decl:{digest}", False
        return f"native:key:{value or 'unknown'}", True

    @staticmethod
    def _display_key(artifact: NativeArtifact, digest) -> str:
        text = str(digest or "")
        return artifact.digest_to_key.get(text, text)

    @staticmethod
    def _split_list(text) -> list[str]:
        value = str(text or "")
        return [part for part in value.split(";;") if part]

    def _project_artifact(self, artifact: NativeArtifact, root: Path,
                          entities: list[ProviderEntity],
                          relations: list[ProviderRelation],
                          facts: list[ProviderFact],
                          unresolved: list[ProviderUnresolved],
                          notes: list[str]) -> None:
        invalid = artifact.invalid_families
        degraded_keys = 0

        def rows(tag: str) -> list[dict]:
            if tag in invalid:
                return []
            return artifact.rows.get(tag, [])

        def attr_state(attrs: dict, degraded: bool, basis: str) -> dict:
            nonlocal degraded_keys
            if degraded:
                degraded_keys += 1
                attrs["identity_degraded"] = True
                attrs["identity_basis"] = basis
            else:
                attrs["identity_degraded"] = False
                attrs["identity_basis"] = basis
            return attrs

        facts_completeness = (
            "partial" if any(rows(tag) for tag in _FACT_TAGS) else "unknown"
        )
        member_completeness = (
            "partial" if any(rows(tag) for tag in _MEMBER_TAGS) else "unknown"
        )
        dep = artifact.dependency_completeness
        calls_completeness = normalize_verdict(dep.get("Call"), default="partial")
        tests_completeness = normalize_verdict(
            dep.get("TestReferences"), default="partial"
        )
        contracts_completeness = normalize_verdict(
            dep.get("ContractReference"), default="partial"
        )

        # ———— header: Repository/ABI surface ————
        surface_hashes = artifact.surface_hashes
        entities.append(ProviderEntity(
            kind="Repository",
            name=(root.name or "."),
            qualified_name=".",
            stable_id="repo:.",
            tier=0,
            provenance="compiler",
            derived_from=("tangerine-native:artifact-header",),
            attrs={
                "native_family": "artifact-header",
                "revision": artifact.revision,
                "compiler_version": artifact.compiler_version,
                "surface_hashes": surface_hashes,
                "semantic_configuration": artifact.semantic_configuration,
            },
            epistemic_state="observed",
            analysis_depth=2,
            completeness="complete",
            provider=self.provider_id,
            provider_revision=self.provider_version,
        ))
        if artifact.revision:
            facts.append(ProviderFact(
                subject="repo:.",
                predicate="native.revision",
                object=artifact.revision,
                stable_subject="repo:.",
                tier=0,
                provenance="compiler",
                derived_from=("tangerine-native:artifact-header",),
                attrs={"artifact": artifact.path},
                epistemic_state="observed",
                analysis_depth=2,
                completeness="complete",
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))
        for hash_name in ("public_api_hash", "abi_hash", "unsafe_hash"):
            value = surface_hashes.get(hash_name)
            if not value:
                continue
            facts.append(ProviderFact(
                subject="repo:.",
                predicate=f"native.{hash_name}",
                object=value,
                stable_subject="repo:.",
                tier=0,
                provenance="compiler",
                derived_from=("tangerine-native:artifact-header",),
                attrs={"artifact": artifact.path, "surface": "repository"},
                epistemic_state="observed",
                analysis_depth=2,
                completeness="complete",
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))

        # ———— declarations ————
        for row in rows("symbol"):
            key = str(row.get("key", "") or "")
            digest = str(row.get("i", "") or "")
            stable, degraded = self._decl_stable(digest, key)
            entities.append(ProviderEntity(
                kind="Symbol",
                name=str(row.get("name") or key or digest),
                qualified_name=key or digest,
                stable_id=stable,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:symbol",),
                attrs=attr_state({
                    "native_family": "symbol",
                    "key": key,
                    "def_kind": row.get("kind"),
                    "digest": digest,
                    "module": row.get("module"),
                    "is_pub": row.get("pub"),
                    "is_generic": row.get("generic"),
                    "raw": row,
                }, degraded,
                   "zero-digest-textual-fallback" if degraded
                   else "persistent-decl-digest"),
                epistemic_state="observed",
                analysis_depth=2,
                completeness="complete",
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))

        for row in rows("type"):
            key = str(row.get("key", "") or "")
            digest = str(row.get("i", "") or "")
            stable, degraded = self._decl_stable(digest, key)
            entities.append(ProviderEntity(
                kind="Symbol",
                name=str(row.get("name") or key or digest),
                qualified_name=key or digest,
                stable_id=stable,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:type",),
                attrs=attr_state({
                    "native_family": "type",
                    "key": key,
                    "type_kind": row.get("tkind"),
                    "digest": digest,
                    "module": row.get("module"),
                    "is_pub": row.get("pub"),
                    "generic_arity": row.get("generic_arity"),
                    "raw": row,
                }, degraded,
                   "zero-digest-textual-fallback" if degraded
                   else "persistent-decl-digest"),
                epistemic_state="observed",
                analysis_depth=2,
                completeness="complete",
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))

        # ———— calls ————
        for row in rows("call"):
            src_stable, src_degraded = self._decl_stable(row.get("from"))
            dst_stable, dst_degraded = self._decl_stable(row.get("to"))
            relations.append(ProviderRelation(
                src_key=src_stable,
                dst_key=dst_stable,
                kind="calls",
                src_kind="Symbol",
                dst_kind="Symbol",
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:call",),
                attrs={
                    "ekind": row.get("ekind"),
                    "from_digest": row.get("from"),
                    "to_digest": row.get("to"),
                    "identity_degraded": bool(src_degraded or dst_degraded),
                    "raw": row,
                },
                epistemic_state="observed",
                analysis_depth=3,
                completeness=calls_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))

        for row in rows("indirect"):
            # The native model emits EVERY indirect site with an EMPTY
            # candidate set and completeness "Unknown" (semantic_snapshot.tg:7527);
            # the provider mirrors that exactly — never a guess.
            caller = str(row.get("caller", "") or "")
            site = str(row.get("site", "") or "")
            signature = str(row.get("sig", "") or "")
            src_stable, src_degraded = self._key_stable(artifact, caller)
            unresolved.append(ProviderUnresolved(
                src_key=src_stable,
                dst_raw=signature or site,
                kind="calls",
                candidates=(),
                confidence=0.1,
                completeness="unknown",
                evidence=(f"site:{site}",) if site else (),
                attrs={
                    "caller_key": caller,
                    "call_site": site,
                    "signature": signature,
                    "native_completeness": row.get("completeness", "Unknown"),
                    "identity_degraded": src_degraded,
                    "raw": row,
                },
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))

        # ———— effects / capabilities / ownership ————
        for row in rows("effect"):
            digest = str(row.get("f", "") or "")
            key = self._display_key(artifact, digest)
            stable_subject, _ = self._decl_stable(digest)
            facts.append(ProviderFact(
                subject=key,
                predicate="effect",
                object=(
                    f"flags={row.get('flags')};purity={row.get('purity')}"
                ),
                stable_subject=stable_subject,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:effect",),
                attrs={
                    "capabilities": row.get("caps"),
                    "purity_evidence": row.get("pevidence"),
                    "function_digest": digest,
                    "raw": row,
                },
                epistemic_state="observed",
                analysis_depth=3,
                completeness=facts_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))
        for row in rows("capability"):
            digest = str(row.get("f", "") or "")
            key = self._display_key(artifact, digest)
            stable_subject, _ = self._decl_stable(digest)
            facts.append(ProviderFact(
                subject=key,
                predicate="capability",
                object=f"{row.get('dir')}:{row.get('cap')}",
                stable_subject=stable_subject,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:capability",),
                attrs={"function_digest": digest, "raw": row},
                epistemic_state="observed",
                analysis_depth=3,
                completeness=facts_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))
        for row in rows("ownership"):
            digest = str(row.get("f", "") or "")
            key = self._display_key(artifact, digest)
            stable_subject, _ = self._decl_stable(digest)
            facts.append(ProviderFact(
                subject=key,
                predicate="ownership",
                object=f"{row.get('place')}:convention={row.get('conv')}",
                stable_subject=stable_subject,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:ownership",),
                attrs={"function_digest": digest, "raw": row},
                epistemic_state="observed",
                analysis_depth=3,
                completeness=facts_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))

        # ———— typed members ————
        for row in rows("field"):
            digest = str(row.get("o", "") or "")
            key = self._display_key(artifact, digest)
            stable_subject, _ = self._decl_stable(digest)
            facts.append(ProviderFact(
                subject=key,
                predicate="member",
                object=f"field:{row.get('name')}:{row.get('ty')}",
                stable_subject=stable_subject,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:field",),
                attrs={
                    "member_kind": "field",
                    "index": row.get("index"),
                    "member": row.get("member"),
                    "member_lineage": row.get("ml"),
                    "is_pub": row.get("pub"),
                    "owner_digest": digest,
                    "raw": row,
                },
                epistemic_state="observed",
                analysis_depth=3,
                completeness=member_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))
        for row in rows("variant"):
            digest = str(row.get("o", "") or "")
            key = self._display_key(artifact, digest)
            stable_subject, _ = self._decl_stable(digest)
            facts.append(ProviderFact(
                subject=key,
                predicate="member",
                object=f"variant:{row.get('name')}({row.get('payload')})",
                stable_subject=stable_subject,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:variant",),
                attrs={
                    "member_kind": "variant",
                    "index": row.get("index"),
                    "member": row.get("member"),
                    "member_lineage": row.get("ml"),
                    "owner_digest": digest,
                    "raw": row,
                },
                epistemic_state="observed",
                analysis_depth=3,
                completeness=member_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))
        for row in rows("signature"):
            digest = str(row.get("f", "") or "")
            key = self._display_key(artifact, digest)
            stable_subject, _ = self._decl_stable(digest)
            facts.append(ProviderFact(
                subject=key,
                predicate="signature",
                object=f"({row.get('params')})->{row.get('ret')}",
                stable_subject=stable_subject,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:signature",),
                attrs={
                    "declared_effects": self._split_list(row.get("effects")),
                    "variadic": row.get("variadic"),
                    "function_digest": digest,
                    "raw": row,
                },
                epistemic_state="observed",
                analysis_depth=3,
                completeness=member_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))
        for row in rows("trait-method"):
            digest = str(row.get("o", "") or "")
            key = self._display_key(artifact, digest)
            stable_subject, _ = self._decl_stable(digest)
            facts.append(ProviderFact(
                subject=key,
                predicate="member",
                object=(
                    f"trait-method:{row.get('name')}"
                    f"({row.get('params')})->{row.get('ret')}"
                ),
                stable_subject=stable_subject,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:trait-method",),
                attrs={
                    "member_kind": "trait_method",
                    "index": row.get("index"),
                    "member": row.get("member"),
                    "member_lineage": row.get("ml"),
                    "owner_digest": digest,
                    "raw": row,
                },
                epistemic_state="observed",
                analysis_depth=3,
                completeness=member_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))

        # ———— MIR summaries ————
        for row in rows("mir"):
            digest = str(row.get("f", "") or "")
            key = self._display_key(artifact, digest)
            stable_subject, _ = self._decl_stable(digest)
            facts.append(ProviderFact(
                subject=key,
                predicate="mir",
                object=(
                    f"blocks={row.get('blocks')};statements={row.get('statements')};"
                    f"locals={row.get('locals')};reachable={row.get('reachable')};"
                    f"unsafe={row.get('unsafe')};unknown={row.get('unknown')};"
                    f"purity={row.get('purity')}"
                ),
                stable_subject=stable_subject,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:mir",),
                attrs={
                    "capabilities": row.get("caps"),
                    "purity_evidence": row.get("pevidence"),
                    "flags": row.get("flags"),
                    "function_digest": digest,
                    "raw": row,
                },
                epistemic_state="observed",
                analysis_depth=3,
                completeness=facts_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))

        # ———— concrete types (layout of generic instantiations) ————
        for row in rows("concrete-type"):
            instance = str(row.get("i", "") or "")
            facts.append(ProviderFact(
                subject=instance,
                predicate="layout",
                object=(
                    f"size={row.get('size')};align={row.get('align')};"
                    f"status={row.get('status')}"
                ),
                stable_subject=f"native:typeinst:{instance}",
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:concrete-type",),
                attrs={
                    "instance_key": instance,
                    "template": row.get("template"),
                    "args": self._split_list(row.get("args")),
                    "fields": self._split_list(row.get("fields")),
                    "raw": row,
                },
                epistemic_state="observed",
                analysis_depth=3,
                completeness=facts_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))

        # ———— resource rows ————
        for row in rows("alloc-site"):
            subject = str(row.get("f", "") or "")
            stable_subject, degraded = self._key_stable(artifact, subject)
            facts.append(ProviderFact(
                subject=subject,
                predicate="alloc_site",
                object=f"{row.get('kind')}:{row.get('size')}",
                stable_subject=stable_subject,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:alloc-site",),
                attrs=attr_state({
                    "site": row.get("site"),
                    "function_key": subject,
                    "raw": row,
                }, degraded, "textual-key"),
                epistemic_state="observed",
                analysis_depth=3,
                completeness=facts_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))
        for row in rows("alloc-summary"):
            subject = str(row.get("f", "") or "")
            stable_subject, degraded = self._key_stable(artifact, subject)
            facts.append(ProviderFact(
                subject=subject,
                predicate="alloc_summary",
                object=(
                    f"dynamic={row.get('dynamic')};arena={row.get('arena')};"
                    f"sites={row.get('sites')};usites={row.get('usites')};"
                    f"blevel={row.get('blevel')};alevel={row.get('alevel')};"
                    f"slevel={row.get('slevel')}"
                ),
                stable_subject=stable_subject,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:alloc-summary",),
                attrs=attr_state({
                    "function_key": subject,
                    "raw": row,
                }, degraded, "textual-key"),
                epistemic_state="observed",
                analysis_depth=3,
                completeness=facts_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))
        for row in rows("stack-summary"):
            subject = str(row.get("f", "") or "")
            stable_subject, degraded = self._key_stable(artifact, subject)
            facts.append(ProviderFact(
                subject=subject,
                predicate="stack",
                object=(
                    f"frame={row.get('frame')};max={row.get('max')};"
                    f"recursive={row.get('recursive')};flevel={row.get('flevel')};"
                    f"mlevel={row.get('mlevel')}"
                ),
                stable_subject=stable_subject,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:stack-summary",),
                attrs=attr_state({
                    "function_key": subject,
                    "raw": row,
                }, degraded, "textual-key"),
                epistemic_state="observed",
                analysis_depth=3,
                completeness=facts_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))
        for row in rows("blocking-summary"):
            subject = str(row.get("f", "") or "")
            stable_subject, degraded = self._key_stable(artifact, subject)
            facts.append(ProviderFact(
                subject=subject,
                predicate="blocking",
                object=(
                    f"blocking={row.get('blocking')};unbounded={row.get('unbounded')};"
                    f"bsites={row.get('bsites')};level={row.get('level')}"
                ),
                stable_subject=stable_subject,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:blocking-summary",),
                attrs=attr_state({
                    "function_key": subject,
                    "raw": row,
                }, degraded, "textual-key"),
                epistemic_state="observed",
                analysis_depth=3,
                completeness=facts_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))
        for row in rows("code-size-summary"):
            subject = str(row.get("f", "") or "")
            stable_subject, degraded = self._key_stable(artifact, subject)
            facts.append(ProviderFact(
                subject=subject,
                predicate="code_size",
                object=(
                    f"bytes={row.get('bytes')};exact={row.get('exact')};"
                    f"level={row.get('level')}"
                ),
                stable_subject=stable_subject,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:code-size-summary",),
                attrs=attr_state({
                    "function_key": subject,
                    "raw": row,
                }, degraded, "textual-key"),
                epistemic_state="observed",
                analysis_depth=3,
                completeness=facts_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))

        # ———— unsafe / drop / DMA ————
        for row in rows("unsafe-fact"):
            subject = str(row.get("f", "") or "")
            stable_subject, degraded = self._key_stable(artifact, subject)
            facts.append(ProviderFact(
                subject=subject,
                predicate="unsafe",
                object=f"{row.get('ukind')}:{row.get('site')}",
                stable_subject=stable_subject,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:unsafe-fact",),
                attrs=attr_state({
                    "unsafe_digest": row.get("i"),
                    "function_key": subject,
                    "raw": row,
                }, degraded, "textual-key"),
                epistemic_state="observed",
                analysis_depth=3,
                completeness=facts_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))
        for row in rows("drop-plan"):
            subject = str(row.get("f", "") or "")
            stable_subject, degraded = self._key_stable(artifact, subject)
            facts.append(ProviderFact(
                subject=subject,
                predicate="drop_plan",
                object=(
                    f"{row.get('place')}:{row.get('kind')}:{row.get('site')}"
                ),
                stable_subject=stable_subject,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:drop-plan",),
                attrs=attr_state({
                    "conditional_paths": self._split_list(row.get("paths")),
                    "function_key": subject,
                    "raw": row,
                }, degraded, "textual-key"),
                epistemic_state="observed",
                analysis_depth=3,
                completeness=facts_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))
        for row in rows("dma"):
            subject = str(row.get("f", "") or "")
            stable_subject, degraded = self._key_stable(artifact, subject)
            facts.append(ProviderFact(
                subject=subject,
                predicate="dma",
                object=(
                    f"{row.get('place')}:{row.get('state')}:{row.get('op')}"
                ),
                stable_subject=stable_subject,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:dma",),
                attrs=attr_state({
                    "place_id": row.get("pid"),
                    "commit_site": row.get("site"),
                    "function_key": subject,
                    "raw": row,
                }, degraded, "textual-key"),
                epistemic_state="observed",
                analysis_depth=3,
                completeness=facts_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))

        # ———— tests + coverage ————
        test_stable_by_key: dict[str, str] = {}
        for row in rows("test"):
            test_digest = str(row.get("test", "") or "")
            test_key = str(row.get("tkey", "") or "")
            stable = f"native:test:{test_digest}"
            if test_key:
                test_stable_by_key.setdefault(test_key, stable)
            entities.append(ProviderEntity(
                kind="Test",
                name=str(row.get("tname") or test_key or test_digest),
                qualified_name=test_key or test_digest,
                stable_id=stable,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:test",),
                attrs={
                    "test_kind": row.get("tkind"),
                    "test_attributes": row.get("tattrs"),
                    "test_digest": test_digest,
                    "tkey": test_key,
                    "target_digest": row.get("target"),
                    "identity_basis": "persistent-test-digest",
                    "identity_degraded": False,
                    "raw": row,
                },
                epistemic_state="declared",
                analysis_depth=3,
                completeness=tests_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))
            target_digest = str(row.get("target", "") or "")
            target_stable, target_degraded = self._decl_stable(target_digest)
            if not target_degraded:
                relations.append(ProviderRelation(
                    src_key=stable,
                    dst_key=target_stable,
                    kind="tests",
                    src_kind="Test",
                    dst_kind="Symbol",
                    tier=3,
                    provenance="compiler",
                    derived_from=("tangerine-native:test",),
                    attrs={"target_digest": target_digest, "raw": row},
                    epistemic_state="declared",
                    analysis_depth=3,
                    completeness=tests_completeness,
                    provider=self.provider_id,
                    provider_revision=self.provider_version,
                ))
            else:
                unresolved.append(ProviderUnresolved(
                    src_key=stable,
                    dst_raw=target_digest,
                    kind="tests",
                    candidates=(),
                    confidence=0.4,
                    completeness="unknown",
                    attrs={
                        "target_digest": target_digest,
                        "identity_degraded": True,
                        "raw": row,
                    },
                    provider=self.provider_id,
                    provider_revision=self.provider_version,
                ))

        for row in rows("coverage"):
            digest = str(row.get("f", "") or "")
            key = self._display_key(artifact, digest)
            stable_subject, _ = self._decl_stable(digest)
            branch = str(row.get("branch", "") or "")
            arm = str(row.get("arm", "") or "")
            point_kind = str(row.get("kind", "") or "")
            test_id = str(row.get("test", "") or "")
            facts.append(ProviderFact(
                subject=key,
                predicate="coverage",
                object=f"{point_kind}:{branch}" + (f"#{arm}" if arm else ""),
                stable_subject=stable_subject,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:coverage",),
                attrs={
                    "branch": branch,
                    "arm": arm,
                    "point_kind": point_kind,
                    "test_id": test_id,
                    "function_digest": digest,
                    "raw": row,
                },
                epistemic_state="observed",
                analysis_depth=3,
                completeness=facts_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))
            if test_id:
                test_stable = test_stable_by_key.get(test_id)
                if test_stable:
                    relations.append(ProviderRelation(
                        src_key=test_stable,
                        dst_key=stable_subject,
                        kind="tests",
                        src_kind="Test",
                        dst_kind="Symbol",
                        tier=3,
                        provenance="compiler",
                        derived_from=("tangerine-native:coverage",),
                        attrs={
                            "role": "coverage",
                            "branch": branch,
                            "arm": arm,
                            "point_kind": point_kind,
                            "raw": row,
                        },
                        epistemic_state="observed",
                        analysis_depth=3,
                        completeness=tests_completeness,
                        provider=self.provider_id,
                        provider_revision=self.provider_version,
                    ))
                else:
                    unresolved.append(ProviderUnresolved(
                        src_key=(
                            test_stable or f"native:key:{test_id}"
                        ),
                        dst_raw=key or digest,
                        kind="tests",
                        candidates=(),
                        confidence=0.4,
                        completeness="unknown",
                        attrs={
                            "role": "coverage",
                            "test_id": test_id,
                            "branch": branch,
                            "point_kind": point_kind,
                            "raw": row,
                        },
                        provider=self.provider_id,
                        provider_revision=self.provider_version,
                    ))

        # ———— contracts + contract references (canonical (kind, name)) ————
        contract_by_key: dict[str, tuple[str, str, str]] = {}
        for row in rows("contract"):
            contract_digest = str(row.get("i", "") or "")
            function_digest = str(row.get("f", "") or "")
            ckind = str(row.get("ckind", "") or "")
            text = str(row.get("text", "") or "")
            function_key = artifact.digest_to_key.get(function_digest)
            if function_key:
                canonical_name = f"{function_key}|{ckind}|{text}"
            else:
                canonical_name = f"digest::{contract_digest}"
            stable = f"native:contract:{contract_digest}"
            contract_by_key[canonical_name] = (ckind, canonical_name, stable)
            holder_stable, _ = self._decl_stable(function_digest)
            entities.append(ProviderEntity(
                kind="Contract",
                name=canonical_name,
                qualified_name=canonical_name,
                stable_id=stable,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:contract",),
                attrs={
                    "native_family": "contract",
                    "contract_kind": ckind,
                    "contract_digest": contract_digest,
                    "expression": text,
                    "fingerprint": row.get("fp"),
                    "message": row.get("msg"),
                    "contract_key": canonical_name,
                    "function": holder_stable,
                    "function_digest": function_digest,
                    "identity_basis": "persistent-contract-digest",
                    "identity_degraded": False,
                    "raw": row,
                },
                epistemic_state="declared",
                analysis_depth=3,
                completeness=contracts_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))
            facts.append(ProviderFact(
                subject=canonical_name,
                predicate="contract_ref",
                object=f"contract:{ckind}:{canonical_name}",
                stable_subject=stable,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:contract",),
                attrs={
                    "role": "declaration",
                    "contract_kind": ckind,
                    "contract_digest": contract_digest,
                    "contract_key": canonical_name,
                    "function": holder_stable,
                    "expression": text,
                    "fingerprint": row.get("fp"),
                    "message": row.get("msg"),
                    "raw": row,
                },
                epistemic_state="declared",
                analysis_depth=3,
                completeness=contracts_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))
            relations.append(ProviderRelation(
                src_key=holder_stable,
                dst_key=stable,
                kind="constrained_by",
                src_kind="Symbol",
                dst_kind="Contract",
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:contract",),
                attrs={"contract_kind": ckind, "raw": row},
                epistemic_state="declared",
                analysis_depth=3,
                completeness=contracts_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))

        for row in rows("dep-contract-ref"):
            contract_text = str(row.get("contract", "") or "")
            symbol_text = str(row.get("symbol", "") or "")
            entry = contract_by_key.get(contract_text)
            if entry is not None:
                ckind, canonical_name, contract_stable = entry
                kind_resolved = True
            else:
                ckind, canonical_name, contract_stable = "unknown", contract_text, f"native:key:{contract_text}"
                kind_resolved = False
            symbol_stable, symbol_degraded = self._key_stable(artifact, symbol_text)
            facts.append(ProviderFact(
                subject=symbol_text or symbol_stable,
                predicate="contract_ref",
                object=f"contract:{ckind}:{canonical_name}",
                stable_subject=symbol_stable,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:dep-contract-ref",),
                attrs={
                    "role": "reference",
                    "contract_id": contract_text,
                    "contract_kind": ckind,
                    "contract_kind_unresolved": not kind_resolved,
                    "referenced_symbol": symbol_text,
                    "identity_degraded": symbol_degraded,
                    "raw": row,
                },
                epistemic_state="observed",
                analysis_depth=3,
                completeness=contracts_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))
            relations.append(ProviderRelation(
                src_key=contract_stable,
                dst_key=symbol_stable,
                kind="depends_on",
                src_kind="Contract",
                dst_kind="Symbol",
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:dep-contract-ref",),
                attrs={
                    "role": "contract_reference",
                    "contract_kind_unresolved": not kind_resolved,
                    "identity_degraded": symbol_degraded,
                    "raw": row,
                },
                epistemic_state="observed",
                analysis_depth=3,
                completeness=contracts_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))

        # ———— typed dependency families ————
        def dep_relation(row: dict, tag: str, src_text, dst_text, kind: str,
                         derived: str, attrs: dict,
                         src_kind: str = "Symbol",
                         dst_kind: str = "Symbol") -> None:
            src_stable, src_degraded = self._key_stable(artifact, src_text)
            dst_stable, dst_degraded = self._key_stable(artifact, dst_text)
            family = _DEP_FAMILY_BY_TAG.get(tag, "")
            completeness = normalize_verdict(
                dep.get(family), default="partial"
            )
            relations.append(ProviderRelation(
                src_key=src_stable,
                dst_key=dst_stable,
                kind=kind,
                src_kind=src_kind,
                dst_kind=dst_kind,
                tier=3,
                provenance="compiler",
                derived_from=(derived,),
                attrs={
                    **attrs,
                    "native_family": family,
                    "identity_degraded": bool(src_degraded or dst_degraded),
                    "raw": row,
                },
                epistemic_state="observed",
                analysis_depth=3,
                completeness=completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))

        for row in rows("dep-type-use"):
            dep_relation(row, "dep-type-use", row.get("user"), row.get("used"),
                         "depends_on", "tangerine-native:dep-type-use",
                         {"role": "type_use"})
        for row in rows("dep-trait-impl"):
            dep_relation(row, "dep-trait-impl", row.get("impl"),
                         row.get("trait"), "implements",
                         "tangerine-native:dep-trait-impl",
                         {"role": "trait_impl", "self_type": row.get("self")})
        for row in rows("dep-trait-select"):
            dep_relation(row, "dep-trait-select", row.get("fn"),
                         row.get("impl"), "depends_on",
                         "tangerine-native:dep-trait-select",
                         {"role": "trait_selection", "trait": row.get("trait")})
        for row in rows("dep-generic-inst"):
            dep_relation(row, "dep-generic-inst", row.get("instance"),
                         row.get("template"), "depends_on",
                         "tangerine-native:dep-generic-inst",
                         {"role": "generic_instantiation"})
        for row in rows("dep-layout"):
            dep_relation(row, "dep-layout", row.get("dependent"),
                         row.get("source"), "depends_on",
                         "tangerine-native:dep-layout",
                         {"role": "layout_dependency"})
        for row in rows("dep-const-eval"):
            dep_relation(row, "dep-const-eval", row.get("dependent"),
                         row.get("const"), "depends_on",
                         "tangerine-native:dep-const-eval",
                         {"role": "const_eval_dependency"})
        for row in rows("dep-derived-body"):
            dep_relation(row, "dep-derived-body", row.get("derived"),
                         row.get("source"), "depends_on",
                         "tangerine-native:dep-derived-body",
                         {"role": "derived_body"})
        for row in rows("dep-abi"):
            dep_relation(row, "dep-abi", f"native:abi:{row.get('surface')}",
                         row.get("type"), "depends_on",
                         "tangerine-native:dep-abi",
                         {"role": "abi_dependency"}, src_kind="API")

        # ———— ABI surfaces ————
        for row in rows("abi-surface"):
            surface = str(row.get("surface", "") or "")
            stable = f"native:abi:{surface}"
            entities.append(ProviderEntity(
                kind="API",
                name=surface,
                qualified_name=surface,
                stable_id=stable,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:abi-surface",),
                attrs={
                    "native_family": "abi-surface",
                    "surface_id": surface,
                    "symbol_key": row.get("symbol"),
                    "surface_kind": row.get("kind"),
                    "size": row.get("size"),
                    "align": row.get("align"),
                    "arg_classes": row.get("args"),
                    "ret_class": row.get("ret"),
                    "fields": row.get("fields"),
                    "calling_convention": row.get("conv"),
                    "external_symbol": row.get("extern"),
                    "platform": row.get("platform"),
                    "failure_convention": row.get("failure"),
                    "thread_safety": row.get("thread"),
                    "taint": row.get("taint"),
                    "canonical_boundary": row.get("boundary"),
                    "variadic": row.get("variadic"),
                    "identity_basis": "abi-surface-key",
                    "identity_degraded": False,
                    "raw": row,
                },
                epistemic_state="observed",
                analysis_depth=2,
                completeness="partial",
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))
            symbol_text = str(row.get("symbol", "") or "")
            if symbol_text:
                symbol_stable, symbol_degraded = self._key_stable(
                    artifact, symbol_text
                )
                relations.append(ProviderRelation(
                    src_key=symbol_stable,
                    dst_key=stable,
                    kind="depends_on",
                    src_kind="Symbol",
                    dst_kind="API",
                    tier=3,
                    provenance="compiler",
                    derived_from=("tangerine-native:abi-surface",),
                    attrs={
                        "role": "abi_surface",
                        "identity_degraded": symbol_degraded,
                        "raw": row,
                    },
                    epistemic_state="observed",
                    analysis_depth=3,
                    completeness="partial",
                    provider=self.provider_id,
                    provider_revision=self.provider_version,
                ))

        if degraded_keys:
            notes.append(
                f"native artifact: {degraded_keys} row(s)/endpoint(s) resolved "
                "to the degraded textual identity (no persistent digest); "
                "identity_degraded is recorded on each"
            )

    def _project_server(self, server: _ServerSession, have_artifact: bool,
                        entities: list[ProviderEntity],
                        facts: list[ProviderFact],
                        notes: list[str]) -> None:
        for op, resp in server.responses.items():
            kind = str(resp.get("kind", ""))
            if not resp.get("ok", False):
                notes.append(
                    f"native server {op}: error response "
                    f"{kind!r}: {resp.get('error', '')}"
                )
                continue
            keys = list(resp.get("keys", []))
            if op == "revision":
                if keys:
                    facts.append(ProviderFact(
                        subject="repo:.",
                        predicate="native.revision",
                        object=str(keys[0]),
                        stable_subject="repo:.",
                        tier=0,
                        provenance="compiler",
                        derived_from=("tangerine-native:revision",),
                        attrs={"operation": op, "raw_keys": keys},
                        epistemic_state="observed",
                        analysis_depth=2,
                        completeness="complete",
                        provider=self.provider_id,
                        provider_revision=self.provider_version,
                    ))
                else:
                    notes.append("native server revision: answer carries no digest")
            elif op == "snapshot.get":
                for row in keys:
                    facts.append(ProviderFact(
                        subject="repo:.",
                        predicate="native.snapshot",
                        object=str(row),
                        stable_subject="repo:.",
                        tier=0,
                        provenance="compiler",
                        derived_from=("tangerine-native:snapshot.get",),
                        attrs={"operation": op},
                        epistemic_state="observed",
                        analysis_depth=2,
                        completeness="partial",
                        provider=self.provider_id,
                        provider_revision=self.provider_version,
                    ))
            elif op == "symbol_search" and not have_artifact:
                for key_text in keys:
                    text = str(key_text)
                    tail = text.rsplit("|", 1)[-1].rsplit("::", 1)[-1]
                    entities.append(ProviderEntity(
                        kind="Symbol",
                        name=tail or text,
                        qualified_name=text,
                        stable_id=f"native:sym:{text}",
                        tier=3,
                        provenance="compiler",
                        derived_from=("tangerine-native:symbol_search",),
                        attrs={
                            "key_text": text,
                            "source": "symbol_search",
                            "identity_basis": "textual-key",
                            "identity_degraded": True,
                        },
                        epistemic_state="declared",
                        analysis_depth=2,
                        completeness="partial",
                        provider=self.provider_id,
                        provider_revision=self.provider_version,
                    ))
            elif kind == "unknown" or kind.endswith("_unavailable"):
                notes.append(
                    f"native server {op}: answered {kind!r} (no rows; "
                    "unregistered or unavailable family)"
                )
            elif op != "symbol_search":
                for row in keys:
                    facts.append(ProviderFact(
                        subject="repo:.",
                        predicate=f"native.{kind or op}",
                        object=str(row),
                        stable_subject="repo:.",
                        tier=0,
                        provenance="compiler",
                        derived_from=(f"tangerine-native:{op}",),
                        attrs={"operation": op, "kind": kind},
                        epistemic_state="observed",
                        analysis_depth=2,
                        completeness="partial",
                        provider=self.provider_id,
                        provider_revision=self.provider_version,
                    ))

    def _mirror_completeness(self, artifact: NativeArtifact | None,
                             server: _ServerSession | None) -> dict[str, str]:
        """Mirror the native producer's own completeness; never upgrade.

        A family invalidated by malformed rows reads back ``unavailable``;
        a rejected artifact contributes nothing.
        """
        completeness: dict[str, str] = {}
        if artifact is not None and not artifact.rejected:
            invalid = artifact.invalid_families
            dep = artifact.dependency_completeness

            def bad(*tags: str) -> bool:
                return any(tag in invalid for tag in tags)

            def has(*tags: str) -> bool:
                return any(artifact.rows.get(tag) for tag in tags)

            completeness["entities"] = (
                "unavailable" if bad(*_ENTITY_TAGS) else "complete"
            )
            call_invalid = bad(*_CALL_TAGS)
            completeness["calls"] = (
                "unavailable" if call_invalid
                else normalize_verdict(dep.get("Call"), default="partial")
            )
            completeness["tests"] = (
                "unavailable" if bad(*_TEST_TAGS)
                else normalize_verdict(dep.get("TestReferences"), default="partial")
            )
            completeness["contracts"] = (
                "unavailable" if bad(*_CONTRACT_TAGS)
                else normalize_verdict(
                    dep.get("ContractReference"), default="partial"
                )
            )
            completeness["facts"] = (
                "unavailable" if bad(*_FACT_TAGS)
                else ("partial" if has(*_FACT_TAGS) else "unknown")
            )
            completeness["ownership"] = (
                "unavailable" if bad(*_OWNERSHIP_TAGS)
                else ("partial" if has(*_OWNERSHIP_TAGS) else "unknown")
            )
            completeness["runtime"] = (
                "unavailable" if bad(*_RUNTIME_TAGS)
                else ("partial" if has(*_RUNTIME_TAGS) else "unknown")
            )
            if bad(*_RELATION_TAGS):
                completeness["relations"] = "unavailable"
            elif dep:
                completeness["relations"] = worst_verdict(
                    *[normalize_verdict(v, default="partial")
                      for v in dep.values()]
                )
            else:
                completeness["relations"] = "partial"
            # An explicit "Unknown" producer word can never read back stronger.
            if (
                "Call" not in dep
                and not call_invalid
                and any(
                    str(row.get("completeness", "")).strip().lower() == "unknown"
                    for row in artifact.rows.get("indirect", [])
                )
            ):
                completeness["calls"] = "unknown"
        elif server is not None and server.responded():
            # Counts and (optionally) symbol keys are visible, but no native
            # completeness record rides the wire; stay conservative.
            completeness["entities"] = "partial"
            for family in ("relations", "facts", "calls", "tests",
                           "contracts", "ownership", "invariants",
                           "runtime", "history"):
                completeness[family] = "unknown"
        else:
            for family in _ALL_FAMILIES:
                completeness[family] = "unavailable"
        for family in _ALL_FAMILIES:
            completeness.setdefault(family, "unknown")
        return completeness

    # ------------------------------------------------------------ sessions

    def _compile_artifact(self, root: Path, binary: Path,
                          entry: Path) -> tuple[Path | None, Path, list[str]]:
        tmpdir = Path(tempfile.mkdtemp(prefix="system-intel-native-"))
        artifact = tmpdir / "semantic_snapshot.tg.jsonl"
        env = dict(os.environ)
        env["TANGERINE_SNAPSHOT"] = str(artifact)
        env.pop("TANGERINE_SERVER", None)
        try:
            proc = subprocess.run(
                [str(binary), "compile", str(entry)],
                cwd=str(root),
                env=env,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                timeout=COMPILE_TIMEOUT_S,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            return None, tmpdir, [
                f"native compile could not start: {exc.__class__.__name__}: {exc}"
            ]
        if proc.returncode != 0:
            tail = (proc.stderr or b"").decode("utf-8", "replace").strip()
            tail_lines = [line for line in tail.splitlines() if line][-3:]
            detail = " | ".join(tail_lines) if tail_lines else "no stderr"
            return None, tmpdir, [
                f"native compile exited {proc.returncode} ({detail})"
            ]
        if not artifact.is_file() or artifact.stat().st_size == 0:
            return None, tmpdir, [
                "native compile reported success but wrote no snapshot artifact"
            ]
        return artifact, tmpdir, [
            f"native compile wrote snapshot artifact {artifact}"
        ]

    def _talk_to_server(self, root: Path, binary: Path,
                        artifact_path: Path | None) -> _ServerSession:
        """Run the whole §39 exchange under ONE wall-clock bound.

        The worker thread owns the blocking reads; the caller joins it with
        ``server_timeout`` and kills the process on expiry, so a hung server
        can never block a scan indefinitely.
        """
        session = _ServerSession(binary=str(binary))
        args = [str(binary), "server"]
        if artifact_path is not None:
            args += ["--snapshot-only", "--snapshot=" + str(artifact_path)]
        requests: list[tuple[str, str]] = [("revision", ""), ("snapshot.get", "")]
        if artifact_path is None:
            requests.append(("symbol_search", ""))
        try:
            proc = subprocess.Popen(
                args,
                cwd=str(root),
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
            )
        except OSError as exc:
            session.notes.append(
                f"native server could not start: {exc.__class__.__name__}: {exc}"
            )
            return session
        worker = threading.Thread(
            target=self._server_exchange,
            args=(proc, requests, session),
            daemon=True,
        )
        worker.start()
        worker.join(self._server_timeout)
        if worker.is_alive():
            session.timed_out = True
            session.notes.append(
                f"native server exchange exceeded the {self._server_timeout:g}s "
                "wall-clock bound; killed and degraded (hung server)"
            )
            try:
                proc.kill()
            except OSError:
                pass
            worker.join(5.0)
        self._finalize_server_process(proc)
        session.counts = _parse_counts(session.responses.get("snapshot.get"))
        return session

    def _server_exchange(self, proc, requests: list[tuple[str, str]],
                         session: _ServerSession) -> None:
        try:
            payload = b"".join(
                frame_request(PROTOCOL_VERSION, index + 1, op, arg)
                for index, (op, arg) in enumerate(requests)
            )
            proc.stdin.write(payload)
            proc.stdin.flush()
        except (OSError, ValueError) as exc:
            session.notes.append(
                f"native server write failed: {exc.__class__.__name__}"
            )
        try:
            proc.stdin.close()
        except OSError:
            pass
        for index, (op, _arg) in enumerate(requests):
            if session.timed_out:
                break
            try:
                body = read_frame(proc.stdout)
            except NativeProtocolError as exc:
                session.notes.append(f"native server {op}: protocol error: {exc}")
                break
            if body is None:
                session.notes.append(
                    f"native server did not answer {op} "
                    f"(EOF after {len(session.responses)} response(s))"
                )
                break
            try:
                response = parse_response_body(body)
            except NativeProtocolError as exc:
                session.notes.append(
                    f"native server {op}: malformed response: {exc}"
                )
                break
            if response["protocol_version"] != PROTOCOL_VERSION:
                session.notes.append(
                    f"native server {op}: protocol version "
                    f"{response['protocol_version']} != {PROTOCOL_VERSION}"
                )
                break
            if response["request_id"] != index + 1:
                session.notes.append(
                    f"native server {op}: request_id "
                    f"{response['request_id']} != {index + 1} (desync; stop)"
                )
                break
            session.responses[op] = response
        try:
            proc.wait(timeout=5.0)
        except subprocess.TimeoutExpired:
            try:
                proc.kill()
            except OSError:
                pass
            try:
                proc.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                pass
            session.notes.append(
                "native server did not exit after stdin close; killed"
            )

    @staticmethod
    def _finalize_server_process(proc) -> None:
        if proc.poll() is None:
            try:
                proc.kill()
            except OSError:
                pass
        try:
            proc.wait(timeout=5.0)
        except (subprocess.TimeoutExpired, OSError):
            pass
        for stream in (proc.stdin, proc.stdout):
            if stream is None:
                continue
            try:
                stream.close()
            except OSError:
                pass

    def _degraded(self, root: Path, notes: list[str],
                  artifact: NativeArtifact | None = None,
                  server: _ServerSession | None = None) -> ProviderSnapshot:
        reason = "; ".join(note for note in notes if note) or (
            "native compiler/artifact unavailable"
        )
        self._completeness = {family: "unavailable" for family in _ALL_FAMILIES}
        self._invalid_families = (
            set(artifact.invalid_families)
            if artifact is not None and not artifact.rejected else set()
        )
        self._degrade_note = reason
        capabilities = [
            ProviderCapability(
                family, "unavailable", self._capability_note(family)
            )
            for family in _ALL_FAMILIES
        ]
        evidence = [ProviderEvidence(
            kind="provider_error",
            ref=str(root),
            summary=reason,
            payload={
                "notes": notes,
                "artifact": artifact.path if artifact else "",
                "rejected": bool(artifact and artifact.rejected),
                "reject_reason": artifact.reject_reason if artifact else "",
                "invalid_families": (
                    sorted(artifact.invalid_families) if artifact else []
                ),
                "server": server.binary if server else "",
                "server_timed_out": bool(server and server.timed_out),
            },
            provider=self.provider_id,
        )]
        snap = ProviderSnapshot(
            evidence=evidence,
            providers=[{
                "provider_id": self.provider_id,
                "provider_version": self.provider_version,
                "capabilities": {family: "unavailable" for family in _ALL_FAMILIES},
                "invoked": True,
            }],
            provider_id=self.provider_id,
            provider_version=self.provider_version,
            capabilities=capabilities,
        )
        self._last_snapshot = snap
        return snap


# ── native artifact delta (requirement 5) ────────────────────────────────


def _canonical_row(row: dict) -> str:
    return json.dumps(row, sort_keys=True, separators=(",", ":"))


def _artifact_entities(artifact: NativeArtifact) -> dict[str, str]:
    """Persistent-digest entity renders for one accepted artifact."""
    out: dict[str, str] = {}
    for tag in ("symbol", "type"):
        if tag in artifact.invalid_families:
            continue
        for row in artifact.rows.get(tag, []):
            digest = str(row.get("i", "") or "")
            if not _is_digest(digest) or digest == _ZERO_DIGEST:
                continue
            out[f"native:decl:{digest}"] = _canonical_row(row)
    if "test" not in artifact.invalid_families:
        for row in artifact.rows.get("test", []):
            digest = str(row.get("test", "") or "")
            if not _is_digest(digest):
                continue
            out[f"native:test:{digest}"] = _canonical_row(row)
    if "contract" not in artifact.invalid_families:
        for row in artifact.rows.get("contract", []):
            digest = str(row.get("i", "") or "")
            if not _is_digest(digest):
                continue
            out[f"native:contract:{digest}"] = _canonical_row(row)
    return out


def _artifact_unresolved(artifact: NativeArtifact) -> dict[str, str]:
    out: dict[str, str] = {}
    if "indirect" in artifact.invalid_families:
        return out
    for row in artifact.rows.get("indirect", []):
        src = str(row.get("caller", "") or "")
        dst = str(row.get("sig") or row.get("site") or "")
        out[f"{src}\x1f{'calls'}\x1f{dst}"] = _canonical_row(row)
    return out


def _native_artifact_delta(old: NativeArtifact,
                           new: NativeArtifact) -> dict:
    """Native row-identity diff of two §30 artifacts.

    Entities keyed by persistent digest (declarations, tests, contracts) and
    indirect unresolved renders — the same channels the federation delta
    shape exposes; edge-only changes are not fabricated into the entity set.

    Note: this mirrors the native §31 entity/indirect semantics over the
    artifact rows because neither the artifact nor the single-snapshot §39
    server serializes a pair delta (see the module docstring).
    """
    old_entities = _artifact_entities(old)
    new_entities = _artifact_entities(new)
    old_unresolved = _artifact_unresolved(old)
    new_unresolved = _artifact_unresolved(new)
    return {
        "added": sorted(set(new_entities) - set(old_entities)),
        "removed": sorted(set(old_entities) - set(new_entities)),
        "changed": sorted(
            key for key in set(old_entities) & set(new_entities)
            if old_entities[key] != new_entities[key]
        ),
        "unresolved_added": sorted(
            set(new_unresolved) - set(old_unresolved)
        ),
    }
