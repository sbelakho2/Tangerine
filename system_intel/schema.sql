-- Tangerine System Intelligence — persistent graph schema (SQLite), v2.
-- Standalone: no consumer-specific concepts live in the core.  Every row is
-- bound to a snapshot; snapshot identity is the revision tuple from
-- INTERFACES.md §1.  Finalized snapshots are IMMUTABLE: BEFORE triggers abort
-- every INSERT/UPDATE/DELETE against the seven core tables while the owning
-- snapshot state is 'finalized' ("nothing inside a finalized snapshot
-- becomes stale"; removed content is represented by newer snapshots and
-- `diff_snapshots`, never by mutating history).
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
INSERT INTO schema_version (version)
  SELECT 2 WHERE NOT EXISTS (SELECT 1 FROM schema_version);

-- One row per scan revision.  repo_root is provenance metadata, never
-- identity; the identity is the UNIQUE tuple below.
CREATE TABLE IF NOT EXISTS snapshot (
  id                    INTEGER PRIMARY KEY AUTOINCREMENT,
  repo_root             TEXT,
  repo_identity         TEXT NOT NULL,
  source_revision       TEXT NOT NULL,
  tree_digest           TEXT NOT NULL,
  semantic_configuration TEXT NOT NULL DEFAULT '{}',
  provider_set_digest   TEXT NOT NULL DEFAULT '',
  revision_digest       TEXT NOT NULL,
  state                 TEXT NOT NULL DEFAULT 'draft' CHECK (state IN ('draft','finalized')),
  created_utc           TEXT,
  finalized_utc         TEXT,
  UNIQUE (repo_identity, source_revision, tree_digest,
          semantic_configuration, provider_set_digest)
);

-- Universal graph entities.  `kind` is open-ended; the documented set is
-- Repository, Project, Package, Module, File, Symbol, Service, Resource,
-- API, Contract, Schema, Event, Queue, Configuration, Deployment, Test,
-- Owner, Invariant, Incident, Change, RuntimePath, DataFlow.  Identity is
-- (snapshot_id, stable_id); qualified_name is display/resolution metadata
-- and is deliberately NOT unique (typed endpoint collisions are resolved by
-- stable_id).
CREATE TABLE IF NOT EXISTS entity (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id    INTEGER NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
  kind           TEXT NOT NULL,
  name           TEXT NOT NULL,
  qualified_name TEXT NOT NULL,
  file           TEXT,
  line           INTEGER,
  tier           INTEGER NOT NULL DEFAULT 0,
  provenance     TEXT NOT NULL DEFAULT 'observed',
  confidence     REAL NOT NULL DEFAULT 1.0,
  derived_from   TEXT NOT NULL DEFAULT '[]',
  last_verified  TEXT,
  uncertainty    TEXT,
  stale          INTEGER NOT NULL DEFAULT 0,
  attrs          TEXT NOT NULL DEFAULT '{}',
  stable_id      TEXT NOT NULL,
  epistemic_state TEXT NOT NULL DEFAULT 'observed',
  analysis_depth INTEGER NOT NULL DEFAULT 0,
  completeness   TEXT NOT NULL DEFAULT 'partial',
  provider       TEXT NOT NULL DEFAULT '',
  provider_revision TEXT NOT NULL DEFAULT '',
  UNIQUE (snapshot_id, stable_id),
  UNIQUE (id, snapshot_id)             -- enables the composite FKs below
);
CREATE INDEX IF NOT EXISTS entity_kind_idx ON entity (snapshot_id, kind);
CREATE INDEX IF NOT EXISTS entity_name_idx ON entity (snapshot_id, name);

