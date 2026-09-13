#!/usr/bin/env python3
# scripts/invariant_registry.py — the invariant-registry codec and content
# digest, shared by scripts/gen_invariants.sh (validate/generate) and
# scripts/release_evidence_schema.sh (release-evidence validation).
#
# The registry content digest is a sha-256 over the CANONICAL SEMANTIC
# CONTENT of invariants.toml's definitions — the registry version plus
# every entry's id/stage/severity/summary/status/assertion/scoping/
# positive/negative/mutation/coverage/former_status/classification — NOT
# over the file bytes and NOT over any commit id.
#
# Why not a commit id: a committed file cannot know the SHA of the commit
# that contains it (writing the digest into the file changes the file, so
# the recorded value could never equal its own commit). The digest solves
# the self-reference: it identifies the definition content wherever it is
# committed, while the TESTED COMMIT and the test evidence live in the
# external invariants-evidence.json artifact (tested_commit_sha +
# registry_digest + compiler_digest + checks + test_evidence + build
# identity), which the CI generates and uploads.
#
# Functions (the single definition of the canonical form):
#   parse_toml(text)        tomllib -> tomli -> the constrained fallback
#   definitions(doc)        the canonical, id-sorted definition records
#   registry_digest(doc)    "sha256:<64 hex>" over the canonical payload
#   legacy_usage(doc)       the rejected old-scheme keys (last_verified_sha
#                           / per-entry verified_sha)
#   sha256_file(path)       the per-file sha-256 (evidence hashing)
#
# The module is import-only; running it as a script prints the digest of
# invariants.toml (a debugging convenience).
import hashlib
import json
import re

DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
LEGACY_KEYS = ("last_verified_sha", "verified_sha")

# The definition fields that make up the canonical content. Every field is
# normalized to a string (or a list of strings); absent fields normalize
# to "" / [] so a formatting-only edit cannot change the digest.
DEFINITION_FIELDS = (
    "id", "stage", "severity", "summary", "status", "assertion",
    "scoping", "positive", "negative", "mutation", "coverage",
    "former_status", "classification",
)
LIST_FIELDS = ("positive", "negative", "mutation")


def _s(value):
    return "" if value is None else str(value)


def _l(value):
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    return [_s(v) for v in value]


def _split_array(inner):
    """Split a TOML-ish array body on top-level commas (quote-aware)."""
    items = []
    buf = []
    quote = None
    i = 0
    while i < len(inner):
        ch = inner[i]
        if quote:
            buf.append(ch)
            if ch == "\\" and i + 1 < len(inner):
                buf.append(inner[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = None
        elif ch in ("'", '"'):
            quote = ch
            buf.append(ch)
        elif ch == ",":
            items.append("".join(buf).strip())
            buf = []
        else:
            buf.append(ch)
        i += 1
    tail = "".join(buf).strip()
    if tail:
        items.append(tail)
    return items


def _scalar(raw):
    value = raw.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        body = value[1:-1]
        if value[0] == '"':
            body = body.replace('\\"', '"').replace("\\\\", "\\")
        return body
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        if not inner:
            return []
        return [_scalar(part) for part in _split_array(inner)]
    return value


def _parse_fallback(text):
    """Parse the constrained invariants.toml subset without tomllib/tomli:
    top-level scalars, [table] sections, [[array-of-tables]] sections,
    quoted/bare scalars and single-line arrays. Repeated [[invariant]]
    sections are preserved as a list of dicts (the shape tomllib gives).
    """
    data = {}
    current = None          # the dict being filled, or None for top level
    current_array = None    # the [[name]] list target
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^\[\[([A-Za-z0-9_.-]+)\]\]$", line)
        if m:
            current_array = m.group(1)
            current = {}
            data.setdefault(current_array, []).append(current)
            continue
        m = re.match(r"^\[([A-Za-z0-9_.-]+)\]$", line)
        if m:
            current_array = None
            current = {}
            data[m.group(1)] = current
            continue
        m = re.match(r'^([A-Za-z0-9_.-]+)\s*=\s*(.*)$', line)
        if not m:
            raise ValueError("toml parse error at line %d: %s" % (lineno, raw))
        key, value = m.group(1), m.group(2).strip()
        if current is None:
            data[key] = _scalar(value)
        else:
            current[key] = _scalar(value)
    return data


def parse_toml(text):
    """tomllib (3.11+) -> tomli -> the constrained fallback. A real parse
    error from an available parser propagates (never masked by a fallback).
    """
    try:
        import tomllib
        return tomllib.loads(text)
    except ImportError:
        pass
    try:
        import tomli
        return tomli.loads(text)
    except ImportError:
        pass
    return _parse_fallback(text)


def definitions(doc):
    """The canonical, id-sorted definition records. Keys outside
    DEFINITION_FIELDS (the registry_digest metadata itself) are excluded, so
    the digest cannot depend on itself.
    """
    invariants = doc.get("invariant", []) or []
    records = []
    for entry in sorted(invariants, key=lambda e: _s(e.get("id", ""))):
        record = {}
        for field in DEFINITION_FIELDS:
            if field in LIST_FIELDS:
                record[field] = _l(entry.get(field))
            else:
                record[field] = _s(entry.get(field, ""))
        records.append(record)
    return records


def registry_digest(doc):
    """The registry content digest: sha256 over the canonical JSON of
    {version, invariants:[canonical records]}. The recorded
    registry_digest field is metadata and is never part of the payload.
    """
    payload = {"version": _s(doc.get("version", "")),
               "invariants": definitions(doc)}
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"),
                           ensure_ascii=True)
    return "sha256:" + hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def legacy_usage(doc):
    """The rejected old-scheme keys (top-level or per-entry, wherever they
    were placed): the committed-SHA scheme is not carried over silently.
    """
    found = [key for key in LEGACY_KEYS if key in doc]
    for index, entry in enumerate(doc.get("invariant", []) or []):
        eid = _s(entry.get("id", "")) or "#%d" % index
        for key in LEGACY_KEYS:
            if key in entry:
                found.append("%s.%s" % (eid, key))
    return found


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


if __name__ == "__main__":
    import sys
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        print(registry_digest(parse_toml(handle.read())))
