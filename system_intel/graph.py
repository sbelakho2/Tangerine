"""Core knowledge graph for the Tangerine System Intelligence platform.

Stdlib-only (sqlite3 / json / pathlib / datetime).  The SQLite schema is
loaded verbatim from ``schema.sql`` next to this module; that file is the
authoritative source for table and column names.

The graph stores what is *known* about a repository: entities, relations,
facts, invariants, contracts and historical records (incidents, changes).
Every row carries provenance, confidence and (where the schema has the
column) a tier, so derived knowledge is never confused with observed or
declared knowledge.  Snapshots bind rows to (repo_root, commit_sha).

Staleness semantics
-------------------
An entity that is not re-upserted in a later extraction becomes stale via
``stale_sweep``.  A caller may only sweep a kind when the extraction for
that run enumerated that kind *fully*: passing a partial ``seen_by_kind``
set silently marks real entities stale, so extraction code must omit a
kind from ``seen_by_kind`` unless it enumerated every entity of it.
"""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

SCHEMA_VERSION = 1

ENTITY_KINDS = (
    "Repository", "Project", "Package", "Module", "File", "Symbol", "Service",
    "Resource", "API", "Contract", "Schema", "Event", "Queue", "Configuration",
    "Deployment", "Test", "Owner", "Invariant", "Incident", "Change",
    "RuntimePath", "DataFlow",
)

RELATION_KINDS = (
    "contains", "imports", "calls", "reads", "writes", "creates", "deletes",
    "publishes", "subscribes", "depends_on", "implements", "extends", "tests",
    "deploys_with", "owns", "configured_by", "constrained_by",
    "compatible_with", "breaks_if_changed", "flows_to",
)

# Edge kinds traversed by impact()/dependencies()/change_surface().
IMPACT_EDGE_KINDS = (
    "depends_on", "imports", "calls", "contains", "reads", "writes",
    "publishes", "subscribes", "flows_to",
)

_ENTITY_COLUMNS = (
    "id", "snapshot_id", "kind", "name", "qualified_name", "file", "line",
    "tier", "provenance", "confidence", "derived_from", "last_verified",
    "uncertainty", "stale", "attrs",
)
_RELATION_COLUMNS = (
    "id", "snapshot_id", "src_id", "dst_id", "kind", "tier", "provenance",
    "confidence", "derived_from", "last_verified", "uncertainty", "stale",
    "attrs",
)

_IN_CHUNK = 500


def _dumps(value):
    return json.dumps(value, sort_keys=True, default=str)


def _loads(raw, default):
    if raw is None:
        return default
    if isinstance(raw, (list, dict)):
        return raw
    try:
        value = json.loads(raw)
    except (TypeError, ValueError):
        return default
    return value if isinstance(value, type(default)) else default


def _rows_to_entities(rows, prefix="e"):
    out = []
    for row in rows:
        raw = {col: row[f"{prefix}_{col}"] for col in _ENTITY_COLUMNS}
        out.append(_parse_entity(raw))
    return out


def _parse_entity(raw):
    ent = dict(raw)
    ent["derived_from"] = _loads(ent.get("derived_from"), [])
    ent["attrs"] = _loads(ent.get("attrs"), {})
    ent["stale"] = bool(ent.get("stale", 0))
    return ent


def _parse_relation(raw):
    rel = dict(raw)
    rel["derived_from"] = _loads(rel.get("derived_from"), [])
    rel["attrs"] = _loads(rel.get("attrs"), {})
    rel["stale"] = bool(rel.get("stale", 0))
    return rel


def _parse_common(raw, list_fields=("derived_from",), dict_fields=("attrs",)):
    row = dict(raw)
    for field in list_fields:
        if field in row:
            row[field] = _loads(row[field], [])
    for field in dict_fields:
        if field in row:
            row[field] = _loads(row[field], {})
    if "stale" in row:
        row["stale"] = bool(row["stale"])
    return row


def _select(prefix, columns):
    return ", ".join(f"{prefix}.{col} AS {prefix}_{col}" for col in columns)


def _chunks(seq, size=_IN_CHUNK):
    seq = list(seq)
    for start in range(0, len(seq), size):
        yield seq[start:start + size]


def _utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _prefix_match(component_qn, qualified_names):
    """True when component_qn is a prefix of (or equal to) any name."""
    return any(qn == component_qn or qn.startswith(component_qn)
               for qn in qualified_names)