-- Universal relationships.  `kind` is open-ended; the documented set is
-- contains, imports, calls, reads, writes, creates, deletes, publishes,
-- subscribes, depends_on, implements, extends, tests, deploys_with, owns,
-- configured_by, constrained_by, compatible_with, breaks_if_changed,
-- flows_to.  Endpoints are resolved by typed (kind, stable_id) keys; an
-- unresolved target keeps a first-class unresolved_edge row plus a relation
-- row with resolved=0 / dst_id NULL.  The composite foreign keys make a
-- cross-snapshot relation structurally impossible.
CREATE TABLE IF NOT EXISTS relation (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id   INTEGER NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
  src_id        INTEGER NOT NULL,
  dst_id        INTEGER,
  kind          TEXT NOT NULL,
  tier          INTEGER NOT NULL DEFAULT 0,
  provenance    TEXT NOT NULL DEFAULT 'inferred',
  confidence    REAL NOT NULL DEFAULT 1.0,
  derived_from  TEXT NOT NULL DEFAULT '[]',
  last_verified TEXT,
  uncertainty   TEXT,
  stale         INTEGER NOT NULL DEFAULT 0,
  attrs         TEXT NOT NULL DEFAULT '{}',
  src_key       TEXT NOT NULL DEFAULT '',
  dst_key       TEXT NOT NULL DEFAULT '',
  resolved      INTEGER NOT NULL DEFAULT 1,
  epistemic_state TEXT NOT NULL DEFAULT 'inferred',
  analysis_depth INTEGER NOT NULL DEFAULT 0,
  completeness  TEXT NOT NULL DEFAULT 'partial',
  provider      TEXT NOT NULL DEFAULT '',
  FOREIGN KEY (src_id, snapshot_id) REFERENCES entity (id, snapshot_id),
  FOREIGN KEY (dst_id, snapshot_id) REFERENCES entity (id, snapshot_id),
  CHECK (dst_id IS NOT NULL OR resolved = 0)
);
CREATE INDEX IF NOT EXISTS relation_src_idx ON relation (snapshot_id, src_id, kind);
CREATE INDEX IF NOT EXISTS relation_dst_idx ON relation (snapshot_id, dst_id, kind);
CREATE UNIQUE INDEX IF NOT EXISTS relation_resolved_uniq
  ON relation (snapshot_id, src_id, dst_id, kind) WHERE dst_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS relation_unresolved_uniq
  ON relation (snapshot_id, src_id, dst_key, kind) WHERE dst_id IS NULL;

-- Unresolved targets observed by a provider: raw target kept verbatim plus
-- candidate stable_ids and evidence.  First-class truth, not an error state.
CREATE TABLE IF NOT EXISTS unresolved_edge (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id   INTEGER NOT NULL REFERENCES snapshot (id),
  src_key       TEXT NOT NULL,
  dst_raw       TEXT NOT NULL,
  kind          TEXT NOT NULL,
  provider      TEXT NOT NULL,
  provider_revision TEXT NOT NULL DEFAULT '',
  candidates    TEXT NOT NULL DEFAULT '[]',
  confidence    REAL NOT NULL DEFAULT 0.3,
  completeness  TEXT NOT NULL DEFAULT 'unknown',
  evidence      TEXT NOT NULL DEFAULT '[]',
  created_utc   TEXT
);
CREATE INDEX IF NOT EXISTS unresolved_edge_snapshot_idx ON unresolved_edge (snapshot_id, kind);

-- Observations supporting canonical rows.
CREATE TABLE IF NOT EXISTS support (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id   INTEGER NOT NULL REFERENCES snapshot (id),
  subject_table TEXT NOT NULL,
  subject_id    INTEGER NOT NULL,
  provider      TEXT NOT NULL,
  provider_revision TEXT NOT NULL DEFAULT '',
  confidence    REAL NOT NULL DEFAULT 1.0,
  evidence_id   INTEGER REFERENCES evidence (id),
  detail        TEXT,
  observed_utc  TEXT,
  UNIQUE (snapshot_id, subject_table, subject_id, provider, evidence_id)
);

CREATE TABLE IF NOT EXISTS evidence (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id   INTEGER NOT NULL REFERENCES snapshot (id),
  kind          TEXT NOT NULL,
  ref           TEXT NOT NULL,
  digest        TEXT,
  summary       TEXT NOT NULL DEFAULT '',
  payload       TEXT,
  provider      TEXT NOT NULL DEFAULT '',
  created_utc   TEXT
);

