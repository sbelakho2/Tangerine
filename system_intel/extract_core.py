"""Language-agnostic Tier 0 / Tier 1 extraction for system_intel.

The core is deliberately language-neutral: every adapter emits the same
universal entity/relation/fact vocabulary (see schema.sql).  Adapters are
pluggable; the default registry understands common manifest files, SQL,
configuration, deployment files, a generic code adapter for many
languages, and a fallback adapter for Tangerine (`.tg`) sources.

v2 semantics (INTERFACES.md §0/§4):

* Every entity carries a namespace-qualified ``stable_id``:
  ``file:<path>``, ``module:<path>``, ``sym:<lang>:<path>::<name>``,
  ``test:<path>::<name>``, ``pkg:<path>``, ``schema:<path>::<table>``,
  ``config:<path>::<KEY>``, ``repo:.``.
* Every entity/fact carries ``epistemic_state`` / ``analysis_depth`` /
  ``completeness`` / ``provider``.  Generic source symbols are
  ``observed`` / depth 1 / ``partial``; manifests are ``declared``.
* Relations carry typed endpoint keys (``src_key``/``dst_key`` plus the
  optional endpoint kinds) so the resolver matches exactly.
* The generic test extractor MUST NOT emit ``tests(rel, rel)``: a file-level
  test emits ``test:<rel>::<name>`` -> the exercised file when it can derive
  one, else an unresolved raw target.  The `.tg` adapter emits a typed
  ``tests`` relation for `@test` functions to their module.

This adapter is the zero-install FALLBACK only; entities are marked
``provider='generic-static'`` so authoritative providers can supersede it.

Nothing here mutates the scanned repository, and nothing crashes on
malformed input: unreadable/binary/large files degrade to a Tier 0 File
entity with a recorded uncertainty.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path

EXTRACTOR_PROVIDER_ID = "generic-static"
EXTRACTOR_PROVIDER_VERSION = "2.0"

SKIP_DIRS = {
    ".git",
    ".hg",
    ".svn",
    ".venv",
    "venv",
    "node_modules",
    "target",
    "build",
    "dist",
    "__pycache__",
    ".tox",
    ".mypy_cache",
    ".pytest_cache",
    "_build",
}

MAX_FILE_BYTES = 2 * 1024 * 1024

# ── stable ids (§4) ──────────────────────────────────────────────────────

REPO_STABLE_ID = "repo:."

_LANGUAGE_BY_SUFFIX = {
    ".rs": "rust", ".py": "python", ".js": "javascript", ".ts": "typescript",
    ".tsx": "typescript", ".jsx": "javascript", ".mjs": "javascript",
    ".c": "c", ".h": "c", ".cc": "cpp", ".cpp": "cpp", ".cxx": "cpp",
    ".hpp": "cpp", ".go": "go", ".java": "java", ".kt": "kotlin",
    ".cs": "csharp", ".rb": "ruby", ".php": "php", ".swift": "swift",
    ".sh": "shell", ".tg": "tg",
}


def language_for_suffix(suffix: str) -> str:
    return _LANGUAGE_BY_SUFFIX.get(suffix, (suffix or "").lstrip(".") or "unknown")


def stable_id_file(rel: str) -> str:
    return f"file:{rel}"


def stable_id_module(rel: str) -> str:
    return f"module:{rel}"


def stable_id_symbol(lang: str, rel: str, name: str) -> str:
    return f"sym:{lang}:{rel}::{name}"


def stable_id_test(rel: str, name: str) -> str:
    return f"test:{rel}::{name}"


def stable_id_package(rel: str) -> str:
    return f"pkg:{rel}"


def stable_id_schema(rel: str, table: str) -> str:
    return f"schema:{rel}::{table}"


def stable_id_config(rel: str, key: str) -> str:
    return f"config:{rel}::{key}"


# ── records ──────────────────────────────────────────────────────────────


@dataclass
class Entity:
    kind: str
    name: str
    qualified_name: str
    file: str | None = None
    line: int | None = None
    tier: int = 0
    provenance: str = "observed"
    confidence: float = 1.0
    derived_from: tuple[str, ...] = ()
    attrs: dict | None = None
    stable_id: str = ""
    epistemic_state: str = "observed"
    analysis_depth: int = 1
    completeness: str = "partial"
    provider: str = EXTRACTOR_PROVIDER_ID
    provider_revision: str = EXTRACTOR_PROVIDER_VERSION

    def key(self) -> tuple[str, str]:
        return (self.kind, self.qualified_name)


@dataclass
class Relation:
    src_key: str
    dst_key: str
    kind: str
    src_kind: str | None = None
    dst_kind: str | None = None
    tier: int = 1
    provenance: str = "inferred"
    confidence: float = 1.0
    derived_from: tuple[str, ...] = ()
    attrs: dict | None = None
    epistemic_state: str = "inferred"
    analysis_depth: int = 1
    completeness: str = "partial"


@dataclass
class Fact:
    subject: str
    predicate: str
    object: str
    tier: int = 0
    provenance: str = "observed"
    confidence: float = 1.0
    derived_from: tuple[str, ...] = ()
    uncertainty: str | None = None
    epistemic_state: str = "observed"
    analysis_depth: int = 1
    completeness: str = "partial"
    provider: str = EXTRACTOR_PROVIDER_ID
    provider_revision: str = EXTRACTOR_PROVIDER_VERSION
    stable_subject: str = ""


@dataclass
class Extraction:
    entities: list[Entity] = field(default_factory=list)
    relations: list[Relation] = field(default_factory=list)
    facts: list[Fact] = field(default_factory=list)

    def add_entity(self, ent: Entity) -> None:
        self.entities.append(ent)

    def add_relation(self, rel: Relation) -> None:
        self.relations.append(rel)

    def add_fact(self, fact: Fact) -> None:
        self.facts.append(fact)

    def merge(self, other: "Extraction") -> None:
        self.entities.extend(other.entities)
        self.relations.extend(other.relations)
        self.facts.extend(other.facts)


@dataclass
class ExtractContext:
    root: Path
    commit_sha: str | None = None
    files: set[str] = field(default_factory=set)
    extractions: Extraction = field(default_factory=Extraction)

    def rel(self, path: Path) -> str:
        return path.relative_to(self.root).as_posix()

    def has_file(self, rel: str) -> bool:
        return rel in self.files

    def find_file(self, candidates: list[str]) -> str | None:
        for cand in candidates:
            rel = cand.lstrip("./")
            if rel in self.files:
                return rel
        return None


# ── adapters ─────────────────────────────────────────────────────────────


class Adapter:
    name = "adapter"

    def detect(self, path: Path) -> bool:
        raise NotImplementedError

    def extract(self, path: Path, text: str, ctx: ExtractContext) -> Extraction | None:
        raise NotImplementedError


class AdapterRegistry:
    def __init__(self) -> None:
        self.adapters: list[Adapter] = []

    def register(self, adapter: Adapter) -> None:
        self.adapters.append(adapter)

    def for_path(self, path: Path) -> list[Adapter]:
        return [a for a in self.adapters if a.detect(path)]


# ── generic code adapter ─────────────────────────────────────────────────

_GENERIC_DEFS: dict[str, list[tuple[str, re.Pattern[str]]]] = {
    ".rs": [
        ("Symbol", re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn\s+([A-Za-z_]\w*)")),
        ("Symbol", re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?struct\s+([A-Za-z_]\w*)")),
        ("Symbol", re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?enum\s+([A-Za-z_]\w*)")),
        ("Symbol", re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?trait\s+([A-Za-z_]\w*)")),
        ("Symbol", re.compile(r"^\s*impl(?:<[^>]*>)?\s+(?:[A-Za-z_]\w*\s+for\s+)?([A-Za-z_]\w*)")),
        ("Symbol", re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:const|static)\s+([A-Za-z_]\w*)")),
        ("Module", re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+([A-Za-z_]\w*)")),
    ],
    ".c": [
        ("Symbol", re.compile(r"^[A-Za-z_][\w\s\*]*\b([A-Za-z_]\w*)\s*\([^;]*\)\s*\{")),
        ("Symbol", re.compile(r"^\s*(?:typedef\s+)?struct\s+([A-Za-z_]\w*)")),
        ("Symbol", re.compile(r"^\s*typedef\b.*\b([A-Za-z_]\w*)\s*;")),
        ("Symbol", re.compile(r"^\s*enum\s+([A-Za-z_]\w*)")),
    ],
    ".py": [
        ("Symbol", re.compile(r"^\s*def\s+([A-Za-z_]\w*)")),
        ("Symbol", re.compile(r"^\s*async\s+def\s+([A-Za-z_]\w*)")),
        ("Symbol", re.compile(r"^\s*class\s+([A-Za-z_]\w*)")),
        ("Symbol", re.compile(r"^([A-Z][A-Z0-9_]*)\s*=")),
    ],
    ".js": [
        ("Symbol", re.compile(r"^\s*(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)")),
        ("Symbol", re.compile(r"^\s*(?:export\s+)?class\s+([A-Za-z_$][\w$]*)")),
        ("Symbol", re.compile(r"^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=")),
        ("Symbol", re.compile(r"^\s*([A-Za-z_$][\w$]*)\s*\([^)]*\)\s*\{")),
        ("Symbol", re.compile(r"^\s*(?:export\s+)?interface\s+([A-Za-z_$][\w$]*)")),
    ],
    ".go": [
        ("Symbol", re.compile(r"^\s*func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)")),
        ("Symbol", re.compile(r"^\s*type\s+([A-Za-z_]\w*)\s+(?:struct|interface)")),
    ],
    ".java": [
        ("Symbol", re.compile(r"^\s*(?:public|private|protected)?\s*(?:static\s+)?(?:final\s+)?class\s+([A-Za-z_]\w*)")),
        ("Symbol", re.compile(r"^\s*(?:public\s+)?interface\s+([A-Za-z_]\w*)")),
        ("Symbol", re.compile(r"^\s*(?:public\s+)?enum\s+([A-Za-z_]\w*)")),
    ],
    ".sh": [
        ("Symbol", re.compile(r"^\s*(?:function\s+)?([A-Za-z_]\w*)\s*\(\s*\)\s*\{")),
    ],
}

_GENERIC_DEFS[".cc"] = _GENERIC_DEFS[".c"]
_GENERIC_DEFS[".cpp"] = _GENERIC_DEFS[".c"]
_GENERIC_DEFS[".h"] = _GENERIC_DEFS[".c"]
_GENERIC_DEFS[".hpp"] = _GENERIC_DEFS[".c"]
_GENERIC_DEFS[".ts"] = _GENERIC_DEFS[".js"]
_GENERIC_DEFS[".tsx"] = _GENERIC_DEFS[".js"]
_GENERIC_DEFS[".jsx"] = _GENERIC_DEFS[".js"]
_GENERIC_DEFS[".mjs"] = _GENERIC_DEFS[".js"]
_GENERIC_DEFS[".kt"] = _GENERIC_DEFS[".java"]
_GENERIC_DEFS[".cs"] = _GENERIC_DEFS[".java"]
_GENERIC_DEFS[".rb"] = [
    ("Symbol", re.compile(r"^\s*def\s+([A-Za-z_]\w*[!?=]?)")),
    ("Symbol", re.compile(r"^\s*class\s+([A-Za-z_]\w*)")),
    ("Symbol", re.compile(r"^\s*module\s+([A-Za-z_]\w*)")),
]
_GENERIC_DEFS[".php"] = [
    ("Symbol", re.compile(r"^\s*(?:public|private|protected)?\s*function\s+([A-Za-z_]\w*)")),
    ("Symbol", re.compile(r"^\s*class\s+([A-Za-z_]\w*)")),
]
_GENERIC_DEFS[".swift"] = [
    ("Symbol", re.compile(r"^\s*(?:public|private|internal)?\s*func\s+([A-Za-z_]\w*)")),
    ("Symbol", re.compile(r"^\s*(?:public|private|internal)?\s*struct\s+([A-Za-z_]\w*)")),
    ("Symbol", re.compile(r"^\s*(?:public|private|internal)?\s*class\s+([A-Za-z_]\w*)")),
    ("Symbol", re.compile(r"^\s*(?:public|private|internal)?\s*enum\s+([A-Za-z_]\w*)")),
]

_IMPORT_RES: dict[str, list[re.Pattern[str]]] = {
    ".rs": [re.compile(r"^\s*(?:pub\s+)?use\s+([A-Za-z0-9_:{} ,]+);")],
    ".py": [
        re.compile(r"^\s*import\s+([\w.]+)"),
        re.compile(r"^\s*from\s+(\.[\w.]*|[\w.]+)\s+import\b"),
    ],
    ".js": [
        re.compile(r"""require\(\s*['"]([^'"]+)['"]\s*\)"""),
        re.compile(r"""from\s+['"]([^'"]+)['"]"""),
    ],
    ".c": [re.compile(r'^\s*#include\s*[<"]([^>"]+)[>"]')],
    ".go": [re.compile(r'^\s*(?:import\s+)?"([^"]+)"')],
}

_IMPORT_RES[".cc"] = _IMPORT_RES[".c"]
_IMPORT_RES[".cpp"] = _IMPORT_RES[".c"]
_IMPORT_RES[".h"] = _IMPORT_RES[".c"]
_IMPORT_RES[".hpp"] = _IMPORT_RES[".c"]
_IMPORT_RES[".ts"] = _IMPORT_RES[".js"]
_IMPORT_RES[".tsx"] = _IMPORT_RES[".js"]
_IMPORT_RES[".jsx"] = _IMPORT_RES[".js"]
_IMPORT_RES[".mjs"] = _IMPORT_RES[".js"]
_IMPORT_RES[".rb"] = [re.compile(r"^\s*require(?:_relative)?\s+['\"]([^'\"]+)['\"]")]
_IMPORT_RES[".php"] = [re.compile(r"^\s*(?:require|include)(?:_once)?\s*\(?\s*['\"]([^'\"]+)['\"]")]
_IMPORT_RES[".swift"] = [re.compile(r"^\s*import\s+([\w.]+)")]

_GENERIC_SUFFIXES = set(_GENERIC_DEFS) | set(_IMPORT_RES)

# stems that look like tests (file-level Test entities)
_TEST_FILE_RE = re.compile(
    r"(^|/)(test_[^/]+|.*_test)\.(py|rs|js|ts|go|rb|java|cs|kt|swift)$"
    r"|(^|/)tests?/.*\.(py|rs|js|ts|go|rb|java|cs|kt|swift)$"
)


def _stem_module(rel: str) -> str:
    """A deterministic module spelling for a file: path minus extension."""
    p = rel.rsplit(".", 1)[0]
    return p.replace("/", ".")


def _test_target_hint(rel: str) -> str | None:
    """The sibling file a test path likely exercises, if derivable."""
    p = Path(rel)
    stem = p.stem
    suffix = p.suffix
    name = p.name
    if name.startswith("test_") and len(name) > 5:
        candidate = name[5:]
    elif stem.endswith("_test") and len(stem) > 5:
        candidate = stem[:-5] + suffix
    else:
        return None
    return (p.parent / candidate).as_posix() if str(p.parent) != "." else candidate


def _resolve_relative(rel_file: str, target: str, ctx: ExtractContext) -> str | None:
    base = Path(rel_file).parent
    joined = (base / target).as_posix()
    candidates = [
        joined,
        joined + ".js",
        joined + ".ts",
        joined + ".jsx",
        joined + ".tsx",
        joined + "/index.js",
        joined + "/index.ts",
        joined + ".py",
        joined + "/__init__.py",
        joined + ".rs",
        joined + "/mod.rs",
    ]
    return ctx.find_file(candidates)


class GenericCodeAdapter(Adapter):
    name = "generic-code"

    def detect(self, path: Path) -> bool:
        return path.suffix in _GENERIC_SUFFIXES

    def extract(self, path: Path, text: str, ctx: ExtractContext) -> Extraction:
        out = Extraction()
        rel = ctx.rel(path)
        module = _stem_module(rel)
        lang = language_for_suffix(path.suffix)
        derived = (f"generic-adapter:{path.suffix}",)
        file_id = stable_id_file(rel)
        seen: set[str] = set()
        for line_no, line in enumerate(text.splitlines(), start=1):
            for kind, rx in _GENERIC_DEFS.get(path.suffix, []):
                m = rx.match(line)
                if m:
                    name = m.group(1)
                    if name in {"if", "for", "while", "switch", "return", "else"}:
                        continue
                    qn = f"{module}::{name}"
                    if qn in seen:
                        continue
                    seen.add(qn)
                    sym_id = stable_id_symbol(lang, rel, name)
                    out.add_entity(
                        Entity(
                            kind=kind,
                            name=name,
                            qualified_name=qn,
                            file=rel,
                            line=line_no,
                            tier=1,
                            provenance="observed",
                            derived_from=derived,
                            stable_id=sym_id,
                            epistemic_state="observed",
                            analysis_depth=1,
                            completeness="partial",
                            provider=EXTRACTOR_PROVIDER_ID,
                            provider_revision=EXTRACTOR_PROVIDER_VERSION,
                        )
                    )
                    out.add_relation(
                        Relation(
                            src_key=file_id,
                            dst_key=sym_id,
                            kind="contains",
                            src_kind="File",
                            dst_kind=kind,
                            tier=1,
                            provenance="observed",
                            derived_from=derived,
                            epistemic_state="observed",
                            analysis_depth=1,
                        )
                    )
            for rx in _IMPORT_RES.get(path.suffix, []):
                m = rx.search(line)
                if not m:
                    continue
                target = m.group(1).strip()
                if not target:
                    continue
                resolved = None
                if target.startswith("."):
                    resolved = _resolve_relative(rel, target, ctx)
                elif path.suffix == ".rs" and target.startswith("crate::"):
                    inner = target.split("::")
                    if len(inner) >= 2:
                        candidate = "src/" + "/".join(inner[1:])
                        resolved = ctx.find_file(
                            [candidate + ".rs", candidate + "/mod.rs", candidate.split("/")[0] + ".rs"]
                        )
                if resolved:
                    dst_key = stable_id_file(resolved)
                    dst_kind = "File"
                    confidence = 0.9
                else:
                    dst_key = target
                    dst_kind = None
                    confidence = 0.5
                out.add_relation(
                    Relation(
                        src_key=file_id,
                        dst_key=dst_key,
                        kind="imports",
                        src_kind="File",
                        dst_kind=dst_kind,
                        tier=1,
                        provenance="inferred",
                        confidence=confidence,
                        derived_from=derived,
                        attrs={"raw": target},
                        epistemic_state="inferred",
                        analysis_depth=1,
                    )
                )
        if _TEST_FILE_RE.search(rel):
            test_id = stable_id_test(rel, path.name)
            out.add_entity(
                Entity(
                    kind="Test",
                    name=path.name,
                    qualified_name=rel,
                    file=rel,
                    tier=1,
                    provenance="observed",
                    derived_from=("generic-adapter:test-path",),
                    stable_id=test_id,
                    epistemic_state="observed",
                    analysis_depth=1,
                    completeness="partial",
                    provider=EXTRACTOR_PROVIDER_ID,
                    provider_revision=EXTRACTOR_PROVIDER_VERSION,
                )
            )
            # Typed tests relation: never tests(rel, rel).  The exercised
            # target is derived from the test filename; when it cannot be
            # resolved it stays a raw (unresolved) target with candidates.
            hint = _test_target_hint(rel)
            raw_hint = hint if hint is not None else _stem_module(rel)
            if hint is not None and hint in ctx.files:
                dst_key = stable_id_file(hint)
                dst_kind = "File"
                confidence = 0.8
                candidates: tuple[str, ...] = ()
            else:
                dst_key = raw_hint
                dst_kind = None
                confidence = 0.3
                candidates = (stable_id_file(hint),) if hint is not None else ()
            out.add_relation(
                Relation(
                    src_key=test_id,
                    dst_key=dst_key,
                    kind="tests",
                    src_kind="Test",
                    dst_kind=dst_kind,
                    tier=1,
                    provenance="observed" if dst_kind else "inferred",
                    confidence=confidence,
                    derived_from=("generic-adapter:test-path",),
                    attrs={"candidates": list(candidates)} if candidates else None,
                    epistemic_state="observed" if dst_kind else "uncertain",
                    analysis_depth=1,
                    completeness="partial" if dst_kind else "unknown",
                )
            )
        return out


# ── Tangerine fallback adapter ───────────────────────────────────────────

_TG_MODULE_RE = re.compile(r"^\s*(?:pub\s+)?module\s+([A-Za-z_]\w*)")
_TG_USE_RE = re.compile(r"^\s*(?:pub\s+)?use\s+([A-Za-z0-9_:]+)(?:::\{([^}]*)\})?\s*$")
_TG_DEFS = [
    ("Symbol", re.compile(r"^\s*(?:pub\s+)?def\s+([A-Za-z_]\w*)")),
    ("Symbol", re.compile(r"^\s*(?:pub\s+)?struct\s+([A-Za-z_]\w*)")),
    ("Symbol", re.compile(r"^\s*(?:pub\s+)?enum\s+([A-Za-z_]\w*)")),
    ("Symbol", re.compile(r"^\s*(?:pub\s+)?trait\s+([A-Za-z_]\w*)")),
    ("Symbol", re.compile(r"^\s*(?:pub\s+)?impl(?:\[[^\]]*\])?\s+([A-Za-z_]\w*)")),
    ("Symbol", re.compile(r"^\s*(?:pub\s+)?static\s+([A-Za-z_]\w*)")),
    ("Symbol", re.compile(r"^\s*(?:pub\s+)?const\s+([A-Za-z_]\w*)")),
]


class TangerineAdapter(Adapter):
    """Regex fallback for `.tg` sources; NOT authoritative (native provider is)."""

    name = "tangerine"

    def detect(self, path: Path) -> bool:
        return path.suffix == ".tg"

    def extract(self, path: Path, text: str, ctx: ExtractContext) -> Extraction:
        out = Extraction()
        rel = ctx.rel(path)
        derived = ("tangerine-adapter",)
        file_id = stable_id_file(rel)
        module_segments: list[str] = []
        lines = text.splitlines()
        for line in lines:
            m = _TG_MODULE_RE.match(line)
            if m:
                module_segments.append(m.group(1))
        base = "::".join(module_segments) if module_segments else _stem_module(rel)
        pending_test = False
        for line_no, line in enumerate(lines, start=1):
            stripped = line.strip()
            if stripped.startswith("@"):
                pending_test = stripped == "@test"
                if stripped != "@test":
                    continue
            m = _TG_USE_RE.match(line)
            if m:
                target = m.group(1)
                names = m.group(2)
                out.add_relation(
                    Relation(
                        src_key=file_id,
                        dst_key=target,
                        kind="imports",
                        src_kind="File",
                        dst_kind=None,
                        tier=2,
                        provenance="declared",
                        confidence=0.8,
                        derived_from=derived,
                        attrs={"names": names.strip() if names else None},
                        epistemic_state="declared",
                        analysis_depth=2,
                        completeness="partial",
                    )
                )
                continue
            for kind, rx in _TG_DEFS:
                m = rx.match(line)
                if m:
                    name = m.group(1)
                    qn = f"{base}::{name}"
                    sym_id = stable_id_symbol("tg", rel, name)
                    out.add_entity(
                        Entity(
                            kind=kind,
                            name=name,
                            qualified_name=qn,
                            file=rel,
                            line=line_no,
                            tier=2,
                            provenance="declared",
                            derived_from=derived,
                            stable_id=sym_id,
                            epistemic_state="declared",
                            analysis_depth=2,
                            completeness="partial",
                            provider=EXTRACTOR_PROVIDER_ID,
                            provider_revision=EXTRACTOR_PROVIDER_VERSION,
                            attrs={"adapter": "tangerine-fallback"},
                        )
                    )
                    out.add_relation(
                        Relation(
                            src_key=file_id,
                            dst_key=sym_id,
                            kind="contains",
                            src_kind="File",
                            dst_kind=kind,
                            tier=2,
                            provenance="declared",
                            derived_from=derived,
                            epistemic_state="declared",
                            analysis_depth=2,
                        )
                    )
                    if pending_test and rx is _TG_DEFS[0][1]:
                        test_id = stable_id_test(rel, name)
                        out.add_entity(
                            Entity(
                                kind="Test",
                                name=name,
                                qualified_name=f"{rel}::{name}",
                                file=rel,
                                line=line_no,
                                tier=2,
                                provenance="declared",
                                derived_from=("tangerine-adapter:@test",),
                                stable_id=test_id,
                                epistemic_state="declared",
                                analysis_depth=2,
                                completeness="partial",
                                provider=EXTRACTOR_PROVIDER_ID,
                                provider_revision=EXTRACTOR_PROVIDER_VERSION,
                                attrs={"adapter": "tangerine-fallback"},
                            )
                        )
                        parent_dir = Path(rel).parent.as_posix()
                        if parent_dir not in (".", ""):
                            dst_key = stable_id_module(parent_dir)
                            dst_kind = "Module"
                        else:
                            dst_key = file_id
                            dst_kind = "File"
                        out.add_relation(
                            Relation(
                                src_key=test_id,
                                dst_key=dst_key,
                                kind="tests",
                                src_kind="Test",
                                dst_kind=dst_kind,
                                tier=2,
                                provenance="declared",
                                confidence=0.6,
                                derived_from=("tangerine-adapter:@test",),
                                epistemic_state="declared",
                                analysis_depth=2,
                                completeness="partial",
                            )
                        )
                    pending_test = False
                    break
            else:
                if stripped and not stripped.startswith(("#", "@")):
                    pending_test = False
        return out


# ── manifest adapter ─────────────────────────────────────────────────────

_MANIFEST_KINDS = {
    "Cargo.toml": "cargo",
    "package.json": "npm",
    "pyproject.toml": "python",
    "setup.py": "python",
    "go.mod": "go",
    "pom.xml": "maven",
    "build.gradle": "gradle",
    "Gemfile": "ruby",
    "composer.json": "php",
    "CMakeLists.txt": "cmake",
    "Makefile": "make",
}


class ManifestAdapter(Adapter):
    name = "manifest"

    def detect(self, path: Path) -> bool:
        return path.name in _MANIFEST_KINDS

    def extract(self, path: Path, text: str, ctx: ExtractContext) -> Extraction:
        out = Extraction()
        rel = ctx.rel(path)
        kind = _MANIFEST_KINDS[path.name]
        derived = (f"manifest:{path.name}",)
        pkg_id = stable_id_package(rel)
        package_name = None
        version = None
        uncertain = None
        try:
            if path.name in ("Cargo.toml", "pyproject.toml"):
                try:
                    import tomllib

                    data = tomllib.loads(text)
                except Exception as exc:  # noqa: BLE001 - degrade gracefully
                    data = {}
                    uncertain = f"unparsed {path.name}: {exc.__class__.__name__}"
                if kind == "python":
                    project = data.get("project") or {}
                    package_name = project.get("name")
                    version = project.get("version")
                else:
                    package = data.get("package") or {}
                    package_name = package.get("name")
                    version = package.get("version")
            elif path.name in ("package.json", "composer.json"):
                import json as _json

                data = _json.loads(text)
                package_name = data.get("name")
                version = data.get("version")
            elif path.name == "go.mod":
                m = re.search(r"^\s*module\s+(\S+)", text, re.MULTILINE)
                package_name = m.group(1) if m else None
            elif path.name == "pom.xml":
                m = re.search(r"<artifactId>([^<]+)</artifactId>", text)
                package_name = m.group(1) if m else None
                m = re.search(r"<version>([^<]+)</version>", text)
                version = m.group(1) if m else None
        except Exception as exc:  # noqa: BLE001 - degrade gracefully
            uncertain = f"unparsed {path.name}: {exc.__class__.__name__}"

        name = package_name or path.parent.name or path.name
        out.add_entity(
            Entity(
                kind="Package",
                name=name,
                qualified_name=rel,
                file=rel,
                tier=1,
                provenance="declared",
                confidence=1.0 if package_name else 0.3,
                derived_from=derived,
                attrs={"manifest": kind, "version": version},
                stable_id=pkg_id,
                epistemic_state="declared",
                analysis_depth=1,
                completeness="partial",
                provider=EXTRACTOR_PROVIDER_ID,
                provider_revision=EXTRACTOR_PROVIDER_VERSION,
            )
        )
        if uncertain:
            out.add_fact(
                Fact(
                    subject=rel,
                    predicate="is parseable",
                    object="false",
                    tier=1,
                    provenance="declared",
                    confidence=0.3,
                    derived_from=derived,
                    uncertainty=uncertain,
                    stable_subject=pkg_id,
                    epistemic_state="declared",
                    analysis_depth=1,
                )
            )
        if package_name:
            out.add_fact(
                Fact(
                    subject=rel,
                    predicate="declares package",
                    object=str(package_name),
                    tier=1,
                    provenance="declared",
                    derived_from=derived,
                    stable_subject=pkg_id,
                    epistemic_state="declared",
                    analysis_depth=1,
                )
            )
        parent = path.parent.relative_to(ctx.root).as_posix()
        if parent in ("", "."):
            out.add_relation(
                Relation(
                    src_key=REPO_STABLE_ID,
                    dst_key=pkg_id,
                    kind="contains",
                    src_kind="Repository",
                    dst_kind="Package",
                    tier=1,
                    provenance="declared",
                    derived_from=derived,
                    epistemic_state="declared",
                    analysis_depth=1,
                )
            )
        else:
            project_id = f"project:{parent}"
            out.add_entity(
                Entity(
                    kind="Project",
                    name=Path(parent).name,
                    qualified_name=parent,
                    tier=1,
                    provenance="declared",
                    derived_from=derived,
                    stable_id=project_id,
                    epistemic_state="declared",
                    analysis_depth=1,
                    completeness="partial",
                    provider=EXTRACTOR_PROVIDER_ID,
                    provider_revision=EXTRACTOR_PROVIDER_VERSION,
                )
            )
            out.add_relation(
                Relation(
                    src_key=REPO_STABLE_ID,
                    dst_key=project_id,
                    kind="contains",
                    src_kind="Repository",
                    dst_kind="Project",
                    tier=1,
                    provenance="declared",
                    derived_from=derived,
                    epistemic_state="declared",
                    analysis_depth=1,
                )
            )
            out.add_relation(
                Relation(
                    src_key=project_id,
                    dst_key=pkg_id,
                    kind="contains",
                    src_kind="Project",
                    dst_kind="Package",
                    tier=1,
                    provenance="declared",
                    derived_from=derived,
                    epistemic_state="declared",
                    analysis_depth=1,
                )
            )
        return out


# ── SQL adapter ──────────────────────────────────────────────────────────

_SQL_TABLE_RE = re.compile(
    r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?[\"`\[]?([A-Za-z_]\w*)[\"`\]]?\s*\((.*?)\)\s*;",
    re.IGNORECASE | re.DOTALL,
)
_SQL_COLUMN_RE = re.compile(r"^\s*[\"`\[]?([A-Za-z_]\w*)[\"`\]]?\s+([A-Za-z_][\w()\s,]*)")
_SQL_FK_RE = re.compile(r"REFERENCES\s+[\"`\[]?([A-Za-z_]\w*)[\"`\]]?", re.IGNORECASE)


class SqlAdapter(Adapter):
    name = "sql"

    def detect(self, path: Path) -> bool:
        return path.suffix == ".sql"

    def extract(self, path: Path, text: str, ctx: ExtractContext) -> Extraction:
        out = Extraction()
        rel = ctx.rel(path)
        derived = ("sql-adapter",)
        for m in _SQL_TABLE_RE.finditer(text):
            table, body = m.group(1), m.group(2)
            qn = f"{rel}::{table}"
            schema_id = stable_id_schema(rel, table)
            out.add_entity(
                Entity(
                    kind="Schema",
                    name=table,
                    qualified_name=qn,
                    file=rel,
                    tier=1,
                    provenance="observed",
                    derived_from=derived,
                    stable_id=schema_id,
                    epistemic_state="observed",
                    analysis_depth=1,
                    completeness="partial",
                    provider=EXTRACTOR_PROVIDER_ID,
                    provider_revision=EXTRACTOR_PROVIDER_VERSION,
                )
            )
            for line in body.splitlines():
                line = line.strip().rstrip(",")
                if not line:
                    continue
                col = _SQL_COLUMN_RE.match(line)
                if col and col.group(1).upper() not in ("PRIMARY", "FOREIGN", "UNIQUE", "CONSTRAINT", "CHECK"):
                    cname, ctype = col.group(1), col.group(2).strip()
                    out.add_fact(
                        Fact(
                            subject=qn,
                            predicate=f"column:{cname}",
                            object=ctype,
                            tier=1,
                            provenance="observed",
                            derived_from=derived,
                            stable_subject=schema_id,
                            epistemic_state="observed",
                            analysis_depth=1,
                        )
                    )
                fk = _SQL_FK_RE.search(line)
                if fk:
                    out.add_relation(
                        Relation(
                            src_key=schema_id,
                            dst_key=stable_id_schema(rel, fk.group(1)),
                            kind="depends_on",
                            src_kind="Schema",
                            dst_kind="Schema",
                            tier=1,
                            provenance="observed",
                            confidence=0.9,
                            derived_from=derived,
                            epistemic_state="observed",
                            analysis_depth=1,
                        )
                    )
        return out


# ── configuration adapter ────────────────────────────────────────────────


class ConfigAdapter(Adapter):
    name = "config"

    def detect(self, path: Path) -> bool:
        if path.name == ".env" or path.name.startswith(".env."):
            return True
        return path.suffix in (".toml", ".yaml", ".yml") and path.name not in _MANIFEST_KINDS

    def extract(self, path: Path, text: str, ctx: ExtractContext) -> Extraction:
        out = Extraction()
        rel = ctx.rel(path)
        derived = ("config-adapter",)
        file_id = stable_id_file(rel)
        seen: set[str] = set()
        for line in text.splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith(("#", "//", "[")):
                continue
            m = re.match(r"^([A-Za-z_][\w.-]*)\s*[:=]", stripped)
            if not m:
                continue
            key = m.group(1)
            if key in seen:
                continue
            seen.add(key)
            qn = f"{rel}::{key}"
            cfg_id = stable_id_config(rel, key)
            out.add_entity(
                Entity(
                    kind="Configuration",
                    name=key,
                    qualified_name=qn,
                    file=rel,
                    tier=1,
                    provenance="observed",
                    derived_from=derived,
                    attrs={"value_recorded": False},
                    stable_id=cfg_id,
                    epistemic_state="observed",
                    analysis_depth=1,
                    completeness="partial",
                    provider=EXTRACTOR_PROVIDER_ID,
                    provider_revision=EXTRACTOR_PROVIDER_VERSION,
                )
            )
            out.add_fact(
                Fact(
                    subject=rel,
                    predicate="defines config key",
                    object=key,
                    tier=1,
                    provenance="observed",
                    derived_from=derived,
                    stable_subject=file_id,
                    epistemic_state="observed",
                    analysis_depth=1,
                )
            )
        return out


# ── deployment adapter ───────────────────────────────────────────────────


class DeploymentAdapter(Adapter):
    name = "deployment"

    def detect(self, path: Path) -> bool:
        return path.name in ("Dockerfile", "docker-compose.yml", "docker-compose.yaml")

    def extract(self, path: Path, text: str, ctx: ExtractContext) -> Extraction:
        out = Extraction()
        rel = ctx.rel(path)
        derived = ("deployment-adapter",)
        deployment_id = f"deployment:{rel}"
        out.add_entity(
            Entity(
                kind="Deployment",
                name=path.name,
                qualified_name=rel,
                file=rel,
                tier=1,
                provenance="declared",
                derived_from=derived,
                stable_id=deployment_id,
                epistemic_state="declared",
                analysis_depth=1,
                completeness="partial",
                provider=EXTRACTOR_PROVIDER_ID,
                provider_revision=EXTRACTOR_PROVIDER_VERSION,
            )
        )
        if path.name.startswith("docker-compose"):
            in_services = False
            for line in text.splitlines():
                if re.match(r"^services\s*:", line):
                    in_services = True
                    continue
                if in_services:
                    m = re.match(r"^  ([A-Za-z0-9_.-]+)\s*:", line)
                    if m:
                        svc = m.group(1)
                        qn = f"{rel}::{svc}"
                        svc_id = f"service:{rel}::{svc}"
                        out.add_entity(
                            Entity(
                                kind="Service",
                                name=svc,
                                qualified_name=qn,
                                file=rel,
                                tier=1,
                                provenance="declared",
                                derived_from=derived,
                                stable_id=svc_id,
                                epistemic_state="declared",
                                analysis_depth=1,
                                completeness="partial",
                                provider=EXTRACTOR_PROVIDER_ID,
                                provider_revision=EXTRACTOR_PROVIDER_VERSION,
                            )
                        )
                        out.add_relation(
                            Relation(
                                src_key=deployment_id,
                                dst_key=svc_id,
                                kind="deploys_with",
                                src_kind="Deployment",
                                dst_kind="Service",
                                tier=1,
                                provenance="declared",
                                derived_from=derived,
                                epistemic_state="declared",
                                analysis_depth=1,
                            )
                        )
                    elif re.match(r"^[A-Za-z]", line):
                        in_services = False
        else:
            m = re.search(r"^FROM\s+(\S+)", text, re.MULTILINE)
            if m:
                out.add_fact(
                    Fact(
                        subject=rel,
                        predicate="base image",
                        object=m.group(1),
                        tier=1,
                        provenance="declared",
                        derived_from=derived,
                        stable_subject=deployment_id,
                        epistemic_state="declared",
                        analysis_depth=1,
                    )
                )
        return out


# ── registry + extraction ────────────────────────────────────────────────


def default_registry() -> AdapterRegistry:
    registry = AdapterRegistry()
    registry.register(ManifestAdapter())
    registry.register(SqlAdapter())
    registry.register(ConfigAdapter())
    registry.register(DeploymentAdapter())
    registry.register(TangerineAdapter())
    registry.register(GenericCodeAdapter())
    return registry


def iter_files(root):
    """Yield every scanned source path (deterministic directory order)."""
    root = Path(root)
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for fname in sorted(filenames):
            yield Path(dirpath) / fname


def extract(
    root: str | Path,
    registry: AdapterRegistry | None = None,
    commit_sha: str | None = None,
) -> Extraction:
    """Tier 0 / Tier 1 extraction of `root` into the universal vocabulary."""
    root = Path(root).resolve()
    registry = registry or default_registry()
    result = Extraction()
    ctx = ExtractContext(root=root, commit_sha=commit_sha)
    files = list(iter_files(root))
    ctx.files = {p.relative_to(root).as_posix() for p in files}

    repo_name = root.name or "."
    result.add_entity(
        Entity(
            kind="Repository",
            name=repo_name,
            qualified_name=".",
            file=None,
            tier=0,
            provenance="observed",
            derived_from=("filesystem",),
            attrs={"root": str(root), "commit_sha": commit_sha},
            stable_id=REPO_STABLE_ID,
            epistemic_state="observed",
            analysis_depth=0,
            completeness="partial",
            provider=EXTRACTOR_PROVIDER_ID,
            provider_revision=EXTRACTOR_PROVIDER_VERSION,
        )
    )

    # directory modules (every dir that directly contains files)
    dirs_with_files = sorted({str(p.parent.relative_to(root)) for p in files})
    dirs_with_files = [d for d in dirs_with_files if d not in (".", "")]
    for d in dirs_with_files:
        out = Extraction()
        module_id = stable_id_module(d)
        out.add_entity(
            Entity(
                kind="Module",
                name=Path(d).name,
                qualified_name=d,
                tier=0,
                provenance="observed",
                derived_from=("filesystem",),
                stable_id=module_id,
                epistemic_state="observed",
                analysis_depth=0,
                completeness="partial",
                provider=EXTRACTOR_PROVIDER_ID,
                provider_revision=EXTRACTOR_PROVIDER_VERSION,
            )
        )
        out.add_relation(
            Relation(
                src_key=REPO_STABLE_ID,
                dst_key=module_id,
                kind="contains",
                src_kind="Repository",
                dst_kind="Module",
                tier=0,
                provenance="observed",
                derived_from=("filesystem",),
                epistemic_state="observed",
                analysis_depth=0,
            )
        )
        result.merge(out)

    for path in files:
        rel = ctx.rel(path)
        file_id = stable_id_file(rel)
        try:
            size = path.stat().st_size
        except OSError:
            continue
        result.add_entity(
            Entity(
                kind="File",
                name=path.name,
                qualified_name=rel,
                file=rel,
                tier=0,
                provenance="observed",
                derived_from=("filesystem",),
                stable_id=file_id,
                epistemic_state="observed",
                analysis_depth=0,
                completeness="partial",
                provider=EXTRACTOR_PROVIDER_ID,
                provider_revision=EXTRACTOR_PROVIDER_VERSION,
            )
        )
        parent = path.parent.relative_to(root).as_posix()
        if parent not in (".", ""):
            result.add_relation(
                Relation(
                    src_key=stable_id_module(parent),
                    dst_key=file_id,
                    kind="contains",
                    src_kind="Module",
                    dst_kind="File",
                    tier=0,
                    provenance="observed",
                    derived_from=("filesystem",),
                    epistemic_state="observed",
                    analysis_depth=0,
                )
            )
        if size > MAX_FILE_BYTES:
            result.add_fact(
                Fact(
                    subject=rel,
                    predicate="extraction",
                    object="skipped",
                    tier=0,
                    provenance="observed",
                    stable_subject=file_id,
                    uncertainty=f"file exceeds the {MAX_FILE_BYTES}-byte extraction cap",
                    epistemic_state="observed",
                    analysis_depth=0,
                )
            )
            continue
        try:
            raw = path.read_bytes()
        except OSError as exc:
            result.add_fact(
                Fact(
                    subject=rel,
                    predicate="extraction",
                    object="unreadable",
                    tier=0,
                    provenance="observed",
                    stable_subject=file_id,
                    uncertainty=str(exc),
                    epistemic_state="observed",
                    analysis_depth=0,
                )
            )
            continue
        if b"\x00" in raw[:8192]:
            result.add_fact(
                Fact(
                    subject=rel,
                    predicate="extraction",
                    object="binary",
                    tier=0,
                    provenance="observed",
                    stable_subject=file_id,
                    uncertainty="binary content; no structural facts extracted",
                    epistemic_state="observed",
                    analysis_depth=0,
                )
            )
            continue
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            text = raw.decode("utf-8", errors="replace")
            result.add_fact(
                Fact(
                    subject=rel,
                    predicate="encoding",
                    object="non-utf8",
                    tier=0,
                    provenance="observed",
                    stable_subject=file_id,
                    uncertainty="decoded with replacement characters",
                    epistemic_state="observed",
                    analysis_depth=0,
                )
            )
        for adapter in registry.for_path(path):
            try:
                piece = adapter.extract(path, text, ctx)
            except Exception as exc:  # noqa: BLE001 - adapters degrade, never crash
                piece = Extraction()
                piece.add_fact(
                    Fact(
                        subject=rel,
                        predicate="extraction",
                        object="adapter-failed",
                        tier=0,
                        provenance="observed",
                        stable_subject=file_id,
                        uncertainty=f"{adapter.name}: {exc.__class__.__name__}",
                        epistemic_state="observed",
                        analysis_depth=0,
                    )
                )
            if piece:
                result.merge(piece)
    return result
