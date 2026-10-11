"""Tests for the system_intel v2 provider SPI and providers (INTERFACES.md §5).

Self-contained and CI-safe: the native compiler is faked with a small Python
script that speaks the §39 framed protocol; no Tangerine build is required.
"""

from __future__ import annotations

import json
import os
import stat
import struct
import tempfile
import time
import unittest
from contextlib import contextmanager
from pathlib import Path

from system_intel.providers import (
    COMPLETENESS_VERDICTS,
    GenericStaticProvider,
    NativeProtocolError,
    ProviderCapability,
    ProviderSnapshot,
    TangerineNativeProvider,
    default_providers,
    frame_request,
    parse_response_body,
    provider_set_digest,
    select_for,
)
from system_intel.providers.generic_static import PROVIDER_ID as GENERIC_ID
from system_intel.providers.tangerine_native import PROVIDER_ID as NATIVE_ID

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "mini_repo"

_PROVIDER_ENV_KEYS = (
    "TANGERINE_NATIVE_COMPILER",
    "TANGERINE_NATIVE_SNAPSHOT",
    "SYSTEM_INTEL_FAKE_LOG",
    "SYSTEM_INTEL_FAKE_ARTIFACT",
    "SYSTEM_INTEL_FAKE_HANG",
)


@contextmanager
def _env(**changes):
    """Temporarily set/clear environment variables (None clears)."""
    saved = {key: os.environ.get(key) for key in changes}
    try:
        for key, value in changes.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        yield
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def _clean_env():
    return _env(**{key: None for key in _PROVIDER_ENV_KEYS})


FAKE_COMPILER_SOURCE = """#!/usr/bin/env python3
\"\"\"Fake Tangerine native compiler speaking the §39 v1 framed protocol.

SYSTEM_INTEL_FAKE_HANG=<n> makes the fake answer n frames and then sleep
forever, for the bounded-server-exchange test.
\"\"\"
import os
import struct
import sys
import time

if len(sys.argv) > 1 and sys.argv[1] == "compile":
    template = os.environ.get("SYSTEM_INTEL_FAKE_ARTIFACT")
    target = os.environ.get("TANGERINE_SNAPSHOT")
    if template and target:
        with open(template, "r", encoding="utf-8") as src:
            data = src.read()
        with open(target, "w", encoding="utf-8") as dst:
            dst.write(data)
        sys.exit(0)
    sys.exit(1)


def read_exact(size):
    data = b""
    while len(data) < size:
        chunk = sys.stdin.buffer.read(size - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def read_frame():
    header = read_exact(4)
    if header is None:
        return None
    (length,) = struct.unpack(">I", header)
    body = read_exact(length)
    if body is None:
        return None
    fields = []
    at = 0
    while at < len(body):
        (flen,) = struct.unpack(">I", body[at:at + 4])
        at += 4
        fields.append(body[at:at + flen].decode("utf-8"))
        at += flen
    return fields


def frame(fields):
    body = b""
    for text in fields:
        payload = text.encode("utf-8")
        body += struct.pack(">I", len(payload)) + payload
    return struct.pack(">I", len(body)) + body


def answer(pv, rid, op):
    if op == "revision":
        return [pv, rid, "true", "revision", "1", "123-456", ""]
    if op == "snapshot.get":
        keys = [
            "compiler_version:fake-1.0",
            "revision:123-456",
            "rows:symbols:2",
            "rows:calls:1",
        ]
        return [pv, rid, "true", "snapshot.get", str(len(keys))] + keys + [""]
    if op == "symbol_search":
        keys = ["pkg|Struct|Item", "pkg|def|main"]
        return [pv, rid, "true", "symbol_search", str(len(keys))] + keys + [""]
    return [pv, rid, "true", "unknown", "0", ""]


log_path = os.environ.get("SYSTEM_INTEL_FAKE_LOG")
hang_after = int(os.environ.get("SYSTEM_INTEL_FAKE_HANG", "0") or "0")
answered = 0
while True:
    request = read_frame()
    if request is None:
        break
    pv, rid, op, payload = (request + ["", "", "", ""])[:4]
    if log_path:
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(pv + "|" + rid + "|" + op + "|" + payload + "\\n")
    sys.stdout.buffer.write(frame(answer(pv, rid, op)))
    sys.stdout.buffer.flush()
    answered += 1
    if hang_after and answered >= hang_after:
        time.sleep(3600)
"""


