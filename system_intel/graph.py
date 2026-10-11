"""Core knowledge graph for the Tangerine System Intelligence platform.

Stdlib-only (sqlite3 / json / pathlib / datetime / hashlib).  The SQLite
schema is loaded verbatim from ``schema.sql`` next to this module; that file
is the authoritative source for table and column names.

The graph stores what is *known* about a repository: entities, relations,
facts, invariants, contracts, historical records (incidents, changes),
unresolved edges, support/evidence and provider capability records.  Every
row is bound to a snapshot; a snapshot is identified by the revision tuple
from INTERFACES.md §1 and is either a mutable ``draft`` or an immutable
``finalized`` record.

Snapshot semantics (v2 / P0-1, P0-4, P0-5, P0-6)
-------------------------------------------------
* One revision tuple -> at most one snapshot.  A scan either reuses the
  finalized snapshot for that tuple or writes a new draft and finalizes it
  inside one transaction.
* Finalized snapshots are immutable, enforced by BEFORE triggers in
  ``schema.sql``: nothing inside becomes "stale".  Removed content is
  represented by a newer snapshot and reported by :meth:`diff_snapshots`.
* Reads (:meth:`export_json`, :meth:`stats`, :meth:`completeness`, ...)
  resolve exactly ONE snapshot -- the latest finalized one by default, by
  ``ORDER BY id DESC LIMIT 1`` -- and never union rows across snapshots.
  When there is no finalized snapshot they raise :class:`SnapshotError`.
* Relations resolve endpoints by typed ``(kind, stable_id)`` exact match.
  Unresolved targets keep a first-class ``unresolved_edge`` row AND a
  relation row with ``resolved=0``; cross-snapshot relations are impossible
  through the composite foreign keys.
* ``batch()`` commits only on success and rolls back on exception;
  ``close()`` never commits a dirty transaction -- it rolls back.
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

SCHEMA_VERSION = 3

EPISTEMIC_STATES = (
    "observed", "declared", "inferred", "historically_supported",
    "uncertain", "contradicted",
)

PROVENANCE_KINDS = (
    "source_scan", "compiler", "runtime_trace", "history", "caller",
)

COMPLETENESS_VERDICTS = ("complete", "partial", "unavailable", "unknown")

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

# The only entity kind allowed to source a `tests` edge (P0-6).
TEST_SOURCE_KIND = "Test"

_VERDICT_RANK = {"complete": 3, "partial": 2, "unknown": 1, "unavailable": 0}

_ENTITY_COLUMNS = (
    "id", "snapshot_id", "kind", "name", "qualified_name", "file", "line",
    "tier", "provenance", "confidence", "derived_from", "last_verified",
    "uncertainty", "stale", "attrs", "stable_id", "epistemic_state",
    "analysis_depth", "completeness", "provider", "provider_revision",
)
_RELATION_COLUMNS = (
    "id", "snapshot_id", "src_id", "dst_id", "kind", "tier", "provenance",
    "confidence", "derived_from", "last_verified", "uncertainty", "stale",
    "attrs", "src_key", "dst_key", "resolved", "epistemic_state",
    "analysis_depth", "completeness", "site_completeness",
    "target_resolution_completeness", "provider", "provider_revision",
)

_IN_CHUNK = 500

_KIND_STABLE_PREFIX = {
    "Repository": "repo",
    "File": "file",
    "Module": "module",
    "Package": "pkg",
    "Schema": "schema",
    "Configuration": "config",
    "Test": "test",
    "Project": "project",
    "Deployment": "deployment",
    "Service": "service",
}


class SnapshotError(RuntimeError, ValueError):
    """Raised when a snapshot is missing, ambiguous or immutable."""


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


def _utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def identity_revision_digest(identity: dict) -> str:
    """sha256 over the canonical join of the six identity fields (v3).

    Identity levels: ``repo_identity`` + ``source_revision`` + ``tree_digest``
    + ``semantic_configuration`` describe the SOURCE revision (level 1);
    ``provider_set_digest`` names which providers observed it;
    ``observation_set_digest`` names the immutable federated observation set
    (level 3).  A new runtime/verification observation therefore produces a
    new revision digest even when the source is unchanged.
    """
    fields = (
        str(identity.get("repo_identity", "")),
        str(identity.get("source_revision", "")),
        str(identity.get("tree_digest", "")),
        str(identity.get("semantic_configuration", "{}") or "{}"),
        str(identity.get("provider_set_digest", "") or ""),
        str(identity.get("observation_set_digest", "") or ""),
    )
    return hashlib.sha256("\x1f".join(fields).encode("utf-8")).hexdigest()


def source_revision_digest(repo_identity, source_revision, tree_digest, target,
                           semantic_configuration) -> str:
    """sha256 over the level-1 source-revision identity fields."""
    fields = (
        str(repo_identity),
        str(source_revision),
        str(tree_digest),
        str(target or ""),
        str(semantic_configuration or "{}"),
    )
    return hashlib.sha256("\x1f".join(fields).encode("utf-8")).hexdigest()


def observation_set_digest(observation_digests) -> str:
    """sha256 over the canonical sorted observation digests (level 3)."""
    canonical = json.dumps(
        sorted(str(d) for d in observation_digests),
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def derive_stable_id(kind: str, qualified_name: str | None) -> str:
    """Deterministic stable id fallback when a caller omits one.

    Extraction/provider code should always supply the §4 spelling; this is
    the last-resort derivation (kind + qualified name) so the schema's
    NOT NULL stable_id is always populated.
    """
    qn = str(qualified_name if qualified_name is not None else "")
    if kind == "Repository":
        return "repo:."
    prefix = _KIND_STABLE_PREFIX.get(str(kind), str(kind).lower() or "entity")
    return f"{prefix}:{qn}"


def fact_stable_id(stable_subject, predicate, object) -> str:
    """Content-derived fact identity: subject ID + predicate + object.

    Several different facts about the same subject must never share an
    identity (the v2 protocol derived Fact ids from the subject alone, so
    ``publishes X`` and ``publishes Y`` collided).
    """
    canonical = "\x1f".join((str(stable_subject), str(predicate), str(object)))
    return "fact:" + hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _derive_epistemics(provenance, epistemic_state, analysis_depth):
    """Map `provenance` to (epistemic_state, analysis_depth) per §0.

    ``runtime`` provenance maps to observed / analysis_depth 4 -- never to
    ``inferred``.  Explicit caller values win.
    """
    state = epistemic_state
    depth = analysis_depth
    if provenance == "runtime":
        if state is None:
            state = "observed"
        if depth is None:
            depth = 4
    if state is None:
        state = provenance if provenance in EPISTEMIC_STATES else "observed"
    if depth is None:
        depth = 0
    return str(state), int(depth)


def _worst_verdict(*verdicts):
    best = None
    for verdict in verdicts:
        if verdict not in _VERDICT_RANK:
            verdict = "unknown"
        if best is None or _VERDICT_RANK[verdict] < _VERDICT_RANK[best]:
            best = verdict
    return best or "unknown"


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
    rel["resolved"] = int(rel.get("resolved", 1))
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


def _structured_key(*parts) -> str:
    """A collision-free map key from semantic identity parts.

    JSON array (not separator-joined): qualified names / contract keys may
    legitimately contain `|`, so splitting a joined key is unsound.
    """
    return json.dumps([str(part if part is not None else "") for part in parts],
                      separators=(",", ":"))


def _prefix_match(component_qn, qualified_names):
    """True when component_qn equals, or is a NAMESPACE-SEGMENT prefix of,
    a qualified name.

    Raw ``startswith`` is not enough: ``foo.bar`` must not be treated as a
    prefix of ``foo.barbaz``.  Only ``::`` (module paths) and ``.``
    (dotted paths) segment boundaries count.
    """
    if not component_qn:
        return False
    for qn in qualified_names:
        if qn == component_qn:
            return True
        if qn.startswith(component_qn + "::") or qn.startswith(component_qn + "."):
            return True
    return False


# v3 column additions applied to databases created by older schema
# versions (fresh databases already carry them in schema.sql).  SQLite
# cannot add a UNIQUE constraint in place; the value-level integrity is
# enforced by the revision-digest check in finalize_snapshot.
_V3_COLUMN_ADDITIONS = (
    ("snapshot", "observation_set_digest", "TEXT NOT NULL DEFAULT ''"),
    ("snapshot", "source_revision_id", "INTEGER"),
    ("relation", "provider_revision", "TEXT NOT NULL DEFAULT ''"),
    ("relation", "site_completeness", "TEXT NOT NULL DEFAULT 'unknown'"),
    ("relation", "target_resolution_completeness", "TEXT NOT NULL DEFAULT 'unknown'"),
    ("unresolved_edge", "resolution_completeness", "TEXT NOT NULL DEFAULT 'unknown'"),
    ("support", "observation_id", "INTEGER"),
    ("provider_record", "scope", "TEXT NOT NULL DEFAULT '{}'"),
    ("provider_record", "authority", "TEXT NOT NULL DEFAULT 'fallback'"),
    ("fact", "stable_id", "TEXT NOT NULL DEFAULT ''"),
    ("contract", "stable_id", "TEXT NOT NULL DEFAULT ''"),
)


# Snapshot-owned family dropped when an EMPTY pre-v3 database is rebuilt
# (children before parents).  SQLite cannot add UNIQUE/composite-FK
# constraints in place, so a data-bearing v2 database is REFUSED (rescan
# into a fresh database) rather than silently relabeled as v3.
_V3_FAMILY_TABLES = (
    "snapshot_observation", "provider_observation", "source_revision",
    "support", "unresolved_edge", "relation", "evidence", "provider_record",
    "fact", "invariant", "contract", "incident", "change", "entity",
    "snapshot", "schema_version",
)


def _ensure_v3_structure(conn):
    """Fail closed on a data-bearing pre-v3 database; rebuild empty ones.

    A pre-v3 database cannot be upgraded in place: its snapshot UNIQUE
    constraint predates `observation_set_digest`, and the v3 support/
    evidence composite FKs and immutability triggers do not exist.  An
    EMPTY pre-v3 database is rebuilt from schema.sql (no data to lose); a
    database with any snapshot row is refused with the rescan instruction.
    """
    marker = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_version'"
    ).fetchone()
    if marker is None:
        return  # fresh file: schema.sql creates the v3 structure
    version_row = conn.execute("SELECT version FROM schema_version LIMIT 1").fetchone()
    version = int(version_row["version"]) if version_row is not None else 0
    if version >= SCHEMA_VERSION:
        return
    has_snapshot = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='snapshot'"
    ).fetchone() is not None
    if has_snapshot:
        rows = int(conn.execute("SELECT COUNT(*) AS n FROM snapshot").fetchone()["n"])
        if rows > 0:
            raise SnapshotError(
                f"database schema version {version} contains {rows} snapshot row(s); "
                f"schema v{SCHEMA_VERSION} adds structural constraints (three-level "
                "observation model, composite endpoint/evidence foreign keys, frozen "
                "snapshot metadata) that SQLite cannot add in place — rescan into a "
                "fresh database instead"
            )
    conn.execute("PRAGMA foreign_keys = OFF")
    for table in _V3_FAMILY_TABLES:
        conn.execute(f"DROP TABLE IF EXISTS {table}")
    conn.execute("PRAGMA foreign_keys = ON")


def _migrate_added_columns(conn):
    """Add any missing v3 columns to pre-v3 tables (idempotent)."""
    for table, column, decl in _V3_COLUMN_ADDITIONS:
        row = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
            (table,),
        ).fetchone()
        if row is None:
            continue
        existing = {r["name"] for r in conn.execute(f"PRAGMA table_info({table})")}
        if column not in existing:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {decl}")


class Graph:
    """A standalone system-intelligence graph backed by SQLite."""

    def __init__(self, conn, path):
        self._conn = conn
        self.path = path
        self._snapshot_id = None
        self._batch_depth = 0
        self._batch_failed = False

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
            _ensure_v3_structure(conn)
            conn.executescript(schema_file.read_text(encoding="utf-8"))
            _migrate_added_columns(conn)
            conn.commit()
        else:
            found = conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='entity'"
            ).fetchone()
            if found is None:
                conn.close()
                raise RuntimeError(f"not a system_intel database: {target}")
        version_row = conn.execute("SELECT MIN(version) AS v, MAX(version) AS v2 FROM schema_version").fetchone()
        version = int(version_row["v2"] or 0) if version_row else 0
        columns = {row["name"] for row in conn.execute("PRAGMA table_info(snapshot)")}
        if "repo_identity" not in columns or version != SCHEMA_VERSION:
            conn.close()
            raise RuntimeError(
                f"database {target!r} uses schema v{version} (expected v{SCHEMA_VERSION}); "
                "system_intel v2 requires a fresh database path -- rescan into a new file"
            )
        return cls(conn, target)

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        if self._conn is not None:
            if self._conn.in_transaction:
                self._conn.rollback()
            self._conn.close()
            self._conn = None
        return False

    def close(self):
        """Close the connection; a dirty transaction is rolled back, never committed."""
        if self._conn is not None:
            if self._conn.in_transaction:
                self._conn.rollback()
            self._conn.close()
            self._conn = None

    def _require_conn(self):
        if self._conn is None:
            raise RuntimeError("graph is closed")
        return self._conn

    # ------------------------------------------------------------ transaction

    def batch(self):
        """Run a block as one all-or-nothing transaction (P0-4).

        Commits ONLY when the block exits without an exception; on any
        exception the transaction is rolled back and the exception is
        re-raised.  There is deliberately no commit in a ``finally`` block.
        """
        from contextlib import contextmanager

        @contextmanager
        def _batch():
            self._batch_depth += 1
            try:
                yield self
            except BaseException:
                self._batch_depth -= 1
                self._batch_failed = True
                if self._batch_depth == 0:
                    self._batch_failed = False
                    self._conn.rollback()
                raise
            else:
                self._batch_depth -= 1
                if self._batch_depth == 0:
                    if self._batch_failed:
                        self._batch_failed = False
                        self._conn.rollback()
                    else:
                        self._conn.commit()

        return _batch()

    def _maybe_commit(self):
        if self._batch_depth == 0:
            self._conn.commit()

    # ------------------------------------------------------------- snapshots

    @staticmethod
    def _snapshot_dict(row):
        data = {k: row[k] for k in row.keys()}
        data["commit_sha"] = data.get("source_revision")
        return data

    def latest_finalized_snapshot(self):
        """The single deterministic latest finalized snapshot, or None."""
        row = self._require_conn().execute(
            "SELECT * FROM snapshot WHERE state='finalized' ORDER BY id DESC LIMIT 1"
        ).fetchone()
        return self._snapshot_dict(row) if row is not None else None

    def snapshot_by_revision(self, revision_digest):
        row = self._require_conn().execute(
            "SELECT * FROM snapshot WHERE revision_digest=? ORDER BY id DESC LIMIT 1",
            (str(revision_digest),),
        ).fetchone()
        return self._snapshot_dict(row) if row is not None else None

    def snapshot_for(self, identity: dict):
        """The snapshot for an identity tuple (any state), or None."""
        row = self._require_conn().execute(
            "SELECT * FROM snapshot WHERE repo_identity=? AND source_revision=? "
            "AND tree_digest=? AND semantic_configuration=? AND provider_set_digest=? "
            "AND observation_set_digest=? ORDER BY id DESC LIMIT 1",
            (
                str(identity.get("repo_identity", "")),
                str(identity.get("source_revision", "")),
                str(identity.get("tree_digest", "")),
                str(identity.get("semantic_configuration", "{}") or "{}"),
                str(identity.get("provider_set_digest", "") or ""),
                str(identity.get("observation_set_digest", "") or ""),
            ),
        ).fetchone()
        return self._snapshot_dict(row) if row is not None else None

    # ------------------------------------------------- observations (v3)

    def upsert_source_revision(self, identity: dict) -> int:
        """Insert (or reuse) the level-1 source revision; return its id.

        Identity is (repo_identity, source_revision, tree_digest, target,
        semantic_configuration); the revision_digest is recomputed here so a
        caller can never persist a digest that disagrees with the fields.
        """
        conn = self._require_conn()
        repo_identity = str(identity.get("repo_identity", ""))
        source_revision = str(identity.get("source_revision", ""))
        tree_digest = str(identity.get("tree_digest", ""))
        target = str(identity.get("target", "") or "")
        semantic = str(identity.get("semantic_configuration", "{}") or "{}")
        digest = source_revision_digest(repo_identity, source_revision, tree_digest,
                                        target, semantic)
        row = conn.execute(
            "SELECT id FROM source_revision WHERE repo_identity=? AND source_revision=? "
            "AND tree_digest=? AND target=? AND semantic_configuration=?",
            (repo_identity, source_revision, tree_digest, target, semantic),
        ).fetchone()
        if row is not None:
            return int(row["id"])
        cur = conn.execute(
            """INSERT INTO source_revision (repo_identity, source_revision, tree_digest,
               target, semantic_configuration, revision_digest, created_utc)
               VALUES (?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT (repo_identity, source_revision, tree_digest, target,
                            semantic_configuration) DO NOTHING""",
            (repo_identity, source_revision, tree_digest, target, semantic,
             digest, _utc_now()),
        )
        if cur.lastrowid:
            source_id = int(cur.lastrowid)
        else:
            row = conn.execute(
                "SELECT id FROM source_revision WHERE revision_digest=?", (digest,)
            ).fetchone()
            source_id = int(row["id"])
        self._maybe_commit()
        return source_id

    def source_revision_row(self, source_revision_id) -> dict | None:
        row = self._require_conn().execute(
            "SELECT * FROM source_revision WHERE id=?", (int(source_revision_id),)
        ).fetchone()
        return {k: row[k] for k in row.keys()} if row is not None else None

    def add_provider_observation(self, source_revision_id, provider, *,
                                 provider_version="", observation_kind="static",
                                 observation_digest="", scope=None,
                                 semantic_configuration="{}",
                                 authority="fallback",
                                 enumeration_completeness="unknown",
                                 resolution_completeness="unknown") -> int:
        """Append one immutable provider observation; return its id.

        The observation_digest is content-derived by the caller and must be
        non-empty (a fresh observation must never be confused with a reused
        one).
        """
        conn = self._require_conn()
        if str(provider).strip() == "":
            raise SnapshotError("provider_observation requires a provider id")
        if str(observation_digest).strip() == "":
            raise SnapshotError("provider_observation requires a content digest")
        scope_json = _dumps(scope if isinstance(scope, dict) else {})
        params = (
            str(provider), str(provider_version), int(source_revision_id),
            str(observation_kind), str(observation_digest), scope_json,
            str(semantic_configuration or "{}"), str(authority),
            str(enumeration_completeness), str(resolution_completeness),
            _utc_now(),
        )
        conn.execute(
            """INSERT INTO provider_observation (provider, provider_version,
               source_revision_id, observation_kind, observation_digest, scope,
               semantic_configuration, authority, enumeration_completeness,
               resolution_completeness, created_utc)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT (provider, provider_version, source_revision_id,
                            observation_kind, observation_digest) DO NOTHING""",
            params,
        )
        row = conn.execute(
            "SELECT id FROM provider_observation WHERE provider=? AND provider_version=? "
            "AND source_revision_id=? AND observation_kind=? AND observation_digest=?",
            params[:5],
        ).fetchone()
        self._maybe_commit()
        return int(row["id"])

    def link_snapshot_observation(self, snapshot_id, observation_id) -> None:
        conn = self._require_conn()
        conn.execute(
            "INSERT OR IGNORE INTO snapshot_observation (snapshot_id, observation_id) "
            "VALUES (?, ?)",
            (int(snapshot_id), int(observation_id)),
        )
        self._maybe_commit()

    def observations(self, snapshot_id=None) -> list[dict]:
        """The immutable observation set of a snapshot, digest-ordered."""
        conn = self._require_conn()
        snap = self._resolve_read_snapshot(snapshot_id)
        rows = conn.execute(
            """SELECT o.*, so.snapshot_id AS linked_snapshot_id
               FROM snapshot_observation so
               JOIN provider_observation o ON o.id = so.observation_id
               WHERE so.snapshot_id = ?
               ORDER BY o.provider, o.observation_kind, o.observation_digest""",
            (int(snap["id"]),),
        ).fetchall()
        out = []
        for row in rows:
            item = {k: row[k] for k in row.keys()}
            item["scope"] = _loads(item.get("scope"), {})
            out.append(item)
        return out

    def begin_draft(self, identity: dict) -> int:
        """Insert a draft snapshot for an identity tuple; return its id.

        Idempotent for an existing draft with the same tuple; raises
        :class:`SnapshotError` when the tuple is already finalized.
        """
        conn = self._require_conn()
        existing = self.snapshot_for(identity)
        if existing is not None:
            if existing["state"] == "draft":
                self._snapshot_id = int(existing["id"])
                return self._snapshot_id
            raise SnapshotError(
                f"revision {existing['revision_digest']} is already finalized; "
                "one revision tuple maps to at most one snapshot"
            )
        revision_digest = identity.get("revision_digest") or identity_revision_digest(identity)
        cur = conn.execute(
            """
            INSERT INTO snapshot (repo_root, repo_identity, source_revision, tree_digest,
                                  semantic_configuration, provider_set_digest,
                                  observation_set_digest, source_revision_id,
                                  revision_digest, state, created_utc, finalized_utc)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'draft', ?, NULL)
            """,
            (
                identity.get("repo_root"),
                str(identity.get("repo_identity", "")),
                str(identity.get("source_revision", "")),
                str(identity.get("tree_digest", "")),
                str(identity.get("semantic_configuration", "{}") or "{}"),
                str(identity.get("provider_set_digest", "") or ""),
                str(identity.get("observation_set_digest", "") or ""),
                int(identity["source_revision_id"])
                if identity.get("source_revision_id") is not None else None,
                str(revision_digest),
                _utc_now(),
            ),
        )
        snap = int(cur.lastrowid)
        self._snapshot_id = snap
        for observation_id in identity.get("observation_ids", ()) or ():
            conn.execute(
                "INSERT OR IGNORE INTO snapshot_observation (snapshot_id, observation_id) "
                "VALUES (?, ?)",
                (snap, int(observation_id)),
            )
        self._maybe_commit()
        return snap

    def finalize_snapshot(self, snapshot_id) -> None:
        """Draft -> finalized, with the identity digest RECOMPUTED first.

        The federated observation-set digest is derived from the linked
        provider observations (when any are linked) and the revision digest
        is recomputed from the frozen identity fields, so a finalized
        snapshot's digest is self-enforcing; the integrity gate re-verifies
        it on read.
        """
        conn = self._require_conn()
        row = conn.execute("SELECT * FROM snapshot WHERE id=?", (int(snapshot_id),)).fetchone()
        if row is None:
            raise SnapshotError(f"snapshot {snapshot_id} not found")
        if row["state"] == "finalized":
            raise SnapshotError(f"snapshot {snapshot_id} is already finalized")
        linked = conn.execute(
            "SELECT o.observation_digest FROM snapshot_observation so "
            "JOIN provider_observation o ON o.id = so.observation_id "
            "WHERE so.snapshot_id=?",
            (int(snapshot_id),),
        ).fetchall()
        obs_digest = str(row["observation_set_digest"] or "")
        if linked:
            obs_digest = observation_set_digest([r["observation_digest"] for r in linked])
        expected = identity_revision_digest({
            "repo_identity": row["repo_identity"],
            "source_revision": row["source_revision"],
            "tree_digest": row["tree_digest"],
            "semantic_configuration": row["semantic_configuration"],
            "provider_set_digest": row["provider_set_digest"],
            "observation_set_digest": obs_digest,
        })
        conn.execute(
            "UPDATE snapshot SET observation_set_digest=?, revision_digest=?, "
            "state='finalized', finalized_utc=? WHERE id=? AND state='draft'",
            (obs_digest, expected, _utc_now(), int(snapshot_id)),
        )
        self._maybe_commit()

    def verify_snapshot_digest(self, snapshot_id) -> bool:
        """True when a snapshot's stored revision digest matches its fields."""
        conn = self._require_conn()
        row = conn.execute("SELECT * FROM snapshot WHERE id=?", (int(snapshot_id),)).fetchone()
        if row is None:
            raise SnapshotError(f"snapshot {snapshot_id} not found")
        expected = identity_revision_digest({
            "repo_identity": row["repo_identity"],
            "source_revision": row["source_revision"],
            "tree_digest": row["tree_digest"],
            "semantic_configuration": row["semantic_configuration"],
            "provider_set_digest": row["provider_set_digest"],
            "observation_set_digest": row["observation_set_digest"],
        })
        return str(row["revision_digest"]) == expected

    def abort_draft(self, snapshot_id) -> None:
        """Delete every row of a draft snapshot in one transaction."""
        conn = self._require_conn()
        row = conn.execute("SELECT state FROM snapshot WHERE id=?", (int(snapshot_id),)).fetchone()
        if row is None:
            return
        if row["state"] == "finalized":
            raise SnapshotError(f"snapshot {snapshot_id} is finalized and cannot be aborted")
        snap = int(snapshot_id)
        conn.execute("DELETE FROM snapshot_observation WHERE snapshot_id=?", (snap,))
        for table in (
            "support", "unresolved_edge", "relation", "evidence", "fact",
            "provider_record", "invariant", "contract", "incident", "change",
            "entity",
        ):
            conn.execute(f"DELETE FROM {table} WHERE snapshot_id=?", (snap,))
        conn.execute("DELETE FROM snapshot WHERE id=?", (snap,))
        if self._snapshot_id == snap:
            self._snapshot_id = None
        self._maybe_commit()

    def ensure_snapshot(self, repo_root, commit_sha):
        """Legacy helper: create/reuse a DRAFT snapshot for (repo_root, commit_sha).

        Kept for interface compatibility (protocol projection tests and older
        callers).  New code should use :meth:`begin_draft` with a full
        identity and :meth:`finalize_snapshot`.
        """
        root = str(Path(repo_root).resolve())
        repo_identity = hashlib.sha256(f"legacy-root:{root}".encode("utf-8")).hexdigest()
        identity = {
            "repo_identity": repo_identity,
            "source_revision": str(commit_sha),
            "tree_digest": hashlib.sha256(f"legacy:{root}:{commit_sha}".encode("utf-8")).hexdigest(),
            "semantic_configuration": "{}",
            "provider_set_digest": "",
            "repo_root": root,
        }
        existing = self.snapshot_for(identity)
        if existing is not None:
            if existing["state"] == "finalized":
                raise SnapshotError(
                    f"legacy snapshot for {root}@{commit_sha} already finalized"
                )
            snap = int(existing["id"])
        else:
            snap = self.begin_draft(identity)
        self._snapshot_id = snap
        return snap

    def _snapshot_row(self, snapshot_id):
        row = self._require_conn().execute(
            "SELECT * FROM snapshot WHERE id=?", (int(snapshot_id),)
        ).fetchone()
        if row is None:
            raise SnapshotError(f"snapshot {snapshot_id} not found")
        return self._snapshot_dict(row)

    def _resolve_read_snapshot(self, snapshot_id=None):
        """Resolve exactly one snapshot for reads: explicit id or latest finalized."""
        if snapshot_id is not None:
            return self._snapshot_row(snapshot_id)
        row = self.latest_finalized_snapshot()
        if row is None:
            raise SnapshotError(
                "no finalized snapshot in this database; run scan first"
            )
        return row

    def _resolve_snapshot(self, snapshot_id=None):
        """Resolve a snapshot id for writes (explicit, pinned legacy, or latest finalized)."""
        if snapshot_id is not None:
            return int(self._snapshot_row(snapshot_id)["id"])
        if self._snapshot_id is not None:
            return int(self._snapshot_id)
        row = self.latest_finalized_snapshot()
        if row is None:
            raise SnapshotError("no snapshot: begin a draft or scan first")
        return int(row["id"])

    def _optional_snapshot(self, snapshot_id=None):
        if snapshot_id is not None:
            return int(snapshot_id)
        if self._snapshot_id is not None:
            return int(self._snapshot_id)
        row = self.latest_finalized_snapshot()
        return int(row["id"]) if row else None

    # -------------------------------------------------------------- upserts

    def upsert_entity(self, kind, name, stable_id=None, *, qualified_name=None,
                      snapshot_id=None, file=None, line=None, tier=0,
                      provenance="observed", confidence=1.0, derived_from=(),
                      last_verified=None, uncertainty=None, attrs=None,
                      epistemic_state=None, analysis_depth=None,
                      completeness=None, provider=None, provider_revision=None):
        conn = self._require_conn()
        snap = self._resolve_snapshot(snapshot_id)
        if stable_id in (None, ""):
            if qualified_name is None:
                qualified_name = name
            stable_id = derive_stable_id(kind, qualified_name)
        if qualified_name is None:
            qualified_name = stable_id
        state, depth = _derive_epistemics(provenance, epistemic_state, analysis_depth)
        conn.execute(
            """
            INSERT INTO entity (snapshot_id, kind, name, qualified_name, file, line,
                                tier, provenance, confidence, derived_from,
                                last_verified, uncertainty, stale, attrs, stable_id,
                                epistemic_state, analysis_depth, completeness,
                                provider, provider_revision)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (snapshot_id, stable_id) DO UPDATE SET
                kind=excluded.kind, name=excluded.name,
                qualified_name=excluded.qualified_name, file=excluded.file,
                line=excluded.line, tier=excluded.tier,
                provenance=excluded.provenance, confidence=excluded.confidence,
                derived_from=excluded.derived_from, last_verified=excluded.last_verified,
                uncertainty=excluded.uncertainty, attrs=excluded.attrs, stale=0,
                epistemic_state=excluded.epistemic_state,
                analysis_depth=excluded.analysis_depth,
                completeness=excluded.completeness, provider=excluded.provider,
                provider_revision=excluded.provider_revision
            """,
            (snap, str(kind), str(name), str(qualified_name), file, line, int(tier),
             str(provenance), float(confidence), _dumps(list(derived_from)),
             last_verified, uncertainty, _dumps(dict(attrs or {})), str(stable_id),
             state, depth, str(completeness or "partial"), str(provider or ""),
             str(provider_revision or "")),
        )
        row = conn.execute(
            "SELECT id FROM entity WHERE snapshot_id=? AND stable_id=?",
            (snap, str(stable_id)),
        ).fetchone()
        self._maybe_commit()
        return int(row["id"])

    def upsert_relation(self, src_id, dst_id, kind, *, snapshot_id=None, tier=0,
                        provenance="inferred", confidence=1.0, derived_from=(),
                        last_verified=None, uncertainty=None, attrs=None,
                        src_key=None, dst_key=None, resolved=None,
                        epistemic_state=None, analysis_depth=None,
                        completeness=None, site_completeness=None,
                        target_resolution_completeness=None,
                        provider=None, provider_revision=None):
        conn = self._require_conn()
        src = conn.execute(
            "SELECT snapshot_id, stable_id FROM entity WHERE id=?", (int(src_id),)
        ).fetchone()
        if src is None:
            raise KeyError(f"entity {src_id} not found")
        snap = int(snapshot_id) if snapshot_id is not None else int(src["snapshot_id"])
        if src_key in (None, ""):
            src_key = src["stable_id"]
        if dst_id is None:
            resolved = 0
            dst_id = None
            d_key = str(dst_key or "")
        else:
            dst = conn.execute(
                "SELECT stable_id FROM entity WHERE id=?", (int(dst_id),)
            ).fetchone()
            if dst is None:
                raise KeyError(f"entity {dst_id} not found")
            resolved = 1
            d_key = str(dst_key or dst["stable_id"])
        state, depth = _derive_epistemics(provenance, epistemic_state, analysis_depth)
        if dst_id is None:
            row = conn.execute(
                "SELECT id FROM relation WHERE snapshot_id=? AND src_id=? AND dst_id IS NULL "
                "AND src_key=? AND dst_key=? AND kind=?",
                (snap, int(src_id), str(src_key), d_key, str(kind)),
            ).fetchone()
        else:
            row = conn.execute(
                "SELECT id FROM relation WHERE snapshot_id=? AND src_id=? AND dst_id=? AND kind=?",
                (snap, int(src_id), int(dst_id), str(kind)),
            ).fetchone()
        if row is not None:
            conn.execute(
                """UPDATE relation SET tier=?, provenance=?, confidence=?, derived_from=?,
                   last_verified=?, uncertainty=?, attrs=?, stale=0, resolved=?,
                   epistemic_state=?, analysis_depth=?, completeness=?,
                   site_completeness=?, target_resolution_completeness=?,
                   provider=?, provider_revision=?
                   WHERE id=?""",
                (int(tier), str(provenance), float(confidence),
                 _dumps(list(derived_from)), last_verified, uncertainty,
                 _dumps(dict(attrs or {})), int(resolved), state, depth,
                 str(completeness or "partial"),
                 str(site_completeness or "unknown"),
                 str(target_resolution_completeness or "unknown"),
                 str(provider or ""), str(provider_revision or ""), int(row["id"])),
            )
            rel_id = int(row["id"])
        else:
            cur = conn.execute(
                """
                INSERT INTO relation (snapshot_id, src_id, dst_id, kind, tier, provenance,
                                      confidence, derived_from, last_verified, uncertainty,
                                      stale, attrs, src_key, dst_key, resolved,
                                      epistemic_state, analysis_depth, completeness,
                                      site_completeness, target_resolution_completeness,
                                      provider, provider_revision)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (snap, int(src_id), dst_id, str(kind), int(tier), str(provenance),
                 float(confidence), _dumps(list(derived_from)), last_verified,
                 uncertainty, _dumps(dict(attrs or {})), str(src_key), d_key,
                 int(resolved), state, depth, str(completeness or "partial"),
                 str(site_completeness or "unknown"),
                 str(target_resolution_completeness or "unknown"),
                 str(provider or ""), str(provider_revision or "")),
            )
            rel_id = int(cur.lastrowid)
        self._maybe_commit()
        return rel_id

    def upsert_fact(self, subject, predicate, object, *, snapshot_id=None, tier=0,
                    provenance="observed", confidence=1.0, derived_from=(),
                    last_verified=None, uncertainty=None, epistemic_state=None,
                    analysis_depth=None, completeness=None, provider=None,
                    provider_revision=None, stable_subject=None):
        conn = self._require_conn()
        snap = self._resolve_snapshot(snapshot_id)
        state, depth = _derive_epistemics(provenance, epistemic_state, analysis_depth)
        stable_subject_text = str(stable_subject if stable_subject is not None else subject)
        fact_stable = fact_stable_id(stable_subject_text, str(predicate), str(object))
        conn.execute(
            """
            INSERT INTO fact (snapshot_id, subject, predicate, object, tier, provenance,
                              confidence, derived_from, last_verified, uncertainty, stale,
                              epistemic_state, analysis_depth, completeness, provider,
                              provider_revision, stable_subject, stable_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (snapshot_id, subject, predicate, object) DO UPDATE SET
                tier=excluded.tier, provenance=excluded.provenance,
                confidence=excluded.confidence, derived_from=excluded.derived_from,
                last_verified=excluded.last_verified, uncertainty=excluded.uncertainty,
                stale=0, epistemic_state=excluded.epistemic_state,
                analysis_depth=excluded.analysis_depth,
                completeness=excluded.completeness, provider=excluded.provider,
                provider_revision=excluded.provider_revision,
                stable_subject=excluded.stable_subject,
                stable_id=excluded.stable_id
            """,
            (snap, str(subject), str(predicate), str(object), int(tier),
             str(provenance), float(confidence), _dumps(list(derived_from)),
             last_verified, uncertainty, state, depth,
             str(completeness or "partial"), str(provider or ""),
             str(provider_revision or ""),
             stable_subject_text, fact_stable),
        )
        row = conn.execute(
            "SELECT id FROM fact WHERE snapshot_id=? AND subject=? AND predicate=? AND object=?",
            (snap, str(subject), str(predicate), str(object)),
        ).fetchone()
        self._maybe_commit()
        return int(row["id"])

    # ------------------------------------------- unresolved / support / provider

    def add_unresolved_edge(self, snapshot_id, src_key, dst_raw, kind, *,
                            provider, provider_revision="", candidates=(),
                            confidence=0.3, completeness="unknown",
                            resolution_completeness=None, evidence=()) -> int:
        conn = self._require_conn()
        snap = self._resolve_snapshot(snapshot_id)
        cur = conn.execute(
            """
            INSERT INTO unresolved_edge (snapshot_id, src_key, dst_raw, kind, provider,
                                         provider_revision, candidates, confidence,
                                         completeness, resolution_completeness,
                                         evidence, created_utc)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (snap, str(src_key), str(dst_raw), str(kind), str(provider),
             str(provider_revision or ""), _dumps(list(candidates)),
             float(confidence), str(completeness),
             str(resolution_completeness or completeness),
             _dumps(list(evidence)), _utc_now()),
        )
        self._maybe_commit()
        return int(cur.lastrowid)

    def unresolved_edges(self, snapshot_id=None, kind=None):
        conn = self._require_conn()
        snap = self._resolve_snapshot(snapshot_id)
        sql = "SELECT * FROM unresolved_edge WHERE snapshot_id=?"
        params = [snap]
        if kind is not None:
            sql += " AND kind=?"
            params.append(str(kind))
        sql += " ORDER BY id"
        out = []
        for row in conn.execute(sql, params).fetchall():
            item = {k: row[k] for k in row.keys()}
            item["candidates"] = _loads(item.get("candidates"), [])
            item["evidence"] = _loads(item.get("evidence"), [])
            out.append(item)
        return out

    def accumulate_support(self, snapshot_id, subject_table, subject_id, *,
                           provider, provider_revision="", confidence=1.0,
                           evidence_id=None, detail=None,
                           observation_id=None) -> int:
        """Accumulate ONE provider observation's support for a canonical row.

        ``observation_id`` (level-2 provider_observation) pins WHICH
        observation supplied the claim; it must be linked to the same
        snapshot (enforced by a trigger).  Two distinct observations by the
        same provider therefore stay distinguishable.
        """
        conn = self._require_conn()
        snap = self._resolve_snapshot(snapshot_id)
        if evidence_id is None:
            row = conn.execute(
                "SELECT id FROM support WHERE snapshot_id=? AND subject_table=? "
                "AND subject_id=? AND provider=? AND observation_id IS NULL "
                "AND evidence_id IS NULL",
                (snap, str(subject_table), int(subject_id), str(provider)),
            ).fetchone()
        else:
            row = conn.execute(
                "SELECT id FROM support WHERE snapshot_id=? AND subject_table=? "
                "AND subject_id=? AND provider=? AND observation_id IS NULL "
                "AND evidence_id=?",
                (snap, str(subject_table), int(subject_id), str(provider), int(evidence_id)),
            ).fetchone()
        if observation_id is not None:
            row = conn.execute(
                "SELECT id FROM support WHERE snapshot_id=? AND subject_table=? "
                "AND subject_id=? AND provider=? AND observation_id=?",
                (snap, str(subject_table), int(subject_id), str(provider),
                 int(observation_id)),
            ).fetchone()
        if row is not None:
            conn.execute(
                "UPDATE support SET provider_revision=?, confidence=?, evidence_id=?, "
                "detail=?, observed_utc=? WHERE id=?",
                (str(provider_revision or ""), float(confidence),
                 int(evidence_id) if evidence_id is not None else None,
                 detail, _utc_now(), int(row["id"])),
            )
            sup_id = int(row["id"])
        else:
            cur = conn.execute(
                """INSERT INTO support (snapshot_id, subject_table, subject_id, provider,
                   provider_revision, confidence, evidence_id, observation_id, detail,
                   observed_utc)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (snap, str(subject_table), int(subject_id), str(provider),
                 str(provider_revision or ""), float(confidence),
                 int(evidence_id) if evidence_id is not None else None,
                 int(observation_id) if observation_id is not None else None,
                 detail, _utc_now()),
            )
            sup_id = int(cur.lastrowid)
        self._maybe_commit()
        return sup_id

    def record_provider(self, snapshot_id, provider, provider_version,
                        capabilities: dict, invoked=True, scope=None,
                        authority="fallback") -> int:
        conn = self._require_conn()
        snap = self._resolve_snapshot(snapshot_id)
        caps = capabilities if isinstance(capabilities, dict) else {}
        conn.execute(
            """INSERT INTO provider_record (snapshot_id, provider, provider_version,
               capabilities, invoked, scope, authority)
               VALUES (?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT (snapshot_id, provider) DO UPDATE SET
                   provider_version=excluded.provider_version,
                   capabilities=excluded.capabilities, invoked=excluded.invoked,
                   scope=excluded.scope, authority=excluded.authority""",
            (snap, str(provider), str(provider_version), _dumps(dict(caps)),
             1 if invoked else 0,
             _dumps(scope if isinstance(scope, dict) else {}),
             str(authority or "fallback")),
        )
        row = conn.execute(
            "SELECT id FROM provider_record WHERE snapshot_id=? AND provider=?",
            (snap, str(provider)),
        ).fetchone()
        self._maybe_commit()
        return int(row["id"])

    def add_evidence(self, snapshot_id, kind, ref, *, digest=None, summary="",
                     payload=None, provider="") -> int:
        conn = self._require_conn()
        snap = self._resolve_snapshot(snapshot_id)
        cur = conn.execute(
            """INSERT INTO evidence (snapshot_id, kind, ref, digest, summary, payload,
               provider, created_utc) VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (snap, str(kind), str(ref), digest, str(summary),
             _dumps(payload) if payload is not None else None,
             str(provider or ""), _utc_now()),
        )
        self._maybe_commit()
        return int(cur.lastrowid)

    # ------------------------------------------------- documents (v1 helpers)

    def add_invariant(self, statement, component_qn=None, *, snapshot_id=None, tier=0,
                      provenance="declared", confidence=1.0, derived_from=(),
                      last_verified=None, uncertainty=None):
        conn = self._require_conn()
        snap = self._resolve_snapshot(snapshot_id)
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
        self._maybe_commit()
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
        self._maybe_commit()
        return int(row["id"])

    def add_incident(self, summary, component_qn=None, occurred_utc=None,
                     severity=None, *, snapshot_id=None, tier=0,
                     provenance="historically_supported", confidence=1.0,
                     derived_from=(), last_verified=None, uncertainty=None,
                     attrs=None):
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
        self._maybe_commit()
        return int(cur.lastrowid)

    def add_change(self, commit_sha, summary, files=(), outcome=None, *,
                   snapshot_id=None, tier=0, provenance="historically_supported",
                   confidence=1.0, derived_from=(), last_verified=None,
                   uncertainty=None, attrs=None):
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
        self._maybe_commit()
        return int(cur.lastrowid)

    # ------------------------------------------------- legacy staleness (draft)

    def mark_entity_stale(self, entity_id):
        """Deprecated: v2 has no in-place staleness.  Draft snapshots only."""
        conn = self._require_conn()
        cur = conn.execute("UPDATE entity SET stale=1 WHERE id=?", (int(entity_id),))
        if cur.rowcount == 0:
            raise KeyError(f"entity {entity_id} not found")
        self._maybe_commit()

    def mark_entity_fresh(self, entity_id):
        """Deprecated: v2 has no in-place staleness.  Draft snapshots only."""
        conn = self._require_conn()
        cur = conn.execute("UPDATE entity SET stale=0 WHERE id=?", (int(entity_id),))
        if cur.rowcount == 0:
            raise KeyError(f"entity {entity_id} not found")
        self._maybe_commit()

    def stale_sweep(self, snapshot_id, seen_by_kind):
        """DEPRECATED: draft-only compatibility helper.

        Finalized snapshots are immutable and never go stale; removal is
        represented by a newer snapshot and reported by
        :meth:`diff_snapshots`.  This helper exists purely so legacy callers
        can mark draft rows and raises :class:`SnapshotError` for finalized
        snapshots.  Do not use it in the operating model.
        """
        conn = self._require_conn()
        snap = int(snapshot_id)
        row = conn.execute("SELECT state FROM snapshot WHERE id=?", (snap,)).fetchone()
        if row is None:
            raise SnapshotError(f"snapshot {snap} not found")
        if row["state"] != "draft":
            raise SnapshotError("stale_sweep is draft-only; finalized snapshots are immutable")
        before = conn.execute(
            "SELECT COUNT(*) AS n FROM entity WHERE snapshot_id=? AND stale=1", (snap,)
        ).fetchone()["n"]
        for kind, seen in dict(seen_by_kind).items():
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
        self._maybe_commit()
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

    def resolve_qn(self, qualified_name, include_stale=True, snapshot_id=None,
                   kind=None, stable_id=None):
        """Typed resolution helper used by CLI/protocol callers.

        With ``stable_id`` the typed (kind, stable_id) key is matched exactly;
        otherwise exact qualified-name match first, then the UNIQUE entity
        whose qualified name ends with ``::<qualified_name>``.  Ambiguity
        resolves to None rather than guessing.
        """
        conn = self._require_conn()
        snap = self._optional_snapshot(snapshot_id)
        if snap is None:
            return None
        if stable_id is not None:
            if kind is not None:
                row = conn.execute(
                    "SELECT * FROM entity WHERE snapshot_id=? AND kind=? AND stable_id=?",
                    (snap, kind, stable_id),
                ).fetchone()
            else:
                rows = conn.execute(
                    "SELECT * FROM entity WHERE snapshot_id=? AND stable_id=? ORDER BY id",
                    (snap, stable_id),
                ).fetchall()
                row = rows[0] if len(rows) == 1 else None
            return _parse_entity({k: row[k] for k in row.keys()}) if row is not None else None
        hit = self.find_entity_by_qn(qualified_name, include_stale, snapshot_id)
        if hit is not None and (kind is None or hit["kind"] == kind):
            return hit
        clause = "" if include_stale else " AND stale=0"
        kind_clause = " AND kind=?" if kind is not None else ""
        escaped = (
            qualified_name.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        )
        params = [snap, qualified_name, "%::" + escaped]
        if kind is not None:
            params.append(kind)
        rows = conn.execute(
            f"SELECT * FROM entity WHERE snapshot_id=?{clause} "
            f"AND (qualified_name=? OR qualified_name LIKE ? ESCAPE '\\'){kind_clause} ORDER BY id",
            params,
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

    def edges_by_type(self, kind, include_stale=False, snapshot_id=None):
        conn = self._require_conn()
        snap = self._resolve_snapshot(snapshot_id)
        sql = (
            f"SELECT {_select('r', _RELATION_COLUMNS)}, {_select('s', _ENTITY_COLUMNS)}, "
            f"{_select('d', _ENTITY_COLUMNS)} "
            f"FROM relation r JOIN entity s ON s.id=r.src_id "
            f"LEFT JOIN entity d ON d.id=r.dst_id "
            f"WHERE r.snapshot_id=? AND r.kind=?"
        )
        if not include_stale:
            sql += " AND r.stale=0 AND s.stale=0"
        sql += " ORDER BY r.id"
        out = []
        for row in conn.execute(sql, (snap, kind)).fetchall():
            rel = _parse_relation({c: row[f"r_{c}"] for c in _RELATION_COLUMNS})
            rel["src"] = _parse_entity({c: row[f"s_{c}"] for c in _ENTITY_COLUMNS})
            rel["dst"] = (_parse_entity({c: row[f"d_{c}"] for c in _ENTITY_COLUMNS})
                          if row["d_id"] is not None else None)
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
            "SELECT src_id, dst_id, kind FROM relation WHERE snapshot_id=? AND stale=0 "
            "AND dst_id IS NOT NULL",
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
            f"AND dst_id IS NOT NULL AND kind IN ({placeholders})",
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
            # P0-6: ONLY entities whose kind is Test may source a `tests` edge.
            tests_rows = conn.execute(
                f"SELECT DISTINCT r.src_id FROM relation r "
                f"JOIN entity s ON s.id=r.src_id AND s.snapshot_id=r.snapshot_id "
                f"WHERE r.snapshot_id=? AND r.kind='tests' AND r.stale=0 "
                f"AND s.kind=? AND r.dst_id IN ({placeholders})",
                (snap, TEST_SOURCE_KIND, *chunk),
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
            "completeness": self.completeness(snap),
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
        fuzzy = []
        unmatched = []
        seed_ids = []
        for qn in qualified_names:
            exact = [e for e in everything if e["qualified_name"] == qn]
            if exact:
                hits = exact
            else:
                # Namespace-boundary-aware suffix fallback.  A textual
                # resemblance is FUZZY evidence, reported as such and never
                # silently promoted to an exact impact seed.
                suffix = "::" + qn
                dotted = "." + qn
                hits = [
                    e for e in everything
                    if e["qualified_name"].endswith(suffix)
                    or e["qualified_name"].endswith(dotted)
                ]
                if hits:
                    fuzzy.append(qn)
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
            "fuzzy": fuzzy,
            "unmatched": unmatched,
            "impacted": impacted,
            "contracts": sorted(contracts.values(), key=lambda c: c["id"]),
            "invariants": sorted(invariants.values(), key=lambda i: i["id"]),
            "tests": sorted(tests.values(), key=lambda t: t["qualified_name"]),
            "incidents": sorted(incidents.values(), key=lambda i: i["id"]),
            "likely_regression_surfaces": likely,
            "completeness": self.completeness(snap),
        }

    # ---------------------------------------------------------- completeness

    def completeness(self, snapshot_id=None, family=None):
        """Completeness verdicts for exactly one snapshot (§0/§3).

        Families come from provider capability records, augmented by data
        actually stored; unresolved edges cap the ``relations`` verdict at
        ``partial`` and are always surfaced explicitly.
        """
        conn = self._require_conn()
        row = self._resolve_read_snapshot(snapshot_id)
        snap = int(row["id"])

        providers = {}
        families = {}
        for prow in conn.execute(
            "SELECT provider, capabilities FROM provider_record WHERE snapshot_id=? ORDER BY provider",
            (snap,),
        ).fetchall():
            caps = _loads(prow["capabilities"], {})
            providers[prow["provider"]] = caps
            for fam, verdict in caps.items():
                families[fam] = _worst_verdict(families.get(fam, "complete"), verdict)

        def _count(sql, params=()):
            return int(conn.execute(sql, params).fetchone()["n"])

        entities = _count("SELECT COUNT(*) AS n FROM entity WHERE snapshot_id=?", (snap,))
        relations_resolved = _count(
            "SELECT COUNT(*) AS n FROM relation WHERE snapshot_id=? AND dst_id IS NOT NULL", (snap,)
        )
        relations_unresolved = _count(
            "SELECT COUNT(*) AS n FROM relation WHERE snapshot_id=? AND dst_id IS NULL", (snap,)
        )
        unresolved_edges = _count(
            "SELECT COUNT(*) AS n FROM unresolved_edge WHERE snapshot_id=?", (snap,)
        )
        facts = _count("SELECT COUNT(*) AS n FROM fact WHERE snapshot_id=?", (snap,))
        tests = _count("SELECT COUNT(*) AS n FROM entity WHERE snapshot_id=? AND kind='Test'", (snap,))

        # PRESENCE PROVES EXISTENCE, NEVER COMPLETENESS.  A family verdict
        # is only ``complete`` when an authoritative producer ASSERTED it
        # (a provider capability record under its scope); rows in storage
        # alone yield at most ``partial``.  Discovering 19 of 20 functions
        # cannot be distinguished from having found them all, and the
        # absence of an unresolved row does not prove closed-world
        # enumeration.
        if "entities" not in families:
            families["entities"] = "partial" if entities else "unknown"
        if "relations" not in families:
            # unresolved claims are observed relations the resolver could
            # not bind: presence (resolved OR unresolved) yields at most
            # partial, never complete
            families["relations"] = (
                "partial"
                if (relations_resolved or relations_unresolved or unresolved_edges)
                else "unknown"
            )
        if "facts" not in families:
            families["facts"] = "partial" if facts else "unknown"
        if "tests" not in families and tests:
            families["tests"] = "partial"
        if relations_unresolved or unresolved_edges:
            families["relations"] = _worst_verdict(families.get("relations", "unknown"), "partial")

        sample = [
            {"src_key": u["src_key"], "dst_raw": u["dst_raw"], "kind": u["kind"]}
            for u in conn.execute(
                "SELECT src_key, dst_raw, kind FROM unresolved_edge WHERE snapshot_id=? ORDER BY id LIMIT 10",
                (snap,),
            ).fetchall()
        ]

        # Provider scope/authority and the SEPARATED enumeration vs
        # resolution completeness axes (P1 completeness algebra): one scalar
        # cannot combine providers whose scopes differ.
        provider_scopes = {}
        for orow in conn.execute(
            """SELECT o.provider, o.provider_version, o.observation_kind,
                      o.observation_digest, o.scope, o.authority,
                      o.enumeration_completeness, o.resolution_completeness
               FROM snapshot_observation so
               JOIN provider_observation o ON o.id = so.observation_id
               WHERE so.snapshot_id=?
               ORDER BY o.provider, o.observation_kind""",
            (snap,),
        ).fetchall():
            entry = provider_scopes.setdefault(orow["provider"], {
                "provider_version": orow["provider_version"],
                "observations": [],
            })
            entry["observations"].append({
                "observation_kind": orow["observation_kind"],
                "observation_digest": orow["observation_digest"],
                "scope": _loads(orow["scope"], {}),
                "authority": orow["authority"],
                "enumeration_completeness": orow["enumeration_completeness"],
                "resolution_completeness": orow["resolution_completeness"],
            })

        # Relation completeness keeps the two axes apart: all sites may be
        # enumerated while some indirect targets stay unknown.
        site_rows = {}
        for rrow in conn.execute(
            "SELECT site_completeness, COUNT(*) AS n FROM relation "
            "WHERE snapshot_id=? GROUP BY site_completeness ORDER BY site_completeness",
            (snap,),
        ).fetchall():
            site_rows[str(rrow["site_completeness"])] = int(rrow["n"])
        target_rows = {}
        for rrow in conn.execute(
            "SELECT target_resolution_completeness, COUNT(*) AS n FROM relation "
            "WHERE snapshot_id=? GROUP BY target_resolution_completeness "
            "ORDER BY target_resolution_completeness",
            (snap,),
        ).fetchall():
            target_rows[str(rrow["target_resolution_completeness"])] = int(rrow["n"])
        site_verdict = "unknown"
        if site_rows:
            site_verdict = _worst_verdict(*site_rows.keys())
        target_verdict = "unknown"
        if target_rows:
            target_verdict = _worst_verdict(*target_rows.keys())
        if relations_unresolved or unresolved_edges:
            target_verdict = _worst_verdict(target_verdict, "partial")

        filtered = ({family: families.get(family, "unknown")} if family is not None
                    else dict(sorted(families.items())))
        return {
            "snapshot": row["revision_digest"],
            "snapshot_id": snap,
            "state": row["state"],
            "families": filtered,
            "providers": providers,
            "provider_scopes": provider_scopes,
            "relations_completeness": {
                "site": site_verdict,
                "target_resolution": target_verdict,
                "site_rows": site_rows,
                "target_resolution_rows": target_rows,
            },
            "unresolved": {
                "count": unresolved_edges,
                "relation_rows": relations_unresolved,
                "sample": sample,
            },
            "counts": {
                "entities": entities,
                "relations": relations_resolved,
                "unresolved_relations": relations_unresolved,
                "unresolved_edges": unresolved_edges,
                "facts": facts,
                "tests": tests,
            },
        }

    # ---------------------------------------------------------------- diff

    def _entity_map(self, snapshot_id):
        conn = self._require_conn()
        out = {}
        for row in conn.execute(
            "SELECT * FROM entity WHERE snapshot_id=? ORDER BY id", (int(snapshot_id),)
        ).fetchall():
            ent = _parse_entity({k: row[k] for k in row.keys()})
            signature = _dumps({
                k: ent.get(k) for k in (
                    "kind", "name", "qualified_name", "file", "line", "tier",
                    "provenance", "confidence", "derived_from", "attrs",
                    "epistemic_state", "analysis_depth", "completeness",
                    "provider", "provider_revision",
                )
            })
            out[ent["stable_id"]] = signature
        return out

    def _relation_map(self, snapshot_id):
        conn = self._require_conn()
        out = {}
        rows = conn.execute(
            f"""SELECT r.*, s.stable_id AS src_stable, d.stable_id AS dst_stable
                FROM relation r
                JOIN entity s ON s.id=r.src_id AND s.snapshot_id=r.snapshot_id
                LEFT JOIN entity d ON d.id=r.dst_id
                WHERE r.snapshot_id=? ORDER BY r.id""",
            (int(snapshot_id),),
        ).fetchall()
        for row in rows:
            rel = _parse_relation({c: row[c] for c in _RELATION_COLUMNS})
            src_key = rel["src_key"] or row["src_stable"] or ""
            dst_key = rel["dst_key"] or (row["dst_stable"] or "")
            key = _structured_key(src_key, dst_key, rel["kind"])
            out[key] = _dumps({
                k: rel.get(k) for k in (
                    "resolved", "tier", "provenance", "confidence", "derived_from",
                    "attrs", "epistemic_state", "analysis_depth", "completeness",
                    "site_completeness", "target_resolution_completeness",
                    "provider", "provider_revision",
                )
            })
        return out

    def _fact_map(self, snapshot_id):
        conn = self._require_conn()
        out = {}
        for row in conn.execute(
            """SELECT * FROM fact WHERE snapshot_id=? ORDER BY id""", (int(snapshot_id),)
        ).fetchall():
            item = _parse_common({k: row[k] for k in row.keys()})
            key = _structured_key(item["subject"], item["predicate"], item["object"])
            out[key] = _dumps({
                k: item.get(k) for k in (
                    "tier", "provenance", "confidence", "derived_from", "uncertainty",
                    "epistemic_state", "analysis_depth", "completeness", "provider",
                    "provider_revision", "stable_subject",
                )
            })
        return out

    def _unresolved_map(self, snapshot_id):
        conn = self._require_conn()
        out = {}
        for row in conn.execute(
            "SELECT * FROM unresolved_edge WHERE snapshot_id=? ORDER BY id", (int(snapshot_id),)
        ).fetchall():
            key = _structured_key(row["src_key"], row["dst_raw"], row["kind"])
            out[key] = _dumps({
                "candidates": _loads(row["candidates"], []),
                "confidence": row["confidence"],
                "completeness": row["completeness"],
                "provider": row["provider"],
                "provider_revision": row["provider_revision"],
            })
        return out

    @staticmethod
    def _diff_maps(old_map, new_map):
        added = sorted(set(new_map) - set(old_map))
        removed = sorted(set(old_map) - set(new_map))
        changed = sorted(k for k in set(old_map) & set(new_map) if old_map[k] != new_map[k])
        return added, removed, changed

    def diff_snapshots(self, old_id, new_id) -> dict:
        """Structural delta between two snapshots (no mutation of either)."""
        old = self._snapshot_row(old_id)
        new = self._snapshot_row(new_id)
        e_add, e_rm, e_ch = self._diff_maps(self._entity_map(old["id"]), self._entity_map(new["id"]))
        r_add, r_rm, r_ch = self._diff_maps(self._relation_map(old["id"]), self._relation_map(new["id"]))
        f_add, f_rm, f_ch = self._diff_maps(self._fact_map(old["id"]), self._fact_map(new["id"]))
        u_add, u_rm, u_ch = self._diff_maps(self._unresolved_map(old["id"]), self._unresolved_map(new["id"]))

        old_comp = self.completeness(old["id"])["families"]
        new_comp = self.completeness(new["id"])["families"]
        delta = {}
        for fam in sorted(set(old_comp) | set(new_comp)):
            o = old_comp.get(fam)
            n = new_comp.get(fam)
            delta[fam] = {"old": o, "new": n, "changed": o != n}

        def _unpack(keys):
            # signatures are canonical JSON tuples: semantic identifiers may
            # themselves contain any separator, so no string splitting
            out = []
            for key in keys:
                try:
                    parts = json.loads(key)
                except (TypeError, ValueError):
                    parts = None
                if isinstance(parts, list) and len(parts) == 3:
                    out.append({"src": parts[0], "dst": parts[1], "kind": parts[2]})
                else:
                    out.append({"key": key})
            return out

        def _unpack_facts(keys):
            out = []
            for key in keys:
                try:
                    parts = json.loads(key)
                except (TypeError, ValueError):
                    parts = None
                if isinstance(parts, list) and len(parts) == 3:
                    out.append({"subject": parts[0], "predicate": parts[1],
                                "object": parts[2]})
                else:
                    out.append({"key": key})
            return out

        return {
            "old_snapshot_id": int(old["id"]),
            "new_snapshot_id": int(new["id"]),
            "old_revision_digest": old["revision_digest"],
            "new_revision_digest": new["revision_digest"],
            "added": e_add,
            "removed": e_rm,
            "changed": e_ch,
            "relations_added": _unpack(r_add),
            "relations_removed": _unpack(r_rm),
            "relations_changed": _unpack(r_ch),
            "facts_added": _unpack_facts(f_add),
            "facts_removed": _unpack_facts(f_rm),
            "facts_changed": _unpack_facts(f_ch),
            "unresolved_added": _unpack(u_add),
            "unresolved_removed": _unpack(u_rm),
            "unresolved_changed": _unpack(u_ch),
            "completeness_delta": delta,
        }

    # ------------------------------------------------------------ integrity

    def integrity_report(self, snapshot_id) -> dict:
        """Structural checks: no orphans, same-snapshot FKs, unresolved accounting."""
        conn = self._require_conn()
        snap = int(snapshot_id)
        orphan_src = int(conn.execute(
            "SELECT COUNT(*) AS n FROM relation r LEFT JOIN entity s "
            "ON s.id=r.src_id AND s.snapshot_id=r.snapshot_id "
            "WHERE r.snapshot_id=? AND s.id IS NULL", (snap,)
        ).fetchone()["n"])
        orphan_dst = int(conn.execute(
            "SELECT COUNT(*) AS n FROM relation r LEFT JOIN entity d "
            "ON d.id=r.dst_id AND d.snapshot_id=r.snapshot_id "
            "WHERE r.snapshot_id=? AND r.dst_id IS NOT NULL AND d.id IS NULL", (snap,)
        ).fetchone()["n"])
        unresolved_rows = int(conn.execute(
            "SELECT COUNT(*) AS n FROM relation WHERE snapshot_id=? AND dst_id IS NULL", (snap,)
        ).fetchone()["n"])
        unaccounted = int(conn.execute(
            "SELECT COUNT(*) AS n FROM relation r WHERE r.snapshot_id=? AND r.dst_id IS NULL "
            "AND NOT EXISTS (SELECT 1 FROM unresolved_edge u WHERE u.snapshot_id=r.snapshot_id "
            "AND u.src_key=r.src_key AND u.dst_raw=r.dst_key AND u.kind=r.kind)", (snap,)
        ).fetchone()["n"])
        bad_support = int(conn.execute(
            "SELECT COUNT(*) AS n FROM support s WHERE s.snapshot_id=? AND "
            "(s.evidence_id IS NOT NULL AND NOT EXISTS "
            " (SELECT 1 FROM evidence e WHERE e.id=s.evidence_id AND e.snapshot_id=s.snapshot_id))",
            (snap,),
        ).fetchone()["n"])
        digest_ok = self.verify_snapshot_digest(snap)
        reasons = []
        if orphan_src or orphan_dst:
            reasons.append("cross-snapshot relation endpoints")
        if unaccounted:
            reasons.append("unresolved relations without an unresolved_edge")
        if bad_support:
            reasons.append("support evidence outside the snapshot")
        if not digest_ok:
            reasons.append("revision digest disagrees with the identity fields")
        report = {
            "snapshot_id": snap,
            "orphan_src_relations": orphan_src,
            "orphan_dst_relations": orphan_dst,
            "unresolved_relation_rows": unresolved_rows,
            "unaccounted_unresolved_relations": unaccounted,
            "support_evidence_violations": bad_support,
            "digest_verified": digest_ok,
            "ok": not reasons,
        }
        if not report["ok"]:
            raise SnapshotError(
                f"integrity check failed for snapshot {snap}: {report} ({'; '.join(reasons)})"
            )
        return report

    # ------------------------------------------------------------------ stats

    def stats(self, snapshot_id=None):
        conn = self._require_conn()
        row = self._resolve_read_snapshot(snapshot_id)
        snap = int(row["id"])

        def count(table, extra=""):
            return int(conn.execute(
                f"SELECT COUNT(*) AS n FROM {table} WHERE snapshot_id=?{extra}", (snap,)
            ).fetchone()["n"])

        by_kind = {}
        for r in conn.execute(
            "SELECT kind, COUNT(*) AS n FROM entity WHERE snapshot_id=? GROUP BY kind ORDER BY kind",
            (snap,),
        ).fetchall():
            by_kind[r["kind"]] = int(r["n"])
        relations_by_kind = {}
        for r in conn.execute(
            "SELECT kind, COUNT(*) AS n FROM relation WHERE snapshot_id=? GROUP BY kind ORDER BY kind",
            (snap,),
        ).fetchall():
            relations_by_kind[r["kind"]] = int(r["n"])
        relations_resolved = count("relation", " AND dst_id IS NOT NULL")
        relations_unresolved = count("relation", " AND dst_id IS NULL")
        return {
            "schema_version": SCHEMA_VERSION,
            "snapshot_id": snap,
            "revision_digest": row["revision_digest"],
            "state": row["state"],
            "source_revision_id": row["source_revision_id"],
            "observation_set_digest": row["observation_set_digest"],
            "observations": int(conn.execute(
                "SELECT COUNT(*) AS n FROM snapshot_observation WHERE snapshot_id=?", (snap,)
            ).fetchone()["n"]),
            "snapshots": int(conn.execute("SELECT COUNT(*) AS n FROM snapshot").fetchone()["n"]),
            "entities_by_kind": by_kind,
            "relations_by_kind": relations_by_kind,
            "relations_resolved": relations_resolved,
            "relations_unresolved": relations_unresolved,
            "facts": count("fact"),
            "invariants": count("invariant"),
            "contracts": count("contract"),
            "incidents": count("incident"),
            "changes": count("change"),
            "unresolved_edges": count("unresolved_edge"),
            "support": count("support"),
            "evidence": count("evidence"),
            "providers": count("provider_record"),
            "stale_entities": count("entity", " AND stale=1"),
            "stale_relations": count("relation", " AND stale=1"),
        }

    # --------------------------------------------------------------- export

    def export_json(self, snapshot_id=None):
        """Export exactly ONE snapshot (latest finalized by default).

        Never unions rows across snapshots (P0-1); raises SnapshotError when
        no finalized snapshot exists.
        """
        conn = self._require_conn()
        row = self._resolve_read_snapshot(snapshot_id)
        snap = int(row["id"])

        def query(table, parse=None):
            rows = conn.execute(
                f"SELECT * FROM {table} WHERE snapshot_id=? ORDER BY id", (snap,)
            ).fetchall()
            out = []
            for r in rows:
                item = {k: r[k] for k in r.keys()}
                if parse is not None:
                    item = parse(item)
                out.append(item)
            return out

        def _parse_unresolved(item):
            item = dict(item)
            item["candidates"] = _loads(item.get("candidates"), [])
            item["evidence"] = _loads(item.get("evidence"), [])
            return item

        def _parse_provider(item):
            item = dict(item)
            item["capabilities"] = _loads(item.get("capabilities"), {})
            item["invoked"] = bool(item.get("invoked", 1))
            return item

        snapshot_meta = dict(row)
        return {
            "schema_version": SCHEMA_VERSION,
            "snapshot": snapshot_meta,
            "snapshots": [snapshot_meta],
            "entities": query("entity", _parse_entity),
            "relations": query("relation", _parse_relation),
            "facts": query("fact", _parse_common),
            "invariants": query("invariant", _parse_common),
            "contracts": query("contract", _parse_common),
            "incidents": query("incident", _parse_common),
            "changes": query("change", lambda d: _parse_common(d, list_fields=("derived_from", "files"))),
            "unresolved_edges": query("unresolved_edge", _parse_unresolved),
            "support": query("support", _parse_common,),
            "evidence": query("evidence", lambda d: _parse_common(d, list_fields=("derived_from",), dict_fields=("attrs",))),
            "provider_records": query("provider_record", _parse_provider),
            "observations": self.observations(snap),
        }
