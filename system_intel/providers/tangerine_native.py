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

Projection into the universal vocabulary (§5):

* ``symbol`` rows  -> Symbol entities (``native:sym:<key>``)
* ``type`` rows    -> Symbol entities, type kind in attrs (``native:type:<key>``)
* ``call`` rows    -> ``calls`` relations, analysis_depth 3
* ``indirect`` rows-> ``unresolved`` entries, completeness ``unknown``
  (the native model records every indirect site with an EMPTY candidate set
  and completeness "Unknown" — semantic_snapshot.tg:7527)
* ``effect`` / ``capability`` / ``ownership`` rows -> facts, depth 3
* ``contract`` rows -> Contract entities, epistemic_state ``declared``
* ``test`` rows     -> Test entities + typed ``tests`` relations (or an
  unresolved claim when the exercised decl cannot be mapped)
* ``dep-completeness`` rows -> the family verdicts, MIRRORED and never
  upgraded (semantic_snapshot.tg:5892 documents the producer statuses)

Degradation is first-class: a missing binary, a compile failure, an absent
artifact or a protocol mismatch yields ``unavailable`` capabilities, an empty
snapshot, a note and a recorded evidence entry — ``snapshot()`` never raises
for these expected states and NEVER fabricates data.
"""

from __future__ import annotations

import json
import hashlib
import os
import shutil
import struct
import subprocess
import tempfile
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
PROVIDER_VERSION = "1.0"

NATIVE_COMPILER_ENV = "TANGERINE_NATIVE_COMPILER"
NATIVE_SNAPSHOT_ENV = "TANGERINE_NATIVE_SNAPSHOT"

# §39 framing constants (semantic_server.tg:379-381).
PROTOCOL_VERSION = 1
MAX_FRAME_BYTES = 16 * 1024 * 1024
MAX_FIELD_BYTES = 1024 * 1024
MAX_KEYS = 65536

SERVER_TIMEOUT_S = 30.0
COMPILE_TIMEOUT_S = 600.0

DEFAULT_BINARY = "build/bootstrap/tg"

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
    "entities": "native symbols/types tables built from finalized type state",
    "relations": "mirrors the native dependency-family completeness record",
    "facts": "effect/capability/ownership rows; no native producer status published",
    "calls": "mirrors native Call completeness; indirect rows stay 'unknown'",
    "tests": "mirrors native TestReferences completeness",
    "contracts": "declared contract rows; mirrors ContractReference completeness",
    "ownership": "ownership facts; no native producer status published",
    "invariants": "no native invariant family is served",
    "runtime": "coverage-ingest rows only; the compile carries no runtime data",
    "history": "no history source in the native artifact",
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


@dataclass
class NativeArtifact:
    """Parsed ``tg-semantic-snapshot/v1`` artifact (semantic_snapshot.tg)."""

    path: str
    sha256: str
    header: dict = field(default_factory=dict)
    rows: dict[str, list[dict]] = field(default_factory=dict)
    dependency_completeness: dict[str, str] = field(default_factory=dict)
    digest_to_key: dict[str, str] = field(default_factory=dict)
    parse_notes: list[str] = field(default_factory=list)

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
    """Parse a §30 artifact defensively; None when absent/empty/unreadable.

    Malformed rows are recorded in ``parse_notes`` and skipped — the parser
    never crashes on an artifact it does not fully understand.
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
    for line_no, line in enumerate(text.splitlines(), start=1):
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            if len(artifact.parse_notes) < 20:
                artifact.parse_notes.append(f"line {line_no}: unparseable row")
            continue
        if not isinstance(row, dict):
            if len(artifact.parse_notes) < 20:
                artifact.parse_notes.append(f"line {line_no}: non-object row")
            continue
        tag = str(row.get("s", "") or "")
        if not tag:
            if len(artifact.parse_notes) < 20:
                artifact.parse_notes.append(f"line {line_no}: row without tag")
            continue
        if tag == "header":
            if not artifact.header:
                artifact.header = row
            continue
        artifact.rows.setdefault(tag, []).append(row)
        if tag == "dep-completeness":
            family = str(row.get("family", "") or "")
            if family:
                artifact.dependency_completeness[family] = normalize_verdict(
                    row.get("status"), default="unknown"
                )
    for tag in ("symbol", "type"):
        for row in artifact.rows.get(tag, []):
            digest = str(row.get("i", "") or "")
            key = str(row.get("key", "") or "")
            if digest and key:
                artifact.digest_to_key.setdefault(digest, key)
    return artifact