def _write_fake_compiler(directory: Path) -> Path:
    path = directory / "fake_tg"
    path.write_text(FAKE_COMPILER_SOURCE, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


def _artifact_header(**overrides) -> dict:
    header = {
        "s": "header", "v": 1, "format": "tg-semantic-snapshot/v1",
        "compiler_version": "canned-1.0", "features": "", "options": "--opt=2",
        "target": "x86_64-unknown-linux-gnu", "tarch": "x86_64",
        "tcpu": "generic", "tptr": 64, "tendian": "little", "tabi": "sysv",
        "tfloat": "sse2", "tisa": "avx2,sse4.2", "tnative": "32;64",
        "tident": "1-1", "tdigest": "2-2",
        "d_concrete_types": "0-0", "d_drop_plans": "0-0",
        "d_allocation_sites": "0-0", "d_resource_summaries": "0-0",
        "d_dma_ownership": "0-0", "d_features": "0-0",
        "revision": "100-200",
        "public_api_hash": "3-3", "abi_hash": "4-4", "unsafe_hash": "5-5",
    }
    header.update(overrides)
    return header


def _canned_artifact_lines() -> list[dict]:
    return [
        _artifact_header(),
        {
            "s": "symbol", "i": "10-1", "key": "pkg|def|main", "kind": "Function",
            "name": "main", "module": "pkg", "pub": True, "generic": False,
        },
        {
            "s": "symbol", "i": "10-2", "key": "pkg|def|helper", "kind": "Function",
            "name": "helper", "module": "pkg", "pub": False, "generic": False,
        },
        {
            "s": "type", "i": "11-1", "key": "pkg|Struct|Item", "tkind": "Struct",
            "name": "Item", "module": "pkg", "generic_arity": 0, "pub": True,
        },
        {"s": "call", "from": "10-1", "to": "10-2", "ekind": "Direct"},
        {
            "s": "indirect", "caller": "10-1", "site": "10-1#B0#T",
            "sig": "fn(i64)->i64", "candidates": "", "completeness": "Unknown",
        },
        {
            "s": "effect", "f": "10-1", "flags": 1, "caps": "",
            "purity": "Impure", "pevidence": "",
        },
        {"s": "capability", "f": "10-1", "cap": 2, "dir": "Requires"},
        {"s": "ownership", "f": "10-1", "place": "p0", "conv": 1},
        {
            "s": "contract", "i": "20-1", "f": "10-1", "ckind": "Pre",
            "text": "> x | 0", "fp": "21-1", "msg": "x must stay positive",
        },
        {
            "s": "test", "test": "30-1", "target": "10-2",
            "tkey": "pkg|test@unit#t_helper", "tkind": "unit",
            "tname": "t_helper", "tattrs": "",
        },
        {"s": "dep-completeness", "family": "Call", "status": "partial"},
        {"s": "dep-completeness", "family": "TestReferences", "status": "complete"},
        {"s": "dep-completeness", "family": "TraitImpl", "status": "partial"},
        {"s": "dep-completeness", "family": "AbiDependency", "status": "partial"},
        {"s": "dep-completeness", "family": "TypeUse", "status": "complete"},
    ]


def _write_artifact(directory: Path, name: str, rows: list[dict]) -> Path:
    path = directory / name
    path.write_text(
        "\n".join(json.dumps(row, sort_keys=True) for row in rows) + "\n",
        encoding="utf-8",
    )
    return path


def _write_canned_artifact(directory: Path) -> Path:
    return _write_artifact(directory, "canned_snapshot.jsonl",
                           _canned_artifact_lines())


def _rich_artifact_lines() -> list[dict]:
    """Every §30 row family the provider must project (native-valid rows)."""
    return [
        _artifact_header(),
        {"s": "symbol", "i": "10-1", "key": "pkg|def|main", "kind": "Function",
         "name": "main", "module": "pkg", "pub": True, "generic": False},
        {"s": "symbol", "i": "10-2", "key": "pkg|def|helper", "kind": "Function",
         "name": "helper", "module": "pkg", "pub": False, "generic": False},
        {"s": "call", "from": "10-1", "to": "10-2", "ekind": "Direct"},
        {"s": "type", "i": "11-1", "key": "pkg|Struct|Item", "tkind": "Struct",
         "name": "Item", "module": "pkg", "generic_arity": 1, "pub": True},
        {"s": "type", "i": "12-1", "key": "pkg|Trait|Show", "tkind": "Trait",
         "name": "Show", "module": "pkg", "generic_arity": 0, "pub": True},
        {"s": "field", "o": "11-1", "name": "x", "index": 0, "ty": "i64",
         "member": "m1", "ml": "field|1", "pub": True},
        {"s": "variant", "o": "11-1", "name": "A", "index": 0,
         "payload": "let|v|i64", "member": "m2", "ml": "variant|1"},
        {"s": "signature", "f": "10-1", "params": "let|x|i64", "ret": "i64",
         "effects": "", "variadic": False},
        {"s": "trait-method", "o": "11-1", "name": "run", "index": 0,
         "params": "let|self|Self", "ret": "unit", "member": "m3",
         "ml": "method|1"},
        {"s": "mir", "f": "10-1", "blocks": 2, "statements": 3, "locals": 1,
         "reachable": True, "unsafe": False, "unknown": False, "flags": 0,
         "caps": "", "purity": "Pure", "pevidence": ""},
        {"s": "concrete-type", "i": "instance::Item<i64>",
         "template": "pkg|Struct|Item", "args": "i64", "size": 8, "align": 8,
         "status": "complete", "fields": "x@0:8"},
        {"s": "alloc-site", "f": "pkg|def|main", "site": "pkg|def|main#B0#S1",
         "kind": "Exact", "size": 16},
        {"s": "alloc-summary", "f": "pkg|def|main", "dynamic": 16, "arena": 0,
         "sites": 1, "usites": "", "blevel": "static-proof",
         "alevel": "static-proof", "slevel": "static-proof"},
        {"s": "stack-summary", "f": "pkg|def|main", "frame": 32, "max": 64,
         "recursive": False, "flevel": "static-bound", "mlevel": "static-bound"},
        {"s": "blocking-summary", "f": "pkg|def|main", "blocking": False,
         "bsites": "", "unbounded": False, "level": "static-proof"},
        {"s": "code-size-summary", "f": "pkg|def|main", "bytes": 42,
         "exact": True, "level": "static-proof"},
        {"s": "unsafe-fact", "i": "40-1", "f": "pkg|def|main",
         "ukind": "raw-deref", "site": "pkg|def|main#B0#S2"},
        {"s": "drop-plan", "f": "pkg|def|main", "place": "p0",
         "site": "pkg|def|main#B0", "paths": "a;;b", "kind": "sink"},
        {"s": "dma", "f": "pkg|def|main", "place": "buf",
         "state": "pinned-readwrite", "op": "commit",
         "site": "pkg|def|main#B0#S3", "pid": "7-7"},
        {"s": "test", "test": "30-1", "target": "10-1",
         "tkey": "pkg|test@unit#t_main", "tkind": "unit", "tname": "t_main",
         "tattrs": ""},
        {"s": "coverage", "f": "10-1", "branch": "pkg|def|main#B0", "arm": "",
         "kind": "Block", "test": "pkg|test@unit#t_main"},
        {"s": "abi-surface", "surface": "fn:pkg|def|main",
         "symbol": "pkg|def|main", "kind": "fn", "size": -1, "align": -1,
         "args": "INTEGER", "ret": "INTEGER", "fields": "", "conv": "sysv",
         "extern": "main", "pclasses": "INTEGER", "plocs": "rdi", "ownin": "let",
         "ownout": "let", "null": "nonnull", "variadic": False, "ext": "",
         "platform": "linux", "failure": "return", "thread": "safe",
         "taint": "none", "boundary": "none"},
        {"s": "dep-type-use", "user": "pkg|def|main", "used": "pkg|Struct|Item"},
        {"s": "dep-trait-impl",
         "impl": "impl::pkg|Struct|Item|as|pkg|Trait|Show",
         "trait": "pkg|Trait|Show", "self": "pkg|Struct|Item"},
        {"s": "dep-trait-select", "fn": "pkg|def|main",
         "trait": "pkg|Trait|Show",
         "impl": "impl::pkg|Struct|Item|as|pkg|Trait|Show"},
        {"s": "dep-generic-inst", "instance": "instance::Item<i64>",
         "template": "pkg|Struct|Item"},
        {"s": "dep-layout", "dependent": "pkg|Struct|Item",
         "source": "pkg|Struct|Inner"},
        {"s": "dep-const-eval", "dependent": "pkg|def|main#B0#S1",
         "const": "pkg|const|N"},
        {"s": "dep-derived-body", "derived": "pkg|def|clone",
         "source": "pkg|Struct|Item"},
        {"s": "dep-contract-ref", "contract": "pkg|def|main|Pre|> x | 0",
         "symbol": "pkg|def|helper"},
        {"s": "dep-abi", "surface": "fn:pkg|def|main", "type": "pkg|Struct|Item"},
        {"s": "contract", "i": "20-1", "f": "10-1", "ckind": "Pre",
         "text": "> x | 0", "fp": "21-1", "msg": "x must stay positive"},
        {"s": "dep-completeness", "family": "Call", "status": "partial"},
        {"s": "dep-completeness", "family": "TestReferences", "status": "complete"},
        {"s": "dep-completeness", "family": "TraitImpl", "status": "partial"},
        {"s": "dep-completeness", "family": "AbiDependency", "status": "partial"},
        {"s": "dep-completeness", "family": "TypeUse", "status": "complete"},
    ]


class TestGenericStaticProvider(unittest.TestCase):
    def test_snapshot_over_mini_repo(self):
        provider = GenericStaticProvider()
        snapshot = provider.snapshot(FIXTURE)

        self.assertIsInstance(snapshot, ProviderSnapshot)
        self.assertGreater(len(snapshot.entities), 0)
        self.assertGreater(len(snapshot.relations), 0)

        verdicts = {cap.family: cap.verdict for cap in snapshot.capabilities}
        self.assertEqual(verdicts["entities"], "complete")
        self.assertEqual(verdicts["relations"], "partial")
        self.assertEqual(verdicts["calls"], "unavailable")
        self.assertEqual(verdicts["runtime"], "unknown")
        self.assertEqual(provider.completeness("entities"), "complete")

        # Unresolved imports are preserved, never dropped.
        import_edges = [u for u in snapshot.unresolved if u.kind == "imports"]
        self.assertTrue(import_edges)
        raw_targets = {u.dst_raw for u in import_edges}
        self.assertIn("app.store", raw_targets)
        self.assertIn("collections", raw_targets)
        app_store = next(u for u in import_edges if u.dst_raw == "app.store")
        self.assertIn(app_store.completeness, COMPLETENESS_VERDICTS)
        self.assertIn(
            "file:app/store.py", list(app_store.candidates),
            "a computable in-corpus candidate must be offered",
        )
        # External stdlib targets have no in-corpus candidate: no guessing.
        collections_edge = next(
            u for u in import_edges if u.dst_raw == "collections"
        )
        self.assertEqual(list(collections_edge.candidates), [])
        self.assertEqual(collections_edge.provider, GENERIC_ID)

        # Every unresolved import corresponds to an extraction relation:
        # nothing was silently dropped.
        self.assertTrue(all(u.kind for u in snapshot.unresolved))

    def test_query_and_delta_shapes(self):
        provider = GenericStaticProvider()
        snapshot = provider.snapshot(FIXTURE)
        answer = provider.query(snapshot, "entities", kind="File")
        self.assertEqual(answer["kind"], "entities")
        self.assertTrue(answer["records"])
        delta = provider.delta(snapshot, snapshot)
        self.assertEqual(
            set(delta), {"added", "removed", "changed", "unresolved_added"}
        )
        self.assertEqual(delta["added"], [])
        self.assertEqual(delta["removed"], [])


class TestNativeFramingHelpers(unittest.TestCase):
    def test_request_frame_layout(self):
        frame = frame_request(1, 7, "revision", "")
        (length,) = struct.unpack(">I", frame[:4])
        self.assertEqual(length, len(frame) - 4)
        at, fields = 4, []
        while at < len(frame):
            (flen,) = struct.unpack(">I", frame[at:at + 4])
            at += 4
            fields.append(frame[at:at + flen].decode("utf-8"))
            at += flen
        self.assertEqual(fields, ["1", "7", "revision", ""])

    def test_response_parser_roundtrip_and_fail_closed(self):
        body = b""
        for text in ("1", "9", "true", "revision", "1", "123-456", ""):
            payload = text.encode("utf-8")
            body += struct.pack(">I", len(payload)) + payload
        parsed = parse_response_body(body)
        self.assertEqual(parsed["protocol_version"], 1)
        self.assertEqual(parsed["request_id"], 9)
        self.assertTrue(parsed["ok"])
        self.assertEqual(parsed["kind"], "revision")
        self.assertEqual(parsed["keys"], ["123-456"])
        with self.assertRaises(NativeProtocolError):
            parse_response_body(body + b"\x00")
        bad_ok = b""
        for text in ("1", "9", "maybe", "revision", "1", "123-456", ""):
            payload = text.encode("utf-8")
            bad_ok += struct.pack(">I", len(payload)) + payload
        with self.assertRaises(NativeProtocolError):
            parse_response_body(bad_ok)


class TestNativeDegrade(unittest.TestCase):
    def test_unavailable_without_binary_or_artifact(self):
        with _clean_env():
            provider = TangerineNativeProvider()
            with tempfile.TemporaryDirectory() as tmp:
                snapshot = provider.snapshot(tmp)

        self.assertIsInstance(snapshot, ProviderSnapshot)
        self.assertEqual(snapshot.entities, [])
        self.assertEqual(snapshot.relations, [])
        self.assertEqual(snapshot.facts, [])
        self.assertEqual(snapshot.unresolved, [])
        self.assertTrue(snapshot.evidence)
        note = snapshot.evidence[0].summary
        self.assertTrue(note)
        verdicts = {cap.family: cap.verdict for cap in snapshot.capabilities}
        self.assertTrue(verdicts)
        self.assertTrue(all(v == "unavailable" for v in verdicts.values()))
        self.assertEqual(provider.completeness("entities"), "unavailable")
        self.assertTrue(
            all(cap.note for cap in snapshot.capabilities),
            "degraded capabilities must carry an explicit note",
        )

    def test_missing_explicit_artifact_degrades(self):
        with _clean_env():
            with tempfile.TemporaryDirectory() as tmp:
                provider = TangerineNativeProvider(
                    artifact=os.path.join(tmp, "does-not-exist.jsonl")
                )
                snapshot = provider.snapshot(tmp)
        self.assertEqual(snapshot.entities, [])
        self.assertTrue(
            all(cap.verdict == "unavailable" for cap in snapshot.capabilities)
        )


class TestNativeDiscovery(unittest.TestCase):
    def test_release_compiler_default_is_build_tg(self):
        from system_intel.providers import tangerine_native as native_module
        # The release driver materialized by the bootstrap lane; the old
        # build/bootstrap/tg ladder stage is never consulted.
        self.assertEqual(native_module.DEFAULT_BINARY, "build/tg")

    def test_root_build_tg_is_discovered_without_env(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "build").mkdir()
            fake = root / "build" / "tg"
            fake.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
            with _clean_env():
                provider = TangerineNativeProvider()
                located = provider._locate_binary(root)
        self.assertEqual(located, fake)

    def test_explicit_overrides_win_over_root_build_tg(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            env_override = _write_fake_compiler(tmp_path)
            ctor_override = tmp_path / "ctor_tg"
            ctor_override.write_text("#!/bin/sh\nexit 0\n")
            root = tmp_path / "root"
            (root / "build").mkdir(parents=True)
            (root / "build" / "tg").write_text("#!/bin/sh\nexit 0\n")
            with _clean_env(), _env(TANGERINE_NATIVE_COMPILER=str(env_override)):
                self.assertEqual(
                    TangerineNativeProvider()._locate_binary(root), env_override
                )
                self.assertEqual(
                    TangerineNativeProvider(binary=str(ctor_override))
                    ._locate_binary(root),
                    ctor_override,
                )


class TestNativeFramingWithFakeCompiler(unittest.TestCase):
    def test_frames_request_and_projects_keys(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            fake = _write_fake_compiler(tmp_path)
            log = tmp_path / "requests.log"
            root = tmp_path / "root"
            root.mkdir()
            with _clean_env(), _env(
                TANGERINE_NATIVE_COMPILER=str(fake),
                SYSTEM_INTEL_FAKE_LOG=str(log),
            ):
                provider = TangerineNativeProvider()
                self.assertTrue(provider.applies_to(root))
                snapshot = provider.snapshot(root)

            # The provider discovered the binary via the env and framed the
            # first §39 request correctly; the fake echoes protocol_version
            # (field 0) and request_id (field 1) into the response.
            self.assertTrue(log.is_file(), "fake compiler was not invoked")
            first = log.read_text(encoding="utf-8").splitlines()[0]
            pv, rid, op, payload = first.split("|")
            self.assertEqual(pv, "1")
            self.assertEqual(rid, "1")
            self.assertEqual(op, "revision")
            self.assertEqual(payload, "")

            # The revision digest came back through the wire and was
            # projected as a fact (never fabricated).
            self.assertTrue(
                any(fact.object == "123-456" for fact in snapshot.facts),
                f"revision key not projected: {snapshot.facts!r}",
            )
            self.assertTrue(
                any(ev.kind == "native_server" for ev in snapshot.evidence)
            )
            self.assertEqual(snapshot.provider_id, NATIVE_ID)
            # No artifact: entities are only what the wire enumerated.
            self.assertEqual(provider.completeness("entities"), "partial")
            self.assertEqual(provider.completeness("runtime"), "unknown")

    def test_server_symbol_projection_without_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            fake = _write_fake_compiler(tmp_path)
            root = tmp_path / "root"
            root.mkdir()
            with _clean_env(), _env(TANGERINE_NATIVE_COMPILER=str(fake)):
                snapshot = TangerineNativeProvider().snapshot(root)
        symbols = [
            e for e in snapshot.entities
            if e.attrs.get("source") == "symbol_search"
        ]
        # Server-only rows carry no persistent digest: the deterministic
        # textual fallback is used and recorded as degraded identity.
        self.assertEqual(
            {e.stable_id for e in symbols},
            {"native:sym:pkg|Struct|Item", "native:sym:pkg|def|main"},
        )
        self.assertTrue(symbols)
        self.assertTrue(all(e.attrs.get("identity_degraded") for e in symbols))
        self.assertTrue(
            all(e.attrs.get("identity_basis") == "textual-key" for e in symbols)
        )

    def test_compile_route_materializes_the_artifact(self):
        # The documented TANGERINE_SNAPSHOT compile route: compiler present,
        # root carries the tg_compiler entry, no explicit artifact env.
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            fake = _write_fake_compiler(tmp_path)
            template = _write_canned_artifact(tmp_path)
            root = tmp_path / "root"
            (root / "tg_compiler").mkdir(parents=True)
            (root / "tg_compiler" / "bootstrap_main.tg").write_text(
                "module bootstrap_main\n", encoding="utf-8"
            )
            with _clean_env(), _env(
                TANGERINE_NATIVE_COMPILER=str(fake),
                SYSTEM_INTEL_FAKE_ARTIFACT=str(template),
            ):
                provider = TangerineNativeProvider()
                snapshot = provider.snapshot(root)

            calls = [r for r in snapshot.relations if r.kind == "calls"]
            self.assertTrue(calls, "compiled artifact was not projected")
            # Identity scheme change (persistent native digest): the call
            # endpoint is the persistent declaration digest, not the key text.
            self.assertEqual(calls[0].src_key, "native:decl:10-1")
            self.assertTrue(
                any(ev.kind == "native_snapshot_artifact" and ev.digest
                    for ev in snapshot.evidence)
            )
            self.assertEqual(provider.completeness("calls"), "partial")


class TestNativeProjection(unittest.TestCase):
    def test_artifact_projection(self):
        with tempfile.TemporaryDirectory() as tmp:
            provider = TangerineNativeProvider()
            with tempfile.TemporaryDirectory() as tmp2:
                artifact = _write_canned_artifact(Path(tmp2))
                fake = _write_fake_compiler(Path(tmp2))
                root = Path(tmp) / "root"
                root.mkdir()
                with _clean_env(), _env(
                    TANGERINE_NATIVE_SNAPSHOT=str(artifact),
                    TANGERINE_NATIVE_COMPILER=str(fake),
                ):
                    snapshot = provider.snapshot(root)

            # Calls: relation kind 'calls', stable ids from the persistent
            # declaration digests (identity scheme change), analysis_depth 3,
            # provider 'tangerine-native'.
            calls = [r for r in snapshot.relations if r.kind == "calls"]
            self.assertTrue(calls)
            call = calls[0]
            self.assertEqual(call.src_key, "native:decl:10-1")
            self.assertEqual(call.dst_key, "native:decl:10-2")
            self.assertEqual(call.analysis_depth, 3)
            self.assertEqual(call.provider, NATIVE_ID)

            # Indirect calls: explicit unresolved rows, EMPTY candidates,
            # completeness 'unknown' (mirrors the native model exactly).
            indirect = [u for u in snapshot.unresolved if u.kind == "calls"]
            self.assertTrue(indirect)
            self.assertEqual(indirect[0].completeness, "unknown")
            self.assertEqual(list(indirect[0].candidates), [])
            self.assertEqual(indirect[0].dst_raw, "fn(i64)->i64")

            # Types project as Symbol entities with the native type kind; the
            # stable id is the persistent declaration digest (identity scheme
            # change) and the textual key is an attribute.
            types = [
                e for e in snapshot.entities
                if e.attrs.get("native_family") == "type"
            ]
            self.assertEqual(types[0].kind, "Symbol")
            self.assertEqual(types[0].attrs["type_kind"], "Struct")
            self.assertEqual(types[0].stable_id, "native:decl:11-1")
            self.assertEqual(types[0].attrs["key"], "pkg|Struct|Item")

            # Contracts: Contract entities with epistemic_state 'declared'.
            contracts = [e for e in snapshot.entities if e.kind == "Contract"]
            self.assertTrue(contracts)
            self.assertEqual(contracts[0].epistemic_state, "declared")
            self.assertEqual(contracts[0].attrs["expression"], "> x | 0")
            self.assertTrue(
                any(r.kind == "constrained_by" for r in snapshot.relations)
            )

            # Tests: Test entity + typed tests relation to the exercised decl.
            tests = [e for e in snapshot.entities if e.kind == "Test"]
            self.assertTrue(tests)
            test_edges = [r for r in snapshot.relations if r.kind == "tests"]
            self.assertTrue(test_edges)
            self.assertEqual(test_edges[0].src_key, tests[0].stable_id)
            self.assertEqual(test_edges[0].dst_key, "native:decl:10-2")
            self.assertEqual(test_edges[0].analysis_depth, 3)

            # Facts at depth 3 for effects/capabilities/ownership.
            for predicate in ("effect", "capability", "ownership"):
                matching = [f for f in snapshot.facts if f.predicate == predicate]
                self.assertTrue(matching, predicate)
                self.assertEqual(matching[0].analysis_depth, 3)
                self.assertEqual(matching[0].provider, NATIVE_ID)

            # Revision + surface hashes read from the artifact header.
            self.assertEqual(
                snapshot.semantic_configuration.get("target"),
                "x86_64-unknown-linux-gnu",
            )
            self.assertTrue(
                any(
                    ev.kind == "native_snapshot_artifact" and ev.digest
                    for ev in snapshot.evidence
                )
            )

    def test_completeness_mirrors_and_never_upgrades(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            artifact = _write_canned_artifact(tmp_path)
            root = tmp_path / "root"
            root.mkdir()
            with _clean_env(), _env(TANGERINE_NATIVE_SNAPSHOT=str(artifact)):
                provider = TangerineNativeProvider()
                snapshot = provider.snapshot(root)

            # Call producer status is 'partial' in the canned artifact: the
            # provider must say partial, never complete.
            self.assertEqual(provider.completeness("calls"), "partial")
            self.assertEqual(snapshot.completeness("calls"), "partial")
            self.assertEqual(provider.completeness("tests"), "complete")
            self.assertEqual(provider.completeness("relations"), "partial")
            self.assertEqual(provider.completeness("entities"), "complete")
            self.assertEqual(provider.completeness("runtime"), "unknown")


class TestNativeIdentity(unittest.TestCase):
    def test_stable_ids_use_persistent_digests(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            artifact = _write_canned_artifact(tmp_path)
            root = tmp_path / "root"
            root.mkdir()
            with _clean_env(), _env(TANGERINE_NATIVE_SNAPSHOT=str(artifact)):
                snapshot = TangerineNativeProvider().snapshot(root)

        symbols = [
            e for e in snapshot.entities
            if e.attrs.get("native_family") == "symbol"
        ]
        self.assertEqual(
            {e.stable_id for e in symbols},
            {"native:decl:10-1", "native:decl:10-2"},
        )
        for entity in symbols:
            self.assertFalse(entity.attrs["identity_degraded"])
            self.assertEqual(
                entity.attrs["identity_basis"], "persistent-decl-digest"
            )
            self.assertTrue(entity.attrs["key"])
        calls = [r for r in snapshot.relations if r.kind == "calls"]
        self.assertEqual(calls[0].src_key, "native:decl:10-1")
        self.assertEqual(calls[0].dst_key, "native:decl:10-2")
        tests = [e for e in snapshot.entities if e.kind == "Test"]
        self.assertEqual(tests[0].stable_id, "native:test:30-1")
        self.assertEqual(tests[0].attrs["tkey"], "pkg|test@unit#t_helper")
        contracts = [e for e in snapshot.entities if e.kind == "Contract"]
        self.assertEqual(contracts[0].stable_id, "native:contract:20-1")
        self.assertEqual(
            contracts[0].attrs["contract_key"], "pkg|def|main|Pre|> x | 0"
        )

    def test_zero_digest_falls_back_to_degraded_textual_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            artifact = _write_artifact(tmp_path, "zero_digest.jsonl", [
                _artifact_header(),
                {"s": "symbol", "i": "0-0", "key": "pkg|def|ghost",
                 "kind": "Function", "name": "ghost", "module": "pkg",
                 "pub": False, "generic": False},
            ])
            root = tmp_path / "root"
            root.mkdir()
            with _clean_env(), _env(TANGERINE_NATIVE_SNAPSHOT=str(artifact)):
                snapshot = TangerineNativeProvider().snapshot(root)

        symbols = [
            e for e in snapshot.entities
            if e.attrs.get("native_family") == "symbol"
        ]
        self.assertEqual(len(symbols), 1)
        self.assertEqual(symbols[0].stable_id, "native:sym:pkg|def|ghost")
        self.assertTrue(symbols[0].attrs["identity_degraded"])


class TestNativeProjectionExpansion(unittest.TestCase):
    def test_all_artifact_row_families_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            artifact = _write_artifact(
                tmp_path, "rich_snapshot.jsonl", _rich_artifact_lines()
            )
            root = tmp_path / "root"
            root.mkdir()
            with _clean_env(), _env(TANGERINE_NATIVE_SNAPSHOT=str(artifact)):
                provider = TangerineNativeProvider()
                snapshot = provider.snapshot(root)

        kinds = {e.kind for e in snapshot.entities}
        self.assertTrue(
            {"Repository", "Symbol", "Contract", "Test", "API"} <= kinds
        )
        self.assertEqual(provider.completeness("entities"), "complete")

        predicates = {f.predicate for f in snapshot.facts}
        for predicate in (
            "native.revision", "native.public_api_hash", "native.abi_hash",
            "native.unsafe_hash", "member", "signature", "mir", "layout",
            "alloc_site", "alloc_summary", "stack", "blocking", "code_size",
            "unsafe", "drop_plan", "dma", "coverage", "contract_ref",
        ):
            self.assertIn(predicate, predicates)

        relation_kinds = {r.kind for r in snapshot.relations}
        self.assertTrue(
            {"calls", "tests", "constrained_by", "depends_on", "implements"}
            <= relation_kinds
        )
        roles = {r.attrs.get("role") for r in snapshot.relations}
        self.assertTrue({
            "type_use", "trait_impl", "trait_selection",
            "generic_instantiation", "layout_dependency",
            "const_eval_dependency", "derived_body", "contract_reference",
            "abi_dependency", "abi_surface", "coverage",
        } <= roles)

        # Typed dependency endpoints resolve text keys to persistent digests.
        type_use = next(
            r for r in snapshot.relations if r.attrs.get("role") == "type_use"
        )
        self.assertEqual(type_use.src_key, "native:decl:10-1")
        self.assertEqual(type_use.dst_key, "native:decl:11-1")
        self.assertFalse(type_use.attrs["identity_degraded"])
        impl = next(r for r in snapshot.relations if r.kind == "implements")
        self.assertEqual(impl.dst_key, "native:decl:12-1")

        # Contract canonicalization: the machine-readable (kind, name) pair
        # rides the contract_ref facts for both declarations and references.
        expected_contract = "contract:Pre:pkg|def|main|Pre|> x | 0"
        declarations = [
            f for f in snapshot.facts
            if f.predicate == "contract_ref"
            and f.attrs.get("role") == "declaration"
        ]
        references = [
            f for f in snapshot.facts
            if f.predicate == "contract_ref"
            and f.attrs.get("role") == "reference"
        ]
        self.assertEqual(declarations[0].object, expected_contract)
        self.assertEqual(references[0].object, expected_contract)
        self.assertEqual(references[0].attrs["contract_kind"], "Pre")
        self.assertFalse(references[0].attrs["contract_kind_unresolved"])
        self.assertEqual(references[0].attrs["referenced_symbol"], "pkg|def|helper")

        # Coverage binds the exercising test to the covered declaration.
        coverage_edges = [
            r for r in snapshot.relations if r.attrs.get("role") == "coverage"
        ]
        self.assertTrue(coverage_edges)
        self.assertEqual(coverage_edges[0].src_key, "native:test:30-1")
        self.assertEqual(coverage_edges[0].dst_key, "native:decl:10-1")

        repo = next(e for e in snapshot.entities if e.stable_id == "repo:.")
        self.assertEqual(
            repo.attrs["surface_hashes"]["public_api_hash"], "3-3"
        )
        api = next(e for e in snapshot.entities if e.kind == "API")
        self.assertEqual(api.stable_id, "native:abi:fn:pkg|def|main")
        self.assertEqual(api.attrs["size"], -1)


def _delta_artifact_rows(revision: str, extra: list[dict]) -> list[dict]:
    return [_artifact_header(revision=revision)] + extra


class TestNativeDelta(unittest.TestCase):
    def test_native_artifact_delta_translates_persistent_keys(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            old_path = _write_artifact(tmp_path, "old.jsonl", _delta_artifact_rows(
                "100-200",
                [
                    {"s": "symbol", "i": "10-1", "key": "pkg|def|main",
                     "kind": "Function", "name": "main", "module": "pkg",
                     "pub": True, "generic": False},
                    {"s": "symbol", "i": "10-2", "key": "pkg|def|helper",
                     "kind": "Function", "name": "helper", "module": "pkg",
                     "pub": False, "generic": False},
                    {"s": "test", "test": "30-1", "target": "10-2",
                     "tkey": "pkg|test@unit#t_helper", "tkind": "unit",
                     "tname": "t_helper", "tattrs": ""},
                    {"s": "contract", "i": "20-1", "f": "10-1", "ckind": "Pre",
                     "text": "> x | 0", "fp": "21-1", "msg": "m"},
                    {"s": "indirect", "caller": "pkg|def|main",
                     "site": "pkg|def|main#B0#T", "sig": "fn(i64)->i64",
                     "candidates": "", "completeness": "Unknown"},
                ],
            ))
            new_path = _write_artifact(tmp_path, "new.jsonl", _delta_artifact_rows(
                "300-400",
                [
                    {"s": "symbol", "i": "10-1", "key": "pkg|def|renamed",
                     "kind": "Function", "name": "renamed", "module": "pkg",
                     "pub": True, "generic": False},
                    {"s": "symbol", "i": "10-3", "key": "pkg|def|fresh",
                     "kind": "Function", "name": "fresh", "module": "pkg",
                     "pub": True, "generic": False},
                    {"s": "test", "test": "30-1", "target": "10-2",
                     "tkey": "pkg|test@unit#t_helper", "tkind": "unit",
                     "tname": "t_helper", "tattrs": ""},
                    {"s": "test", "test": "31-1", "target": "10-3",
                     "tkey": "pkg|test@unit#t_fresh", "tkind": "unit",
                     "tname": "t_fresh", "tattrs": ""},
                    {"s": "contract", "i": "20-1", "f": "10-1", "ckind": "Pre",
                     "text": "> x | 0", "fp": "21-1", "msg": "m"},
                    {"s": "indirect", "caller": "pkg|def|renamed",
                     "site": "pkg|def|renamed#B0#T", "sig": "fn(i64)->i64",
                     "candidates": "", "completeness": "Unknown"},
                ],
            ))
            root = tmp_path / "root"
            root.mkdir()
            provider = TangerineNativeProvider()
            with _clean_env(), _env(TANGERINE_NATIVE_SNAPSHOT=str(old_path)):
                old_snapshot = provider.snapshot(root)
            with _env(TANGERINE_NATIVE_SNAPSHOT=str(new_path)):
                new_snapshot = provider.snapshot(root)
            delta = provider.delta(old_snapshot, new_snapshot)

        self.assertEqual(delta["source"], "native")
        self.assertEqual(
            delta["added"], ["native:decl:10-3", "native:test:31-1"]
        )
        self.assertEqual(delta["removed"], ["native:decl:10-2"])
        # Same persistent digest, changed textual/name attributes: a rename
        # is a 'changed' entity, never an add+remove.
        self.assertEqual(delta["changed"], ["native:decl:10-1"])
        self.assertEqual(len(delta["unresolved_added"]), 1)
        self.assertTrue(delta["note"])

    def test_generic_fallback_records_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            artifact = _write_canned_artifact(tmp_path)
            root = tmp_path / "root"
            root.mkdir()
            provider_a = TangerineNativeProvider(artifact=str(artifact))
            provider_b = TangerineNativeProvider()  # server-only / degraded
            with _clean_env():
                snapshot_a = provider_a.snapshot(root)
                snapshot_b = provider_b.snapshot(root)
                # snapshot_b carries no native artifact evidence, so the
                # native pair delta is unavailable for provider_a.
                delta = provider_a.delta(snapshot_a, snapshot_b)
        self.assertEqual(delta["source"], "generic")
        self.assertTrue(
            {"added", "removed", "changed", "unresolved_added"} <= set(delta)
        )
        self.assertTrue(delta["note"])


class TestNativeCorruption(unittest.TestCase):
    def test_unknown_future_tag_is_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            lines = _canned_artifact_lines() + [{"s": "future-family", "x": 1}]
            artifact = _write_artifact(tmp_path, "future.jsonl", lines)
            root = tmp_path / "root"
            root.mkdir()
            with _clean_env(), _env(TANGERINE_NATIVE_SNAPSHOT=str(artifact)):
                provider = TangerineNativeProvider()
                snapshot = provider.snapshot(root)

        self.assertEqual(provider.completeness("entities"), "complete")
        self.assertTrue([e for e in snapshot.entities if e.kind == "Symbol"])
        artifact_ev = next(
            ev for ev in snapshot.evidence
            if ev.kind == "native_snapshot_artifact"
        )
        self.assertTrue(any(
            "unknown future row tag" in note
            for note in artifact_ev.payload["parse_notes"]
        ))
        self.assertFalse(artifact_ev.payload["rejected"])

    def test_malformed_known_family_row_invalidates_family(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            lines = [
                _artifact_header(),
                {"s": "symbol", "i": "not-a-digest", "key": "pkg|def|main",
                 "kind": "Function", "name": "main", "module": "pkg",
                 "pub": True, "generic": False},
            ] + _canned_artifact_lines()[1:]
            artifact = _write_artifact(tmp_path, "bad_family.jsonl", lines)
            root = tmp_path / "root"
            root.mkdir()
            with _clean_env(), _env(TANGERINE_NATIVE_SNAPSHOT=str(artifact)):
                provider = TangerineNativeProvider()
                snapshot = provider.snapshot(root)

        self.assertEqual(provider.completeness("entities"), "unavailable")
        self.assertFalse([
            e for e in snapshot.entities
            if e.attrs.get("native_family") == "symbol"
        ])
        artifact_ev = next(
            ev for ev in snapshot.evidence
            if ev.kind == "native_snapshot_artifact"
        )
        self.assertEqual(artifact_ev.payload["invalid_families"], ["symbol"])
        self.assertTrue(any(
            "family invalidated" in note
            for note in artifact_ev.payload["parse_notes"]
        ))
        # Families outside the corruption keep projecting.
        self.assertTrue([r for r in snapshot.relations if r.kind == "calls"])

    def test_malformed_or_missing_header_rejects_artifact(self):
        cases = {
            "bad-version": [
                _artifact_header(v=2),
                {"s": "symbol", "i": "10-1", "key": "pkg|def|main",
                 "kind": "Function", "name": "main", "module": "pkg",
                 "pub": True, "generic": False},
            ],
            "missing-field": [
                {k: v for k, v in _artifact_header().items()
                 if k != "revision"},
            ],
            "headerless": [
                {"s": "symbol", "i": "10-1", "key": "pkg|def|main",
                 "kind": "Function", "name": "main", "module": "pkg",
                 "pub": True, "generic": False},
            ],
            "bad-completeness": [
                _artifact_header(),
                {"s": "dep-completeness", "family": "Call", "status": "banana"},
            ],
        }
        for name, lines in cases.items():
            with self.subTest(case=name):
                with tempfile.TemporaryDirectory() as tmp:
                    tmp_path = Path(tmp)
                    artifact = _write_artifact(
                        tmp_path, f"{name}.jsonl", lines
                    )
                    root = tmp_path / "root"
                    root.mkdir()
                    with _clean_env(), _env(
                        TANGERINE_NATIVE_SNAPSHOT=str(artifact)
                    ):
                        provider = TangerineNativeProvider()
                        snapshot = provider.snapshot(root)
                self.assertEqual(snapshot.entities, [])
                self.assertEqual(snapshot.relations, [])
                self.assertTrue(all(
                    cap.verdict == "unavailable"
                    for cap in snapshot.capabilities
                ))
                summary = " | ".join(ev.summary for ev in snapshot.evidence)
                self.assertIn("rejected", summary)


class TestNativeServerTimeout(unittest.TestCase):
    def test_hung_server_is_bounded_and_degraded(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            fake = _write_fake_compiler(tmp_path)
            root = tmp_path / "root"
            root.mkdir()
            with _clean_env(), _env(
                TANGERINE_NATIVE_COMPILER=str(fake),
                SYSTEM_INTEL_FAKE_HANG="1",
            ):
                provider = TangerineNativeProvider(server_timeout=1.0)
                started = time.monotonic()
                snapshot = provider.snapshot(root)
                elapsed = time.monotonic() - started
            self.assertLess(
                elapsed, 15.0,
                "the hung server must not block the scan",
            )
            summaries = " | ".join(ev.summary for ev in snapshot.evidence)
            self.assertIn("wall-clock bound", summaries)
            self.assertIn("hung server", summaries)


class TestRegistry(unittest.TestCase):
    def test_default_order(self):
        providers = default_providers()
        self.assertEqual(
            [p.provider_id for p in providers],
            ["tangerine-native", "generic-static"],
        )

    def test_provider_set_digest_stability(self):
        first = provider_set_digest(default_providers())
        second = provider_set_digest(default_providers())
        self.assertEqual(first, second)
        self.assertEqual(len(first), 64)
        self.assertTrue(all(c in "0123456789abcdef" for c in first))
        self.assertNotEqual(
            first,
            provider_set_digest([GenericStaticProvider()]),
        )

    def test_select_for_orders_by_authority(self):
        selected = select_for(FIXTURE)
        self.assertEqual(selected[0].provider_id, "tangerine-native")
        self.assertEqual(selected[-1].provider_id, "generic-static")
        with tempfile.TemporaryDirectory() as tmp:
            with _clean_env():
                only_generic = select_for(tmp)
        self.assertEqual(
            [p.provider_id for p in only_generic], ["generic-static"]
        )


class TestSPIConformance(unittest.TestCase):
    def test_every_default_provider_speaks_the_spi(self):
        with _clean_env():
            providers = default_providers()
            for provider in providers:
                with self.subTest(provider=provider.provider_id):
                    identity = provider.identity(FIXTURE)
                    self.assertIsInstance(identity, dict)
                    self.assertIn("repo_root", identity)

                    capabilities = provider.capabilities()
                    self.assertIsInstance(capabilities, list)
                    self.assertTrue(capabilities)
                    for cap in capabilities:
                        self.assertIsInstance(cap, ProviderCapability)
                        self.assertTrue(cap.family)
                        self.assertIn(cap.verdict, COMPLETENESS_VERDICTS)

                    snapshot = provider.snapshot(FIXTURE)
                    self.assertIsInstance(snapshot, ProviderSnapshot)
                    for field_name in (
                        "entities", "relations", "facts", "unresolved",
                        "evidence", "providers", "semantic_configuration",
                    ):
                        self.assertTrue(hasattr(snapshot, field_name), field_name)
                    self.assertIsInstance(snapshot.semantic_configuration, dict)
                    self.assertIsInstance(snapshot.providers, list)

                    answer = provider.query(snapshot, "entities")
                    self.assertIsInstance(answer, dict)
                    self.assertIn("kind", answer)

                    delta = provider.delta(snapshot, snapshot)
                    # The federation delta carries the four typed-key sets;
                    # tangerine-native additionally records which delta source
                    # it used ('native' artifact delta vs generic fallback).
                    self.assertTrue(
                        {"added", "removed", "changed", "unresolved_added"}
                        <= set(delta)
                    )
                    if "source" in delta:
                        self.assertIn(delta["source"], ("native", "generic"))

                    verdict = provider.completeness("entities")
                    self.assertIn(verdict, COMPLETENESS_VERDICTS)


if __name__ == "__main__":
    unittest.main()