CREATE TABLE IF NOT EXISTS provider_record (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id   INTEGER NOT NULL REFERENCES snapshot (id),
  provider      TEXT NOT NULL,
  provider_version TEXT NOT NULL,
  capabilities  TEXT NOT NULL,
  invoked       INTEGER NOT NULL DEFAULT 1,
  UNIQUE (snapshot_id, provider)
);

-- Minimal subject/predicate/object facts ("checkout publishes OrderCreated").
CREATE TABLE IF NOT EXISTS fact (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id   INTEGER NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
  subject       TEXT NOT NULL,
  predicate     TEXT NOT NULL,
  object        TEXT NOT NULL,
  tier          INTEGER NOT NULL DEFAULT 0,
  provenance    TEXT NOT NULL DEFAULT 'observed',
  confidence    REAL NOT NULL DEFAULT 1.0,
  derived_from  TEXT NOT NULL DEFAULT '[]',
  last_verified TEXT,
  uncertainty   TEXT,
  stale         INTEGER NOT NULL DEFAULT 0,
  epistemic_state TEXT NOT NULL DEFAULT 'observed',
  analysis_depth INTEGER NOT NULL DEFAULT 0,
  completeness  TEXT NOT NULL DEFAULT 'partial',
  provider      TEXT NOT NULL DEFAULT '',
  provider_revision TEXT NOT NULL DEFAULT '',
  stable_subject TEXT NOT NULL DEFAULT '',
  UNIQUE (snapshot_id, subject, predicate, object)
);

-- Invariants: conditions that must remain true.  May be declared or
-- inferred; both keep provenance/confidence.
CREATE TABLE IF NOT EXISTS invariant (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id   INTEGER NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
  statement     TEXT NOT NULL,
  component_qn  TEXT,
  tier          INTEGER NOT NULL DEFAULT 0,
  provenance    TEXT NOT NULL DEFAULT 'declared',
  confidence    REAL NOT NULL DEFAULT 1.0,
  derived_from  TEXT NOT NULL DEFAULT '[]',
  last_verified TEXT,
  uncertainty   TEXT,
  stale         INTEGER NOT NULL DEFAULT 0,
  UNIQUE (snapshot_id, statement, component_qn)
);

-- Contracts: compatibility boundaries (api/schema/event/cli/config/format).
CREATE TABLE IF NOT EXISTS contract (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id   INTEGER NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
  kind          TEXT NOT NULL,
  name          TEXT NOT NULL,
  component_qn  TEXT,
  format        TEXT,
  tier          INTEGER NOT NULL DEFAULT 0,
  provenance    TEXT NOT NULL DEFAULT 'declared',
  confidence    REAL NOT NULL DEFAULT 1.0,
  derived_from  TEXT NOT NULL DEFAULT '[]',
  last_verified TEXT,
  uncertainty   TEXT,
  stale         INTEGER NOT NULL DEFAULT 0,
  attrs         TEXT NOT NULL DEFAULT '{}',
  UNIQUE (snapshot_id, kind, name)
);