@dataclass
class _ServerSession:
    binary: str
    responses: dict[str, dict] = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)
    counts: dict[str, int] = field(default_factory=dict)

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

    def __init__(self, binary=None, artifact=None) -> None:
        self._binary_override = str(binary) if binary else None
        self._artifact_override = str(artifact) if artifact else None
        self._completeness = {family: "unknown" for family in _ALL_FAMILIES}
        self._degrade_note = ""
        self._last_snapshot: ProviderSnapshot | None = None
        self._last_artifact: NativeArtifact | None = None
        self._last_server: _ServerSession | None = None

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
        if artifact is None:
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

    def capabilities(self) -> list[ProviderCapability]:
        out = []
        for family in _ALL_FAMILIES:
            note = _CAPABILITY_NOTES.get(family, "")
            if self._degrade_note:
                note = f"{note}; {self._degrade_note}" if note else self._degrade_note
            out.append(ProviderCapability(
                family, self._completeness.get(family, "unknown"), note
            ))
        return out

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
                else:
                    notes.append(f"native artifact {artifact_path} does not exist")

            server: _ServerSession | None = None
            if binary is not None and binary.is_file():
                server = self._talk_to_server(
                    root_path, binary,
                    Path(artifact_path) if artifact else None,
                )
                notes.extend(server.notes)
            elif binary is None:
                notes.append(
                    f"native compiler not found (env {NATIVE_COMPILER_ENV} or "
                    f"{DEFAULT_BINARY})"
                )
            else:
                notes.append(f"native compiler {binary} is not a file")

            if artifact is None and (server is None or not server.responded()):
                return self._degraded(root_path, notes, artifact=artifact,
                                      server=server)

            entities: list[ProviderEntity] = []
            relations: list[ProviderRelation] = []
            facts: list[ProviderFact] = []
            unresolved: list[ProviderUnresolved] = []
            if artifact is not None:
                self._project_artifact(
                    artifact, entities, relations, facts, unresolved, notes
                )
            if server is not None and server.responded():
                self._project_server(
                    server, artifact is not None, entities, facts, notes
                )

            completeness = self._mirror_completeness(artifact, server)
            capabilities = [
                ProviderCapability(family, completeness.get(family, "unknown"),
                                   _CAPABILITY_NOTES.get(family, ""))
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
                    ),
                    payload={
                        "revision": artifact.revision,
                        "compiler_version": artifact.compiler_version,
                        "surface_hashes": artifact.surface_hashes,
                        "dependency_completeness": artifact.dependency_completeness,
                        "parse_notes": artifact.parse_notes,
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
                    artifact.semantic_configuration if artifact else {}
                ),
                provider_id=self.provider_id,
                provider_version=self.provider_version,
                capabilities=capabilities,
            )
            self._completeness = completeness
            self._degrade_note = ""
            self._last_snapshot = snap
            self._last_artifact = artifact
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

    def delta(self, old_snapshot: ProviderSnapshot,
              new_snapshot: ProviderSnapshot) -> dict:
        return _snapshot_delta(old_snapshot, new_snapshot)

    # ------------------------------------------------------------ projection

    @staticmethod
    def _digest_stable(artifact: NativeArtifact, digest: str,
                       domain: str = "sym") -> str | None:
        key = artifact.digest_to_key.get(str(digest))
        if not key:
            return None
        return f"native:{domain}:{key}"

    def _project_artifact(self, artifact: NativeArtifact,
                          entities: list[ProviderEntity],
                          relations: list[ProviderRelation],
                          facts: list[ProviderFact],
                          unresolved: list[ProviderUnresolved],
                          notes: list[str]) -> None:
        dep = artifact.dependency_completeness

        def dep_verdict(family: str, fallback: str) -> str:
            if family in dep:
                return normalize_verdict(dep[family], default=fallback)
            return fallback

        symbol_completeness = "complete"
        call_completeness = dep_verdict("Call", "partial")
        tests_completeness = dep_verdict("TestReferences", "partial")
        contracts_completeness = dep_verdict("ContractReference", "partial")

        for row in artifact.rows.get("symbol", []):
            key = str(row.get("key", "") or "")
            if not key:
                notes.append("native symbol row without a key text")
                continue
            entities.append(ProviderEntity(
                kind="Symbol",
                name=str(row.get("name") or key),
                qualified_name=key,
                stable_id=f"native:sym:{key}",
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:symbol",),
                attrs={
                    "native_family": "symbol",
                    "def_kind": row.get("kind"),
                    "digest": row.get("i"),
                    "module": row.get("module"),
                    "is_pub": row.get("pub"),
                    "is_generic": row.get("generic"),
                    "raw": row,
                },
                epistemic_state="observed",
                analysis_depth=2,
                completeness=symbol_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))

        for row in artifact.rows.get("type", []):
            key = str(row.get("key", "") or "")
            if not key:
                notes.append("native type row without a key text")
                continue
            entities.append(ProviderEntity(
                kind="Symbol",
                name=str(row.get("name") or key),
                qualified_name=key,
                stable_id=f"native:type:{key}",
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:type",),
                attrs={
                    "native_family": "type",
                    "type_kind": row.get("tkind"),
                    "digest": row.get("i"),
                    "module": row.get("module"),
                    "is_pub": row.get("pub"),
                    "generic_arity": row.get("generic_arity"),
                    "raw": row,
                },
                epistemic_state="observed",
                analysis_depth=2,
                completeness=symbol_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))

        for row in artifact.rows.get("call", []):
            from_digest = str(row.get("from", "") or "")
            to_digest = str(row.get("to", "") or "")
            src_stable = self._digest_stable(artifact, from_digest)
            dst_stable = self._digest_stable(artifact, to_digest)
            attrs = {
                "ekind": row.get("ekind"),
                "from_digest": from_digest,
                "to_digest": to_digest,
                "raw": row,
            }
            if src_stable and dst_stable:
                relations.append(ProviderRelation(
                    src_key=src_stable,
                    dst_key=dst_stable,
                    kind="calls",
                    src_kind="Symbol",
                    dst_kind="Symbol",
                    tier=3,
                    provenance="compiler",
                    derived_from=("tangerine-native:call",),
                    attrs=attrs,
                    epistemic_state="observed",
                    analysis_depth=3,
                    completeness=call_completeness,
                    provider=self.provider_id,
                    provider_revision=self.provider_version,
                ))
            else:
                unresolved.append(ProviderUnresolved(
                    src_key=src_stable or f"native:def:{from_digest}",
                    dst_raw=to_digest,
                    kind="calls",
                    candidates=(),
                    confidence=0.5,
                    completeness="unknown",
                    attrs=dict(attrs, mapped_src=bool(src_stable),
                               mapped_dst=bool(dst_stable)),
                    provider=self.provider_id,
                    provider_revision=self.provider_version,
                ))

        for row in artifact.rows.get("indirect", []):
            # The native model emits EVERY indirect site with an EMPTY
            # candidate set and completeness "Unknown" (semantic_snapshot.tg:7527);
            # the provider mirrors that exactly — never a guess.
            caller = str(row.get("caller", "") or "")
            site = str(row.get("site", "") or "")
            signature = str(row.get("sig", "") or "")
            unresolved.append(ProviderUnresolved(
                src_key=caller,
                dst_raw=signature or site,
                kind="calls",
                candidates=(),
                confidence=0.1,
                completeness="unknown",
                evidence=(f"site:{site}",) if site else (),
                attrs={
                    "call_site": site,
                    "signature": signature,
                    "native_completeness": row.get("completeness", "Unknown"),
                    "raw": row,
                },
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))

        facts_completeness = "partial" if (
            artifact.rows.get("effect")
            or artifact.rows.get("capability")
            or artifact.rows.get("ownership")
        ) else "unknown"
        for row in artifact.rows.get("effect", []):
            digest = str(row.get("f", "") or "")
            key = artifact.digest_to_key.get(digest)
            facts.append(ProviderFact(
                subject=key or digest,
                predicate="effect",
                object=(
                    f"flags={row.get('flags')};purity={row.get('purity')}"
                ),
                stable_subject=f"native:sym:{key}" if key else "",
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
        for row in artifact.rows.get("capability", []):
            digest = str(row.get("f", "") or "")
            key = artifact.digest_to_key.get(digest)
            facts.append(ProviderFact(
                subject=key or digest,
                predicate="capability",
                object=f"{row.get('dir')}:{row.get('cap')}",
                stable_subject=f"native:sym:{key}" if key else "",
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
        for row in artifact.rows.get("ownership", []):
            digest = str(row.get("f", "") or "")
            key = artifact.digest_to_key.get(digest)
            facts.append(ProviderFact(
                subject=key or digest,
                predicate="ownership",
                object=f"{row.get('place')}:convention={row.get('conv')}",
                stable_subject=f"native:sym:{key}" if key else "",
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

        for row in artifact.rows.get("contract", []):
            contract_id = str(row.get("i", "") or "")
            function_digest = str(row.get("f", "") or "")
            function_key = artifact.digest_to_key.get(function_digest)
            stable = f"native:contract:{contract_id}"
            entities.append(ProviderEntity(
                kind="Contract",
                name=f"{function_key or function_digest}:{row.get('ckind')}",
                qualified_name=contract_id,
                stable_id=stable,
                tier=3,
                provenance="compiler",
                derived_from=("tangerine-native:contract",),
                attrs={
                    "contract_kind": row.get("ckind"),
                    "expression": row.get("text"),
                    "fingerprint": row.get("fp"),
                    "message": row.get("msg"),
                    "function": (
                        f"native:sym:{function_key}" if function_key
                        else function_digest
                    ),
                    "function_digest": function_digest,
                    "raw": row,
                },
                epistemic_state="declared",
                analysis_depth=3,
                completeness=contracts_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))
            if function_key:
                relations.append(ProviderRelation(
                    src_key=f"native:sym:{function_key}",
                    dst_key=stable,
                    kind="constrained_by",
                    src_kind="Symbol",
                    dst_kind="Contract",
                    tier=3,
                    provenance="compiler",
                    derived_from=("tangerine-native:contract",),
                    attrs={"raw": row},
                    epistemic_state="declared",
                    analysis_depth=3,
                    completeness=contracts_completeness,
                    provider=self.provider_id,
                    provider_revision=self.provider_version,
                ))

        for row in artifact.rows.get("test", []):
            test_key = str(row.get("tkey", "") or "")
            test_digest = str(row.get("test", "") or "")
            if not test_key and not test_digest:
                notes.append("native test row without a test key")
                continue
            stable = (
                f"native:test:{test_key}" if test_key
                else f"native:test:{test_digest}"
            )
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
                    "target_digest": row.get("target"),
                    "raw": row,
                },
                epistemic_state="declared",
                analysis_depth=3,
                completeness=tests_completeness,
                provider=self.provider_id,
                provider_revision=self.provider_version,
            ))
            target_digest = str(row.get("target", "") or "")
            target_stable = self._digest_stable(artifact, target_digest)
            if target_stable:
                relations.append(ProviderRelation(
                    src_key=stable,
                    dst_key=target_stable,
                    kind="tests",
                    src_kind="Test",
                    dst_kind="Symbol",
                    tier=3,
                    provenance="compiler",
                    derived_from=("tangerine-native:test",),
                    attrs={"raw": row},
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
                    attrs={"target_digest": target_digest, "raw": row},
                    provider=self.provider_id,
                    provider_revision=self.provider_version,
                ))

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
                        attrs={"key_text": text, "source": "symbol_search"},
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
        """Mirror the native producer's own completeness; never upgrade."""
        completeness: dict[str, str] = {}
        if artifact is not None:
            dep = artifact.dependency_completeness
            completeness["entities"] = "complete"
            completeness["calls"] = normalize_verdict(
                dep.get("Call"), default="partial"
            )
            completeness["tests"] = normalize_verdict(
                dep.get("TestReferences"), default="partial"
            )
            completeness["contracts"] = normalize_verdict(
                dep.get("ContractReference"), default="partial"
            )
            if dep:
                completeness["relations"] = worst_verdict(
                    *[normalize_verdict(v, default="partial") for v in dep.values()]
                )
            else:
                completeness["relations"] = "partial"
            completeness["facts"] = "partial" if (
                artifact.rows.get("effect")
                or artifact.rows.get("capability")
                or artifact.rows.get("ownership")
            ) else "unknown"
            completeness["ownership"] = (
                "partial" if artifact.rows.get("ownership") else "unknown"
            )
            completeness["runtime"] = (
                "partial" if artifact.rows.get("coverage") else "unknown"
            )
            completeness["history"] = "unknown"
            completeness["invariants"] = "unknown"
            # An explicit "Unknown" producer word can never read back stronger.
            if any(
                str(row.get("completeness", "")).strip().lower() == "unknown"
                for row in artifact.rows.get("indirect", [])
            ) and "Call" not in dep:
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
            proc.wait(timeout=SERVER_TIMEOUT_S)
        except subprocess.TimeoutExpired:
            proc.kill()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
            session.notes.append("native server did not exit after stdin close; killed")
        try:
            proc.stdout.close()
        except OSError:
            pass
        session.counts = _parse_counts(session.responses.get("snapshot.get"))
        return session

    def _degraded(self, root: Path, notes: list[str],
                  artifact: NativeArtifact | None = None,
                  server: _ServerSession | None = None) -> ProviderSnapshot:
        reason = "; ".join(note for note in notes if note) or (
            "native compiler/artifact unavailable"
        )
        self._completeness = {family: "unavailable" for family in _ALL_FAMILIES}
        self._degrade_note = reason
        capabilities = [
            ProviderCapability(family, "unavailable",
                               f"{_CAPABILITY_NOTES.get(family, '')}; {reason}".strip("; "))
            for family in _ALL_FAMILIES
        ]
        evidence = [ProviderEvidence(
            kind="provider_error",
            ref=str(root),
            summary=reason,
            payload={
                "notes": notes,
                "artifact": artifact.path if artifact else "",
                "server": server.binary if server else "",
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
