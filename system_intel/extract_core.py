"""Language-agnostic Tier 0 / Tier 1 extraction for system_intel.

The core is deliberately language-neutral: every adapter emits the same
universal entity/relation/fact vocabulary (see schema.sql).  Adapters are
pluggable; the default registry understands common manifest files, SQL,
configuration, deployment files, a generic code adapter for many
languages, and an exact adapter for Tangerine (`.tg`) sources.

Nothing here mutates the scanned repository, and nothing crashes on
malformed input: unreadable/binary/large files degrade to a Tier 0 File
entity with a recorded uncertainty.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path

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

    def key(self) -> tuple[str, str]:
        return (self.kind, self.qualified_name)


@dataclass
class Relation:
    src_qn: str
    dst_qn: str
    kind: str
    tier: int = 1
    provenance: str = "inferred"
    confidence: float = 1.0
    derived_from: tuple[str, ...] = ()
    attrs: dict | None = None


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
        derived = (f"generic-adapter:{path.suffix}",)
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
                        )
                    )
                    out.add_relation(
                        Relation(
                            src_qn=rel,
                            dst_qn=qn,
                            kind="contains",
                            tier=1,
                            provenance="observed",
                            derived_from=derived,
                        )
                    )
            for rx in _IMPORT_RES.get(path.suffix, []):
                m = rx.search(line)
                if not m:
                    continue
                target = m.group(1).strip()
                if not target:
                    continue
                if target.startswith("."):
                    resolved = _resolve_relative(rel, target, ctx)
                    dst = resolved or target
                elif path.suffix == ".rs" and target.startswith("crate::"):
                    inner = target.split("::")
                    if len(inner) >= 2:
                        candidate = "src/" + "/".join(inner[1:])
                        dst = ctx.find_file(
                            [candidate + ".rs", candidate + "/mod.rs", candidate.split("/")[0] + ".rs"]
                        ) or target
                    else:
                        dst = target
                elif path.suffix in (".py",) and target.startswith("."):
                    dst = _resolve_relative(rel, target, ctx) or target
                else:
                    dst = target
                out.add_relation(
                    Relation(
                        src_qn=rel,
                        dst_qn=dst,
                        kind="imports",
                        tier=1,
                        provenance="inferred",
                        confidence=0.9 if dst != target else 0.5,
                        derived_from=derived,
                        attrs={"raw": target},
                    )
                )
        if _TEST_FILE_RE.search(rel):
            out.add_entity(
                Entity(
                    kind="Test",
                    name=path.name,
                    qualified_name=rel,
                    file=rel,
                    tier=1,
                    provenance="observed",
                    derived_from=("generic-adapter:test-path",),
                )
            )
            out.add_relation(
                Relation(
                    src_qn=rel,
                    dst_qn=rel,
                    kind="tests",
                    tier=1,
                    provenance="observed",
                    derived_from=("generic-adapter:test-path",),
                )
            )
        return out


# ── Tangerine adapter ────────────────────────────────────────────────────

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
    name = "tangerine"

    def detect(self, path: Path) -> bool:
        return path.suffix == ".tg"

    def extract(self, path: Path, text: str, ctx: ExtractContext) -> Extraction:
        out = Extraction()
        rel = ctx.rel(path)
        derived = ("tangerine-adapter",)
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
                        src_qn=rel,
                        dst_qn=target,
                        kind="imports",
                        tier=2,
                        provenance="declared",
                        confidence=0.8,
                        derived_from=derived,
                        attrs={"names": names.strip() if names else None},
                    )
                )
                continue
            for kind, rx in _TG_DEFS:
                m = rx.match(line)
                if m:
                    name = m.group(1)
                    qn = f"{base}::{name}"
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
                        )
                    )
                    out.add_relation(
                        Relation(
                            src_qn=rel,
                            dst_qn=qn,
                            kind="contains",
                            tier=2,
                            provenance="declared",
                            derived_from=derived,
                        )
                    )
                    if pending_test and rx is _TG_DEFS[0][1]:
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
                )
            )
        parent = path.parent.relative_to(ctx.root).as_posix()
        if parent in ("", "."):
            out.add_relation(
                Relation(
                    src_qn=".",
                    dst_qn=rel,
                    kind="contains",
                    tier=1,
                    provenance="declared",
                    derived_from=derived,
                )
            )
        else:
            out.add_entity(
                Entity(
                    kind="Project",
                    name=Path(parent).name,
                    qualified_name=parent,
                    tier=1,
                    provenance="declared",
                    derived_from=derived,
                )
            )
            out.add_relation(
                Relation(
                    src_qn=".",
                    dst_qn=parent,
                    kind="contains",
                    tier=1,
                    provenance="declared",
                    derived_from=derived,
                )
            )
            out.add_relation(
                Relation(
                    src_qn=parent,
                    dst_qn=rel,
                    kind="contains",
                    tier=1,
                    provenance="declared",
                    derived_from=derived,
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
            out.add_entity(
                Entity(
                    kind="Schema",
                    name=table,
                    qualified_name=qn,
                    file=rel,
                    tier=1,
                    provenance="observed",
                    derived_from=derived,
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
                        )
                    )
                fk = _SQL_FK_RE.search(line)
                if fk:
                    out.add_relation(
                        Relation(
                            src_qn=qn,
                            dst_qn=fk.group(1),
                            kind="depends_on",
                            tier=1,
                            provenance="observed",
                            confidence=0.9,
                            derived_from=derived,
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
        out.add_entity(
            Entity(
                kind="Deployment",
                name=path.name,
                qualified_name=rel,
                file=rel,
                tier=1,
                provenance="declared",
                derived_from=derived,
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
                        out.add_entity(
                            Entity(
                                kind="Service",
                                name=svc,
                                qualified_name=qn,
                                file=rel,
                                tier=1,
                                provenance="declared",
                                derived_from=derived,
                            )
                        )
                        out.add_relation(
                            Relation(
                                src_qn=rel,
                                dst_qn=qn,
                                kind="deploys_with",
                                tier=1,
                                provenance="declared",
                                derived_from=derived,
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


def _iter_files(root: Path):
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
    files = list(_iter_files(root))
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
        )
    )

    # directory modules (every dir that directly contains files)
    dirs_with_files = sorted({str(p.parent.relative_to(root)) for p in files})
    dirs_with_files = [d for d in dirs_with_files if d not in (".", "")]
    for d in dirs_with_files:
        result.add_entity(
            Entity(
                kind="Module",
                name=Path(d).name,
                qualified_name=d,
                tier=0,
                provenance="observed",
                derived_from=("filesystem",),
            )
        )
        result.add_relation(
            Relation(
                src_qn=".",
                dst_qn=d,
                kind="contains",
                tier=0,
                provenance="observed",
                derived_from=("filesystem",),
            )
        )

    for path in files:
        rel = ctx.rel(path)
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
            )
        )
        parent = path.parent.relative_to(root).as_posix()
        if parent not in (".", ""):
            result.add_relation(
                Relation(
                    src_qn=parent,
                    dst_qn=rel,
                    kind="contains",
                    tier=0,
                    provenance="observed",
                    derived_from=("filesystem",),
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
                    uncertainty=f"file exceeds the {MAX_FILE_BYTES}-byte extraction cap",
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
                    uncertainty=str(exc),
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
                    uncertainty="binary content; no structural facts extracted",
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
                    uncertainty="decoded with replacement characters",
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
                        uncertainty=f"{adapter.name}: {exc.__class__.__name__}",
                    )
                )
            if piece:
                result.merge(piece)
    return result
