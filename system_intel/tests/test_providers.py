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
\"\"\"Fake Tangerine native compiler speaking the §39 v1 framed protocol.\"\"\"
import os
import struct
import sys

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
"""


def _write_fake_compiler(directory: Path) -> Path:
    path = directory / "fake_tg"
    path.write_text(FAKE_COMPILER_SOURCE, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


def _canned_artifact_lines() -> list[dict]:
    return [
        {
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
        },
        {
            "s": "symbol", "i": "10-1", "key": "pkg|def|main", "kind": "Fn",
            "name": "main", "module": "pkg", "pub": True, "generic": False,
        },
        {
            "s": "symbol", "i": "10-2", "key": "pkg|def|helper", "kind": "Fn",
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


def _write_canned_artifact(directory: Path) -> Path:
    path = directory / "canned_snapshot.jsonl"
    lines = [
        json.dumps(row, sort_keys=True) for row in _canned_artifact_lines()
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


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
        self.assertEqual(
            {e.stable_id for e in symbols},
            {"native:sym:pkg|Struct|Item", "native:sym:pkg|def|main"},
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
            self.assertEqual(calls[0].src_key, "native:sym:pkg|def|main")
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

            # Calls: relation kind 'calls', stable ids from caller/callee
            # keys, analysis_depth 3, provider 'tangerine-native'.
            calls = [r for r in snapshot.relations if r.kind == "calls"]
            self.assertTrue(calls)
            call = calls[0]
            self.assertEqual(call.src_key, "native:sym:pkg|def|main")
            self.assertEqual(call.dst_key, "native:sym:pkg|def|helper")
            self.assertEqual(call.analysis_depth, 3)
            self.assertEqual(call.provider, NATIVE_ID)

            # Indirect calls: explicit unresolved rows, EMPTY candidates,
            # completeness 'unknown' (mirrors the native model exactly).
            indirect = [u for u in snapshot.unresolved if u.kind == "calls"]
            self.assertTrue(indirect)
            self.assertEqual(indirect[0].completeness, "unknown")
            self.assertEqual(list(indirect[0].candidates), [])
            self.assertEqual(indirect[0].dst_raw, "fn(i64)->i64")

            # Types project as Symbol entities with the native type kind.
            types = [
                e for e in snapshot.entities
                if e.attrs.get("native_family") == "type"
            ]
            self.assertEqual(types[0].kind, "Symbol")
            self.assertEqual(types[0].attrs["type_kind"], "Struct")
            self.assertEqual(types[0].stable_id, "native:type:pkg|Struct|Item")

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
            self.assertEqual(test_edges[0].dst_key, "native:sym:pkg|def|helper")
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
                    self.assertEqual(
                        set(delta),
                        {"added", "removed", "changed", "unresolved_added"},
                    )

                    verdict = provider.completeness("entities")
                    self.assertIn(verdict, COMPLETENESS_VERDICTS)


if __name__ == "__main__":
    unittest.main()