class Graph:
    """A standalone system-intelligence graph backed by SQLite."""

    def __init__(self, conn, path):
        self._conn = conn
        self.path = path
        self._snapshot_id = None
        self._batch_depth = 0

    # ------------------------------------------------------------------ open

    @classmethod
    def open(cls, path, create=True):
        target = str(path)
        if target != ":memory:":
            target = str(Path(target).expanduser())
            if create:
                Path(target).parent.mkdir(parents=True, exist_ok=True)
            elif not Path(target).exists():
                raise FileNotFoundError(target)
        conn = sqlite3.connect(target)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        schema_file = Path(__file__).with_name("schema.sql")
        if create:
            conn.executescript(schema_file.read_text(encoding="utf-8"))
            conn.commit()
        else:
            found = conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='entity'"
            ).fetchone()
            if found is None:
                conn.close()
                raise RuntimeError(f"not a system_intel database: {target}")
        return cls(conn, target)

    def batch(self):
        """Defer commits until the outermost batch exits.

        With `with graph.batch(): ...` every upsert defers its commit and
        the outermost exit commits once.  Used by `persist.scan` so a
        large repository upserts at bulk speed without changing any
        public call signature.
        """
        from contextlib import contextmanager

        @contextmanager
        def _batch():
            self._batch_depth += 1
            try:
                yield self
            finally:
                self._batch_depth -= 1
                if self._batch_depth == 0:
                    self._conn.commit()

        return _batch()

    def _maybe_commit(self):
        if self._batch_depth == 0:
            self._conn.commit()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        if self._conn is not None:
            if exc_type is None:
                self._conn.commit()
            else:
                self._conn.rollback()
            self._conn.close()
            self._conn = None
        return False

    def close(self):
        if self._conn is not None:
            self._conn.commit()
            self._conn.close()
            self._conn = None

    def _require_conn(self):
        if self._conn is None:
            raise RuntimeError("graph is closed")
        return self._conn

    # ------------------------------------------------------------- snapshots

    def ensure_snapshot(self, repo_root, commit_sha):
        conn = self._require_conn()
        root = str(Path(repo_root).resolve())
        commit = str(commit_sha)
        conn.execute(
            "INSERT OR IGNORE INTO snapshot (repo_root, commit_sha, created_utc, schema_version)"
            " VALUES (?, ?, ?, ?)",
            (root, commit, _utc_now(), SCHEMA_VERSION),
        )
        row = conn.execute(
            "SELECT id FROM snapshot WHERE repo_root=? AND commit_sha=?", (root, commit)
        ).fetchone()
        conn.commit()
        self._snapshot_id = int(row["id"])
        return self._snapshot_id

    def _resolve_snapshot(self, snapshot_id=None):
        if snapshot_id is not None:
            return int(snapshot_id)
        if self._snapshot_id is not None:
            return self._snapshot_id
        row = self._require_conn().execute(
            "SELECT id FROM snapshot ORDER BY id DESC LIMIT 1"
        ).fetchone()
        if row is None:
            raise RuntimeError("no snapshot: call ensure_snapshot(repo_root, commit_sha) first")
        self._snapshot_id = int(row["id"])
        return self._snapshot_id

    def _optional_snapshot(self, snapshot_id=None):
        if snapshot_id is not None:
            return int(snapshot_id)
        if self._snapshot_id is not None:
            return self._snapshot_id
        row = self._require_conn().execute(
            "SELECT id FROM snapshot ORDER BY id DESC LIMIT 1"
        ).fetchone()
        return int(row["id"]) if row else None

    # -------------------------------------------------------------- upserts

    def upsert_entity(self, kind, name, qualified_name, *, snapshot_id=None,
                      file=None, line=None, tier=0, provenance="observed",
                      confidence=1.0, derived_from=(), last_verified=None,
                      uncertainty=None, attrs=None):
        conn = self._require_conn()
        snap = self._resolve_snapshot(snapshot_id)
        conn.execute(
            """
            INSERT INTO entity (snapshot_id, kind, name, qualified_name, file, line,
                                tier, provenance, confidence, derived_from,
                                last_verified, uncertainty, stale, attrs)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
            ON CONFLICT (snapshot_id, kind, qualified_name) DO UPDATE SET
                name=excluded.name, file=excluded.file, line=excluded.line,
                tier=excluded.tier, provenance=excluded.provenance,
                confidence=excluded.confidence, derived_from=excluded.derived_from,
                last_verified=excluded.last_verified,
                uncertainty=excluded.uncertainty, attrs=excluded.attrs, stale=0
            """,
            (snap, kind, name, qualified_name, file, line, int(tier),
             str(provenance), float(confidence), _dumps(list(derived_from)),
             last_verified, uncertainty, _dumps(dict(attrs or {}))),
        )
        row = conn.execute(
            "SELECT id FROM entity WHERE snapshot_id=? AND kind=? AND qualified_name=?",
            (snap, kind, qualified_name),
        ).fetchone()
        self._maybe_commit()
        return int(row["id"])

    def upsert_relation(self, src_id, dst_id, kind, *, snapshot_id=None, tier=0,
                        provenance="inferred", confidence=1.0, derived_from=(),
                        last_verified=None, uncertainty=None, attrs=None):
        conn = self._require_conn()
        if snapshot_id is not None:
            snap = int(snapshot_id)
        else:
            row = conn.execute(
                "SELECT snapshot_id FROM entity WHERE id=?", (int(src_id),)
            ).fetchone()
            if row is None:
                raise KeyError(f"entity {src_id} not found")
            snap = int(row["snapshot_id"])
        conn.execute(
            """
            INSERT INTO relation (snapshot_id, src_id, dst_id, kind, tier, provenance,
                                  confidence, derived_from, last_verified,
                                  uncertainty, stale, attrs)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
            ON CONFLICT (snapshot_id, src_id, dst_id, kind) DO UPDATE SET
                tier=excluded.tier, provenance=excluded.provenance,
                confidence=excluded.confidence, derived_from=excluded.derived_from,
                last_verified=excluded.last_verified,
                uncertainty=excluded.uncertainty, attrs=excluded.attrs, stale=0
            """,
            (snap, int(src_id), int(dst_id), kind, int(tier), str(provenance),
             float(confidence), _dumps(list(derived_from)), last_verified,
             uncertainty, _dumps(dict(attrs or {}))),
        )
        row = conn.execute(
            "SELECT id FROM relation WHERE snapshot_id=? AND src_id=? AND dst_id=? AND kind=?",
            (snap, int(src_id), int(dst_id), kind),
        ).fetchone()
        self._maybe_commit()
        return int(row["id"])

    def upsert_fact(self, subject, predicate, object, *, snapshot_id=None, tier=0,
                    provenance="observed", confidence=1.0, derived_from=(),
                    last_verified=None, uncertainty=None):
        conn = self._require_conn()
        snap = self._resolve_snapshot(snapshot_id)
        conn.execute(
            """
            INSERT INTO fact (snapshot_id, subject, predicate, object, tier, provenance,
                              confidence, derived_from, last_verified, uncertainty, stale)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            ON CONFLICT (snapshot_id, subject, predicate, object) DO UPDATE SET
                tier=excluded.tier, provenance=excluded.provenance,
                confidence=excluded.confidence, derived_from=excluded.derived_from,
                last_verified=excluded.last_verified,
                uncertainty=excluded.uncertainty, stale=0
            """,
            (snap, str(subject), str(predicate), str(object), int(tier),
             str(provenance), float(confidence), _dumps(list(derived_from)),
             last_verified, uncertainty),
        )
        row = conn.execute(
            "SELECT id FROM fact WHERE snapshot_id=? AND subject=? AND predicate=? AND object=?",
            (snap, str(subject), str(predicate), str(object)),
        ).fetchone()
        self._maybe_commit()
        return int(row["id"])

    def add_invariant(self, statement, component_qn=None, *, snapshot_id=None, tier=0,
                      provenance="declared", confidence=1.0, derived_from=(),
                      last_verified=None, uncertainty=None):
        conn = self._require_conn()
        snap = self._resolve_snapshot(snapshot_id)
        # SQLite treats NULLs as distinct in UNIQUE, so dedupe manually when
        # component_qn is absent.
        if component_qn is None:
            row = conn.execute(
                "SELECT id FROM invariant WHERE snapshot_id=? AND statement=? AND component_qn IS NULL",
                (snap, statement),
            ).fetchone()
        else:
            row = conn.execute(
                "SELECT id FROM invariant WHERE snapshot_id=? AND statement=? AND component_qn=?",
                (snap, statement, component_qn),
            ).fetchone()
        if row is not None:
            conn.execute(
                """UPDATE invariant SET tier=?, provenance=?, confidence=?, derived_from=?,
                   last_verified=?, uncertainty=?, stale=0 WHERE id=?""",
                (int(tier), str(provenance), float(confidence),
                 _dumps(list(derived_from)), last_verified, uncertainty, int(row["id"])),
            )
            inv_id = int(row["id"])
        else:
            cur = conn.execute(
                """INSERT INTO invariant (snapshot_id, statement, component_qn, tier,
                   provenance, confidence, derived_from, last_verified, uncertainty, stale)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)""",
                (snap, statement, component_qn, int(tier), str(provenance),
                 float(confidence), _dumps(list(derived_from)), last_verified, uncertainty),
            )
            inv_id = int(cur.lastrowid)
        conn.commit()
        return inv_id

    def add_contract(self, kind, name, component_qn=None, format=None, *,
                     snapshot_id=None, tier=0, provenance="declared",
                     confidence=1.0, derived_from=(), last_verified=None,
                     uncertainty=None, attrs=None):
        conn = self._require_conn()
        snap = self._resolve_snapshot(snapshot_id)
        conn.execute(
            """
            INSERT INTO contract (snapshot_id, kind, name, component_qn, format, tier,
                                  provenance, confidence, derived_from, last_verified,
                                  uncertainty, stale, attrs)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
            ON CONFLICT (snapshot_id, kind, name) DO UPDATE SET
                component_qn=excluded.component_qn, format=excluded.format,
                tier=excluded.tier, provenance=excluded.provenance,
                confidence=excluded.confidence, derived_from=excluded.derived_from,
                last_verified=excluded.last_verified,
                uncertainty=excluded.uncertainty, attrs=excluded.attrs, stale=0
            """,
            (snap, kind, name, component_qn, format, int(tier), str(provenance),
             float(confidence), _dumps(list(derived_from)), last_verified,
             uncertainty, _dumps(dict(attrs or {}))),
        )
        row = conn.execute(
            "SELECT id FROM contract WHERE snapshot_id=? AND kind=? AND name=?",
            (snap, kind, name),
        ).fetchone()
        conn.commit()
        return int(row["id"])

    def add_incident(self, summary, component_qn=None, occurred_utc=None,
                     severity=None, *, snapshot_id=None, tier=0,
                     provenance="historically_supported", confidence=1.0,
                     derived_from=(), last_verified=None, uncertainty=None,
                     attrs=None):
        # NOTE: schema v1 `incident` has no tier/last_verified columns; those
        # arguments are accepted for interface symmetry and not persisted.
        conn = self._require_conn()
        snap = self._resolve_snapshot(snapshot_id)
        cur = conn.execute(
            """INSERT INTO incident (snapshot_id, summary, component_qn, occurred_utc,
               severity, provenance, confidence, derived_from, uncertainty, stale, attrs)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)""",
            (snap, summary, component_qn, occurred_utc, severity, str(provenance),
             float(confidence), _dumps(list(derived_from)), uncertainty,
             _dumps(dict(attrs or {}))),
        )
        conn.commit()
        return int(cur.lastrowid)

    def add_change(self, commit_sha, summary, files=(), outcome=None, *,
                   snapshot_id=None, tier=0, provenance="historically_supported",
                   confidence=1.0, derived_from=(), last_verified=None,
                   uncertainty=None, attrs=None):
        # NOTE: schema v1 `change` has no tier/last_verified columns.
        conn = self._require_conn()
        snap = self._resolve_snapshot(snapshot_id)
        cur = conn.execute(
            """INSERT INTO change (snapshot_id, commit_sha, summary, files, outcome,
               provenance, confidence, derived_from, uncertainty, stale, attrs)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)""",
            (snap, commit_sha, summary, _dumps(list(files)), outcome,
             str(provenance), float(confidence), _dumps(list(derived_from)),
             uncertainty, _dumps(dict(attrs or {}))),
        )
        conn.commit()
        return int(cur.lastrowid)

    # ------------------------------------------------------------- staleness

    def mark_entity_stale(self, entity_id):
        conn = self._require_conn()
        cur = conn.execute("UPDATE entity SET stale=1 WHERE id=?", (int(entity_id),))
        if cur.rowcount == 0:
            raise KeyError(f"entity {entity_id} not found")
        conn.commit()

    def mark_entity_fresh(self, entity_id):
        conn = self._require_conn()
        cur = conn.execute("UPDATE entity SET stale=0 WHERE id=?", (int(entity_id),))
        if cur.rowcount == 0:
            raise KeyError(f"entity {entity_id} not found")
        conn.commit()

    def stale_sweep(self, snapshot_id, seen_by_kind):
        """Mark unseen entities of each given kind stale; return stale count.

        Only pass a kind when the extraction enumerated *all* entities of that
        kind for the snapshot; a partial set will mark live entities stale.
        """
        conn = self._require_conn()
        snap = int(snapshot_id)
        before = conn.execute(
            "SELECT COUNT(*) AS n FROM entity WHERE snapshot_id=? AND stale=1", (snap,)
        ).fetchone()["n"]
        for kind, seen in dict(seen_by_kind).items():
            # Mark-then-unmark so chunking cannot turn `NOT IN (chunk)` into
            # a per-chunk sweep of the other chunks' entities: every row of
            # the kind is marked stale first, then every SEEN qualified name
            # is restored fresh (chunked IN-clause).
            conn.execute(
                "UPDATE entity SET stale=1 WHERE snapshot_id=? AND kind=? AND stale=0",
                (snap, kind),
            )
            names = list(seen)
            for chunk in _chunks(names):
                placeholders = ",".join("?" for _ in chunk)
                conn.execute(
                    f"UPDATE entity SET stale=0 WHERE snapshot_id=? AND kind=? "
                    f"AND qualified_name IN ({placeholders})",
                    (snap, kind, *chunk),
                )
        after = conn.execute(
            "SELECT COUNT(*) AS n FROM entity WHERE snapshot_id=? AND stale=1", (snap,)
        ).fetchone()["n"]
        conn.commit()
        return int(after) - int(before)

    # --------------------------------------------------------------- lookups

    def entity_row(self, entity_id):
        row = self._require_conn().execute(
            "SELECT * FROM entity WHERE id=?", (int(entity_id),)
        ).fetchone()
        if row is None:
            raise KeyError(f"entity {entity_id} not found")
        return _parse_entity({k: row[k] for k in row.keys()})

    def find_entity(self, kind, qualified_name, include_stale=True):
        snap = self._optional_snapshot()
        if snap is None:
            return None
        clause = "" if include_stale else " AND stale=0"
        row = self._require_conn().execute(
            f"SELECT * FROM entity WHERE snapshot_id=? AND kind=? AND qualified_name=?{clause}",
            (snap, kind, qualified_name),
        ).fetchone()
        if row is None:
            return None
        return _parse_entity({k: row[k] for k in row.keys()})

    def find_entity_by_qn(self, qualified_name, include_stale=True, snapshot_id=None):
        """Exact qualified-name lookup across kinds; None if absent/ambiguous."""
        snap = self._optional_snapshot(snapshot_id)
        if snap is None:
            return None
        clause = "" if include_stale else " AND stale=0"
        rows = self._require_conn().execute(
            f"SELECT * FROM entity WHERE snapshot_id=? AND qualified_name=?{clause} ORDER BY id",
            (snap, qualified_name),
        ).fetchall()
        if len(rows) != 1:
            return None
        return _parse_entity({k: rows[0][k] for k in rows[0].keys()})

    def resolve_qn(self, qualified_name, include_stale=True, snapshot_id=None):
        """Exact qualified-name match first; otherwise the UNIQUE entity whose
        qualified name ends with ``::<qualified_name>`` (a bare symbol or a
        relative import target).  An ambiguous suffix resolves to None; the
        caller counts it as unresolved rather than guessing."""
        hit = self.find_entity_by_qn(qualified_name, include_stale, snapshot_id)
        if hit is not None:
            return hit
        snap = self._optional_snapshot(snapshot_id)
        if snap is None:
            return None
        clause = "" if include_stale else " AND stale=0"
        escaped = (
            qualified_name.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        )
        rows = self._require_conn().execute(
            f"SELECT * FROM entity WHERE snapshot_id=?{clause} "
            "AND (qualified_name=? OR qualified_name LIKE ? ESCAPE '\\') ORDER BY id",
            (snap, qualified_name, "%::" + escaped),
        ).fetchall()
        if len(rows) != 1:
            return None
        return _parse_entity({k: rows[0][k] for k in rows[0].keys()})

    def entities_by_kind(self, kind, include_stale=False):
        conn = self._require_conn()
        snap = self._resolve_snapshot(None)
        clause = "" if include_stale else " AND stale=0"
        rows = conn.execute(
            f"SELECT * FROM entity WHERE snapshot_id=? AND kind=?{clause} ORDER BY qualified_name",
            (snap, kind),
        ).fetchall()
        return [_parse_entity({k: r[k] for k in r.keys()}) for r in rows]

    def entities_by_file(self, file_path, *, snapshot_id=None, include_stale=True):
        conn = self._require_conn()
        snap = self._resolve_snapshot(snapshot_id)
        needle = str(file_path).replace("\\", "/").lstrip("./")
        clause = "" if include_stale else " AND stale=0"
        rows = conn.execute(
            f"SELECT * FROM entity WHERE snapshot_id=? AND file IS NOT NULL{clause} ORDER BY id",
            (snap,),
        ).fetchall()
        out = []
        for row in rows:
            ent = _parse_entity({k: row[k] for k in row.keys()})
            stored = str(ent["file"] or "").replace("\\", "/")
            if stored == needle or stored.endswith("/" + needle):
                out.append(ent)
        return out

    def neighbors(self, entity_id, kind=None, direction="both", include_stale=False):
        conn = self._require_conn()
        ent = self.entity_row(entity_id)
        snap = int(ent["snapshot_id"])
        out = []
        sides = []
        if direction in ("out", "both"):
            sides.append(("out", "r.src_id=?", "e.id=r.dst_id", int(entity_id)))
        if direction in ("in", "both"):
            sides.append(("in", "r.dst_id=?", "e.id=r.src_id", int(entity_id)))
        for side, where, join, value in sides:
            sql = (
                f"SELECT {_select('r', _RELATION_COLUMNS)}, {_select('e', _ENTITY_COLUMNS)} "
                f"FROM relation r JOIN entity e ON {join} "
                f"WHERE {where} AND r.snapshot_id=?"
            )
            params = [value, snap]
            if kind is not None:
                sql += " AND r.kind=?"
                params.append(kind)
            if not include_stale:
                sql += " AND r.stale=0 AND e.stale=0"
            sql += " ORDER BY r.id"
            for row in conn.execute(sql, params).fetchall():
                rel = _parse_relation({c: row[f"r_{c}"] for c in _RELATION_COLUMNS})
                rel["direction"] = side
                rel["entity"] = _parse_entity({c: row[f"e_{c}"] for c in _ENTITY_COLUMNS})
                out.append(rel)
        return out

    def edges_by_type(self, kind, include_stale=False):
        conn = self._require_conn()
        snap = self._resolve_snapshot(None)
        sql = (
            f"SELECT {_select('r', _RELATION_COLUMNS)}, {_select('s', _ENTITY_COLUMNS)}, "
            f"{_select('d', _ENTITY_COLUMNS)} "
            f"FROM relation r JOIN entity s ON s.id=r.src_id JOIN entity d ON d.id=r.dst_id "
            f"WHERE r.snapshot_id=? AND r.kind=?"
        )
        if not include_stale:
            sql += " AND r.stale=0 AND s.stale=0 AND d.stale=0"
        sql += " ORDER BY r.id"
        out = []
        for row in conn.execute(sql, (snap, kind)).fetchall():
            rel = _parse_relation({c: row[f"r_{c}"] for c in _RELATION_COLUMNS})
            rel["src"] = _parse_entity({c: row[f"s_{c}"] for c in _ENTITY_COLUMNS})
            rel["dst"] = _parse_entity({c: row[f"d_{c}"] for c in _ENTITY_COLUMNS})
            out.append(rel)
        return out

    def contracts(self, component_qn=None):
        snap = self._resolve_snapshot(None)
        rows = self._contracts_for_snapshot(snap)
        if component_qn is None:
            return rows
        return [c for c in rows if _prefix_match(c.get("component_qn"), [component_qn])]

    def invariants(self, component_qn=None):
        snap = self._resolve_snapshot(None)
        rows = self._invariants_for_snapshot(snap)
        if component_qn is None:
            return rows
        return [i for i in rows if _prefix_match(i.get("component_qn"), [component_qn])]

    def _contracts_for_snapshot(self, snapshot_id):
        rows = self._require_conn().execute(
            "SELECT * FROM contract WHERE snapshot_id=? ORDER BY id", (int(snapshot_id),)
        ).fetchall()
        return [_parse_common({k: row[k] for k in row.keys()}) for row in rows]

    def _invariants_for_snapshot(self, snapshot_id):
        rows = self._require_conn().execute(
            "SELECT * FROM invariant WHERE snapshot_id=? ORDER BY id", (int(snapshot_id),)
        ).fetchall()
        return [_parse_common({k: row[k] for k in row.keys()}) for row in rows]

    # ---------------------------------------------------------------- search

    def find_path(self, src_id, dst_id, *, max_depth=6, kinds=None):
        conn = self._require_conn()
        src_id, dst_id = int(src_id), int(dst_id)
        if src_id == dst_id:
            return [src_id]
        snap = self._resolve_snapshot(None)
        allowed = set(kinds) if kinds else None
        rows = conn.execute(
            "SELECT src_id, dst_id, kind FROM relation WHERE snapshot_id=? AND stale=0",
            (snap,),
        ).fetchall()
        adjacency = {}
        for row in rows:
            if allowed is not None and row["kind"] not in allowed:
                continue
            adjacency.setdefault(row["src_id"], []).append(row["dst_id"])
        queue = [src_id]
        depth = {src_id: 0}
        parent = {src_id: None}
        head = 0
        while head < len(queue):
            node = queue[head]
            head += 1
            if depth[node] >= max_depth:
                continue
            for nxt in adjacency.get(node, ()):
                if nxt in depth:
                    continue
                depth[nxt] = depth[node] + 1
                parent[nxt] = node
                if nxt == dst_id:
                    path = []
                    cur = dst_id
                    while cur is not None:
                        path.append(cur)
                        cur = parent[cur]
                    path.reverse()
                    return path
                queue.append(nxt)
        return None

    # ---------------------------------------------------------------- closure

    def _closure(self, entity_id, *, max_depth, reverse):
        conn = self._require_conn()
        root = self.entity_row(entity_id)
        snap = int(root["snapshot_id"])
        placeholders = ",".join("?" for _ in IMPACT_EDGE_KINDS)
        rows = conn.execute(
            f"SELECT src_id, dst_id FROM relation WHERE snapshot_id=? AND stale=0 "
            f"AND kind IN ({placeholders})",
            (snap, *IMPACT_EDGE_KINDS),
        ).fetchall()
        adjacency = {}
        for row in rows:
            if reverse:
                key, value = row["dst_id"], row["src_id"]
            else:
                key, value = row["src_id"], row["dst_id"]
            adjacency.setdefault(key, []).append(value)

        depth_by_id = {root["id"]: 0}
        level_entities = {0: [root]}
        frontier = [root["id"]]
        level = 0
        while frontier and level < max_depth:
            level += 1
            nxt = []
            for node in frontier:
                for other in adjacency.get(node, ()):
                    if other in depth_by_id:
                        continue
                    depth_by_id[other] = level
                    nxt.append(other)
            if nxt:
                level_entities[level] = [self.entity_row(i) for i in nxt]
            frontier = nxt

        levels = []
        impacted = []
        for dep in sorted(level_entities):
            ents = sorted(level_entities[dep], key=lambda e: (e["qualified_name"], e["id"]))
            levels.append({"depth": dep, "entities": ents})
            for ent in ents:
                item = dict(ent)
                item["depth"] = dep
                impacted.append(item)

        qns = [e["qualified_name"] for e in impacted]
        ids = [e["id"] for e in impacted]

        contracts = [c for c in self._contracts_for_snapshot(snap)
                     if c.get("component_qn") and _prefix_match(c["component_qn"], qns)]
        invariants = [i for i in self._invariants_for_snapshot(snap)
                      if i.get("component_qn") and _prefix_match(i["component_qn"], qns)]

        incidents = []
        for row in conn.execute(
            "SELECT * FROM incident WHERE snapshot_id=? ORDER BY id", (snap,)
        ).fetchall():
            item = _parse_common({k: row[k] for k in row.keys()})
            if item.get("component_qn") and _prefix_match(item["component_qn"], qns):
                incidents.append(item)

        test_by_id = {e["id"]: e for e in impacted if e["kind"] == "Test"}
        for chunk in _chunks(ids):
            placeholders = ",".join("?" for _ in chunk)
            tests_rows = conn.execute(
                f"SELECT DISTINCT src_id FROM relation WHERE snapshot_id=? AND kind='tests' "
                f"AND stale=0 AND dst_id IN ({placeholders})",
                (snap, *chunk),
            ).fetchall()
            for row in tests_rows:
                if row["src_id"] not in test_by_id:
                    try:
                        test_by_id[row["src_id"]] = self.entity_row(row["src_id"])
                    except KeyError:
                        continue
        tests = sorted(test_by_id.values(), key=lambda e: e["qualified_name"])

        return {
            "roots": [root],
            "levels": levels,
            "impacted": impacted,
            "contracts": contracts,
            "invariants": invariants,
            "tests": tests,
            "incidents": incidents,
        }

    def impact(self, entity_id, *, max_depth=6):
        return self._closure(entity_id, max_depth=max_depth, reverse=True)

    def dependencies(self, entity_id, *, max_depth=6):
        return self._closure(entity_id, max_depth=max_depth, reverse=False)

    # --------------------------------------------------------- change surface

    def change_surface(self, qualified_names, *, max_depth=6):
        conn = self._require_conn()
        snap = self._resolve_snapshot(None)
        rows = conn.execute(
            "SELECT * FROM entity WHERE snapshot_id=? ORDER BY qualified_name, id", (snap,)
        ).fetchall()
        everything = [_parse_entity({k: r[k] for k in r.keys()}) for r in rows]

        matched = {}
        unmatched = []
        seed_ids = []
        for qn in qualified_names:
            exact = [e for e in everything if e["qualified_name"] == qn]
            hits = exact if exact else [e for e in everything if e["qualified_name"].endswith(qn)]
            if hits:
                matched[qn] = hits
                for ent in hits:
                    if ent["id"] not in seed_ids:
                        seed_ids.append(ent["id"])
            else:
                unmatched.append(qn)

        impacted_by_id = {}
        contracts = {}
        invariants = {}
        tests = {}
        incidents = {}
        for seed in seed_ids:
            closure = self.impact(seed, max_depth=max_depth)
            for level in closure["levels"]:
                for ent in level["entities"]:
                    prev = impacted_by_id.get(ent["id"])
                    if prev is None or level["depth"] < prev["depth"]:
                        impacted_by_id[ent["id"]] = {"depth": level["depth"], "entity": ent}
            for item in closure["contracts"]:
                contracts[item["id"]] = item
            for item in closure["invariants"]:
                invariants[item["id"]] = item
            for item in closure["tests"]:
                tests[item["id"]] = item
            for item in closure["incidents"]:
                incidents[item["id"]] = item

        impacted = []
        for entry in sorted(impacted_by_id.values(), key=lambda v: (v["depth"], v["entity"]["qualified_name"])):
            item = dict(entry["entity"])
            item["depth"] = entry["depth"]
            impacted.append(item)

        surfaces = []
        for item in tests.values():
            surfaces.append(item["qualified_name"])
        for item in list(contracts.values()) + list(invariants.values()):
            if item.get("component_qn"):
                surfaces.append(item["component_qn"])
        for ent in impacted:
            if ent["kind"] == "Service":
                surfaces.append(ent["qualified_name"])
        likely = sorted(dict.fromkeys(surfaces))

        return {
            "matched": matched,
            "unmatched": unmatched,
            "impacted": impacted,
            "contracts": sorted(contracts.values(), key=lambda c: c["id"]),
            "invariants": sorted(invariants.values(), key=lambda i: i["id"]),
            "tests": sorted(tests.values(), key=lambda t: t["qualified_name"]),
            "incidents": sorted(incidents.values(), key=lambda i: i["id"]),
            "likely_regression_surfaces": likely,
        }

    # ------------------------------------------------------------------ stats

    def stats(self, snapshot_id=None):
        conn = self._require_conn()
        snap = snapshot_id if snapshot_id is not None else self._snapshot_id

        def where(alias=""):
            return (" WHERE " + alias + "snapshot_id=?") if snap is not None else ""

        def args():
            return (int(snap),) if snap is not None else ()

        def count(table, extra=""):
            if snap is None:
                sql = f"SELECT COUNT(*) AS n FROM {table}"
                if extra:
                    sql += " WHERE 1=1" + extra
                return int(conn.execute(sql).fetchone()["n"])
            return int(conn.execute(
                f"SELECT COUNT(*) AS n FROM {table} WHERE snapshot_id=?{extra}", (int(snap),)
            ).fetchone()["n"])

        by_kind = {}
        for row in conn.execute(
            f"SELECT kind, COUNT(*) AS n FROM entity{where()} GROUP BY kind ORDER BY kind", args()
        ).fetchall():
            by_kind[row["kind"]] = int(row["n"])
        relations_by_kind = {}
        for row in conn.execute(
            f"SELECT kind, COUNT(*) AS n FROM relation{where()} GROUP BY kind ORDER BY kind", args()
        ).fetchall():
            relations_by_kind[row["kind"]] = int(row["n"])
        version_row = conn.execute("SELECT MAX(version) AS v FROM schema_version").fetchone()
        return {
            "schema_version": int(version_row["v"]) if version_row and version_row["v"] is not None else SCHEMA_VERSION,
            "snapshots": int(conn.execute("SELECT COUNT(*) AS n FROM snapshot").fetchone()["n"]),
            "entities_by_kind": by_kind,
            "relations_by_kind": relations_by_kind,
            "facts": count("fact"),
            "invariants": count("invariant"),
            "contracts": count("contract"),
            "incidents": count("incident"),
            "changes": count("change"),
            "stale_entities": count("entity", " AND stale=1"),
            "stale_relations": count("relation", " AND stale=1"),
        }

    # --------------------------------------------------------------- export

    def export_json(self, snapshot_id=None):
        conn = self._require_conn()
        snap = snapshot_id if snapshot_id is not None else self._snapshot_id

        def query(sql, parse=None, bind=True):
            params = (int(snap),) if (bind and snap is not None) else ()
            rows = conn.execute(sql, params).fetchall()
            out = []
            for row in rows:
                item = {k: row[k] for k in row.keys()}
                if parse is not None:
                    item = parse(item)
                out.append(item)
            return out

        suffix = " WHERE snapshot_id=?" if snap is not None else ""
        version_row = conn.execute("SELECT MAX(version) AS v FROM schema_version").fetchone()
        return {
            "schema_version": int(version_row["v"]) if version_row and version_row["v"] is not None else SCHEMA_VERSION,
            "snapshots": query("SELECT * FROM snapshot ORDER BY id", bind=False),
            "entities": query(f"SELECT * FROM entity{suffix} ORDER BY id", _parse_entity),
            "relations": query(f"SELECT * FROM relation{suffix} ORDER BY id", _parse_relation),
            "facts": query(f"SELECT * FROM fact{suffix} ORDER BY id", _parse_common),
            "invariants": query(f"SELECT * FROM invariant{suffix} ORDER BY id", _parse_common),
            "contracts": query(f"SELECT * FROM contract{suffix} ORDER BY id", _parse_common),
            "incidents": query(f"SELECT * FROM incident{suffix} ORDER BY id", _parse_common),
            "changes": query(f"SELECT * FROM change{suffix} ORDER BY id",
                             lambda d: _parse_common(d, list_fields=("derived_from", "files"))),
        }