-- Historical model: incidents, changes, failures, rollbacks.
CREATE TABLE IF NOT EXISTS incident (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id   INTEGER NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
  summary       TEXT NOT NULL,
  component_qn  TEXT,
  occurred_utc  TEXT,
  severity      TEXT,
  provenance    TEXT NOT NULL DEFAULT 'historically_supported',
  confidence    REAL NOT NULL DEFAULT 1.0,
  derived_from  TEXT NOT NULL DEFAULT '[]',
  uncertainty   TEXT,
  stale         INTEGER NOT NULL DEFAULT 0,
  attrs         TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS change (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id   INTEGER NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
  commit_sha    TEXT,
  summary       TEXT NOT NULL,
  files         TEXT NOT NULL DEFAULT '[]',
  outcome       TEXT,
  provenance    TEXT NOT NULL DEFAULT 'historically_supported',
  confidence    REAL NOT NULL DEFAULT 1.0,
  derived_from  TEXT NOT NULL DEFAULT '[]',
  uncertainty   TEXT,
  stale         INTEGER NOT NULL DEFAULT 0,
  attrs         TEXT NOT NULL DEFAULT '{}'
);

-- ── immutability triggers ────────────────────────────────────────────────
-- Draft snapshots are mutable (scan() writes and finalizes inside one
-- transaction).  Once a snapshot is 'finalized', nothing inside it may be
-- inserted, updated or deleted; a scan that changes the tree produces a NEW
-- revision, and removals are answered by diff_snapshots.

CREATE TRIGGER IF NOT EXISTS entity_no_insert_finalized
BEFORE INSERT ON entity
WHEN (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: entity is immutable'); END;

CREATE TRIGGER IF NOT EXISTS entity_no_update_finalized
BEFORE UPDATE ON entity
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
  OR (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: entity is immutable'); END;

CREATE TRIGGER IF NOT EXISTS entity_no_delete_finalized
BEFORE DELETE ON entity
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: entity is immutable'); END;

CREATE TRIGGER IF NOT EXISTS relation_no_insert_finalized
BEFORE INSERT ON relation
WHEN (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: relation is immutable'); END;

CREATE TRIGGER IF NOT EXISTS relation_no_update_finalized
BEFORE UPDATE ON relation
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
  OR (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: relation is immutable'); END;

CREATE TRIGGER IF NOT EXISTS relation_no_delete_finalized
BEFORE DELETE ON relation
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: relation is immutable'); END;

CREATE TRIGGER IF NOT EXISTS fact_no_insert_finalized
BEFORE INSERT ON fact
WHEN (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: fact is immutable'); END;

CREATE TRIGGER IF NOT EXISTS fact_no_update_finalized
BEFORE UPDATE ON fact
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
  OR (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: fact is immutable'); END;

CREATE TRIGGER IF NOT EXISTS fact_no_delete_finalized
BEFORE DELETE ON fact
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: fact is immutable'); END;

CREATE TRIGGER IF NOT EXISTS unresolved_edge_no_insert_finalized
BEFORE INSERT ON unresolved_edge
WHEN (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: unresolved_edge is immutable'); END;

CREATE TRIGGER IF NOT EXISTS unresolved_edge_no_update_finalized
BEFORE UPDATE ON unresolved_edge
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
  OR (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: unresolved_edge is immutable'); END;

CREATE TRIGGER IF NOT EXISTS unresolved_edge_no_delete_finalized
BEFORE DELETE ON unresolved_edge
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: unresolved_edge is immutable'); END;

CREATE TRIGGER IF NOT EXISTS support_no_insert_finalized
BEFORE INSERT ON support
WHEN (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: support is immutable'); END;

CREATE TRIGGER IF NOT EXISTS support_no_update_finalized
BEFORE UPDATE ON support
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
  OR (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: support is immutable'); END;

CREATE TRIGGER IF NOT EXISTS support_no_delete_finalized
BEFORE DELETE ON support
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: support is immutable'); END;

CREATE TRIGGER IF NOT EXISTS evidence_no_insert_finalized
BEFORE INSERT ON evidence
WHEN (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: evidence is immutable'); END;

CREATE TRIGGER IF NOT EXISTS evidence_no_update_finalized
BEFORE UPDATE ON evidence
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
  OR (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: evidence is immutable'); END;

CREATE TRIGGER IF NOT EXISTS evidence_no_delete_finalized
BEFORE DELETE ON evidence
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: evidence is immutable'); END;

CREATE TRIGGER IF NOT EXISTS provider_record_no_insert_finalized
BEFORE INSERT ON provider_record
WHEN (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: provider_record is immutable'); END;

CREATE TRIGGER IF NOT EXISTS provider_record_no_update_finalized
BEFORE UPDATE ON provider_record
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
  OR (SELECT state FROM snapshot WHERE id = NEW.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: provider_record is immutable'); END;

CREATE TRIGGER IF NOT EXISTS provider_record_no_delete_finalized
BEFORE DELETE ON provider_record
WHEN (SELECT state FROM snapshot WHERE id = OLD.snapshot_id) = 'finalized'
BEGIN SELECT RAISE(ABORT, 'snapshot finalized: provider_record is immutable'); END;
